-- BondSpot Analytics - schema rozszerzenia
-- Wymaga juz odpalonego bondspot_schema.sql (uzywa funkcji bondspot_set_updated_at).
--
-- Dwie nowe tabele:
--   bond_specs           - dane statyczne obligacji (kupon, terminy, typ) z MF XLSM
--   bondspot_analytics   - wyliczone metryki per (data, ISIN) - jeden wpis per dzien
--                          (uzywamy fixing 2 = EOD jako zrodla YTM)
--
-- Schema jest idempotentny: tabele uzywaja CREATE IF NOT EXISTS, funkcje
-- wymagaja DROP+CREATE bo Postgres nie pozwala zmienic return type przez
-- CREATE OR REPLACE.
--
-- Jednorazowa migracja z bondspot_analytics z fixing_session w PK (jesli
-- masz takie z poprzedniej wersji):
--    DROP TABLE bondspot_analytics CASCADE;
-- Po DROP tabela bedzie odtworzona przy ponownym apply schematu, a
-- compute_analytics.py uzupelni dane przy nastepnym uruchomieniu.

DROP FUNCTION IF EXISTS bondspot_missing_analytics(INT);

-- =====================================================================
--  BOND SPECS - dane statyczne, refreshowane z MF Obligacje_Hurtowe.xlsm
-- =====================================================================
CREATE TABLE IF NOT EXISTS bond_specs (
    isin             VARCHAR(12) PRIMARY KEY,
    name             VARCHAR(32) NOT NULL,           -- np. 'DS0726'
    bond_type        TEXT NOT NULL,                  -- 'OK','PS','DS','WS','WZ','NZ','IZ','OS','DZ',...
    coupon_kind      CHAR(1) NOT NULL,               -- 'S'=stale, 'Z'=zmienne, 'I'=inflacja, 'O'=zerokuponowe
    is_floating      BOOLEAN NOT NULL,
    issue_date       DATE,                           -- MIN(DataTransakcji) per ISIN
    maturity_date    DATE NOT NULL,
    coupon_rate      NUMERIC(8,6),                   -- annual decimal (0.025 = 2.5%); NULL dla floating ('FRN')
    coupon_freq      SMALLINT,                       -- 1=annual, 2=semi-annual, 4=quarterly, 0=zero-coupon
    source           TEXT NOT NULL DEFAULT 'mf_xlsm',
    source_url       TEXT,
    inserted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_bond_specs_maturity ON bond_specs (maturity_date);
CREATE INDEX IF NOT EXISTS idx_bond_specs_type     ON bond_specs (bond_type);

DROP TRIGGER IF EXISTS trg_bond_specs_updated_at ON bond_specs;
CREATE TRIGGER trg_bond_specs_updated_at
    BEFORE UPDATE ON bond_specs
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  BONDSPOT ANALYTICS - wyliczane metryki per (data, ISIN)
--  Jeden wpis na dzien - zrodlem YTM jest fixing_session = 2 (EOD).
-- =====================================================================
CREATE TABLE IF NOT EXISTS bondspot_analytics (
    fixing_date     DATE         NOT NULL,
    isin            VARCHAR(12)  NOT NULL,
    bond_type       TEXT,
    atm_years       NUMERIC(8,4),    -- Average Time to Maturity (lata)
    atr_years       NUMERIC(8,4),    -- Average Time to Refixing  (lata)
    mac_duration    NUMERIC(8,4),    -- Macaulay Duration (lata); dla floaterow == ATR (time to next reset)
    mod_duration    NUMERIC(8,4),    -- Modified Duration (lata); dla floaterow ~ ATR
    computed_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (fixing_date, isin)
);

CREATE INDEX IF NOT EXISTS idx_bondspot_analytics_isin_date
    ON bondspot_analytics (isin, fixing_date DESC);

-- =====================================================================
--  RPC: brakujace metryki - dni z fixingiem 2 (EOD) bez wpisu w analytics.
--  Uzywane przez compute_analytics.py do incremental compute.
--  Bierzemy wylacznie fixing_session=2 zeby nie liczyc 2x tego samego dnia.
--
--  Zwracane pola:
--    fixing_yield     - quoted YTM (NULL dla WZ/IZ ktorych BondSpot nie quotuje)
--    fixing_price     - clean price, uzywane do back-solve YTM dla IZ
--    short_rate_proxy - AVG(fixing_yield) ze stalokuponowych obligacji na te
--                        sama date (proxy dla short rate gdy WIBOR niedostepny;
--                        floatery uzywaja tego do Mod = Mac / (1 + proxy/freq))
-- =====================================================================
CREATE OR REPLACE FUNCTION bondspot_missing_analytics(
    p_limit  INT DEFAULT 100000
)
RETURNS TABLE (
    fixing_date      DATE,
    isin             VARCHAR,
    fixing_yield     NUMERIC,
    fixing_price     NUMERIC,
    short_rate_proxy NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH proxy AS (
        SELECT
            fp.fixing_date,
            AVG(fp.fixing_yield) AS avg_y
        FROM bondspot_fixing fp
        WHERE fp.fixing_session = 2
          AND fp.fixing_yield IS NOT NULL
        GROUP BY fp.fixing_date
    )
    SELECT f.fixing_date, f.isin, f.fixing_yield, f.fixing_price, p.avg_y
    FROM bondspot_fixing f
    LEFT JOIN bondspot_analytics a
      ON a.fixing_date = f.fixing_date
     AND a.isin = f.isin
    LEFT JOIN proxy p ON p.fixing_date = f.fixing_date
    WHERE f.fixing_session = 2
      AND a.fixing_date IS NULL
    ORDER BY f.fixing_date ASC, f.isin ASC
    LIMIT p_limit;
$$;

-- =====================================================================
--  RPC: lista ISIN-ow obecnych w bondspot_fixing a brakujacych w bond_specs
--  (do alertu "nowa seria, dolacz do bond_specs")
-- =====================================================================
CREATE OR REPLACE FUNCTION bondspot_isins_missing_specs()
RETURNS TABLE (isin VARCHAR, first_seen DATE, last_seen DATE, fixings_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT
        f.isin,
        MIN(f.fixing_date) AS first_seen,
        MAX(f.fixing_date) AS last_seen,
        COUNT(*) AS fixings_count
    FROM bondspot_fixing f
    LEFT JOIN bond_specs s ON s.isin = f.isin
    WHERE s.isin IS NULL
    GROUP BY f.isin
    ORDER BY MIN(f.fixing_date);
$$;

-- =====================================================================
--  WIDOK: czytelny join EOD-fixingu (sesja 2) + analytics + spec.
--  Dla raportow analitycznych i dashboardu - 1 wiersz per (dzien, ISIN).
-- =====================================================================
CREATE OR REPLACE VIEW v_bondspot_full AS
SELECT
    f.fixing_date,
    f.isin,
    f.name,
    s.bond_type,
    s.is_floating,
    s.maturity_date,
    s.coupon_rate,
    f.bid_price,
    f.ask_price,
    f.fixing_price,
    f.fixing_yield,
    a.atm_years,
    a.atr_years,
    a.mac_duration,
    a.mod_duration
FROM bondspot_fixing f
LEFT JOIN bond_specs s ON s.isin = f.isin
LEFT JOIN bondspot_analytics a
    ON a.fixing_date = f.fixing_date
   AND a.isin = f.isin
WHERE f.fixing_session = 2;
