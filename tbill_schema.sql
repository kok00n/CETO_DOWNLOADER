-- Bony Skarbowe (T-bills) - dane statyczne + outstanding.
-- Wymaga juz odpalonego bondspot_schema.sql + bond_outstanding_schema.sql
-- (uzywa bondspot_set_updated_at + bonds_outstanding_at).
--
-- Bony skarbowe to krotkoterminowy dlug skarbowy (1-52 tyg), zerokuponowy,
-- znacznie mniejszy wolumenowo niz obligacje (~30 mld vs ~1.37 bln dla bondow)
-- ale wlicza sie do zadluzenia krajowego.
--
-- Schema jest idempotentny: tabele uzywaja CREATE IF NOT EXISTS, funkcje
-- wymagaja DROP+CREATE bo Postgres nie pozwala zmienic return type.

DROP FUNCTION IF EXISTS tbill_outstanding_at(VARCHAR, DATE);
DROP FUNCTION IF EXISTS tbills_outstanding_at(DATE);
DROP FUNCTION IF EXISTS sovereign_debt_at(DATE);

-- =====================================================================
--  TBILL SPECS - dane statyczne bonow skarbowych (refresh z MF .xls)
-- =====================================================================
CREATE TABLE IF NOT EXISTS tbill_specs (
    isin            VARCHAR(12) PRIMARY KEY,
    bill_type       TEXT NOT NULL,         -- np. '52T', '26T', '13T', '04T'
    tenor_days      SMALLINT,              -- maturity - issue, dla orientacji
    issue_date      DATE,                  -- MIN(DataRozliczenia) per ISIN
    maturity_date   DATE NOT NULL,
    source          TEXT NOT NULL DEFAULT 'mf_xls',
    source_url      TEXT,
    inserted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tbill_specs_maturity ON tbill_specs (maturity_date);
CREATE INDEX IF NOT EXISTS idx_tbill_specs_type     ON tbill_specs (bill_type);

DROP TRIGGER IF EXISTS trg_tbill_specs_updated_at ON tbill_specs;
CREATE TRIGGER trg_tbill_specs_updated_at
    BEFORE UPDATE ON tbill_specs
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  TBILL OUTSTANDING - punkty zmian salda per ISIN (analogiczne do bondow)
-- =====================================================================
CREATE TABLE IF NOT EXISTS tbill_outstanding (
    isin              VARCHAR(12) NOT NULL,
    change_date       DATE        NOT NULL,
    delta_mln_pln     NUMERIC(14,3),
    balance_mln_pln   NUMERIC(14,3) NOT NULL,
    op_type           TEXT,                -- 'sale','buyback','redemption','reconciliation'
    source            TEXT NOT NULL DEFAULT 'mf_xls',
    source_url        TEXT,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (isin, change_date)
);

CREATE INDEX IF NOT EXISTS idx_tbill_outstanding_isin_date
    ON tbill_outstanding (isin, change_date DESC);
CREATE INDEX IF NOT EXISTS idx_tbill_outstanding_date
    ON tbill_outstanding (change_date);

DROP TRIGGER IF EXISTS trg_tbill_outstanding_updated_at ON tbill_outstanding;
CREATE TRIGGER trg_tbill_outstanding_updated_at
    BEFORE UPDATE ON tbill_outstanding
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  RPC: outstanding pojedynczego bonu na dany dzien
-- =====================================================================
CREATE OR REPLACE FUNCTION tbill_outstanding_at(p_isin VARCHAR, p_date DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT balance_mln_pln
    FROM tbill_outstanding
    WHERE isin = p_isin AND change_date <= p_date
    ORDER BY change_date DESC
    LIMIT 1;
$$;

-- =====================================================================
--  RPC: outstanding wszystkich bonow na dany dzien
-- =====================================================================
CREATE OR REPLACE FUNCTION tbills_outstanding_at(p_date DATE)
RETURNS TABLE (isin VARCHAR, balance_mln_pln NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (isin) isin, balance_mln_pln
    FROM tbill_outstanding
    WHERE change_date <= p_date
    ORDER BY isin, change_date DESC;
$$;

-- =====================================================================
--  RPC: laczne zadluzenie (bondy + bony) na dany dzien
-- =====================================================================
CREATE OR REPLACE FUNCTION sovereign_debt_at(p_date DATE)
RETURNS TABLE (
    instrument_class TEXT,
    total_mln_pln    NUMERIC,
    instrument_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT 'bond'::TEXT, COALESCE(SUM(balance_mln_pln), 0)::NUMERIC, COUNT(*)::BIGINT
    FROM bonds_outstanding_at(p_date)
    WHERE balance_mln_pln > 0
    UNION ALL
    SELECT 'tbill'::TEXT, COALESCE(SUM(balance_mln_pln), 0)::NUMERIC, COUNT(*)::BIGINT
    FROM tbills_outstanding_at(p_date)
    WHERE balance_mln_pln > 0;
$$;

-- =====================================================================
--  WIDOK: aktualny snapshot lacznego zadluzenia z breakdown po typie
-- =====================================================================
CREATE OR REPLACE VIEW v_sovereign_debt_today AS
WITH d AS (SELECT * FROM sovereign_debt_at(CURRENT_DATE))
SELECT
    instrument_class,
    total_mln_pln,
    instrument_count,
    ROUND(100.0 * total_mln_pln / NULLIF(SUM(total_mln_pln) OVER (), 0), 2) AS pct_of_total
FROM d
ORDER BY total_mln_pln DESC;
