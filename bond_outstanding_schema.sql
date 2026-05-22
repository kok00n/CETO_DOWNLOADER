-- Bond Outstanding - historyczne salda obligacji hurtowych w obiegu.
-- Wymaga juz odpalonego bondspot_schema.sql + bondspot_analytics_schema.sql.
--
-- Tabela bond_outstanding trzyma punkty zmian salda per ISIN (1 wiersz per
-- (isin, change_date) - operacje z tego samego dnia agregowane przez ETL).
-- Aby otrzymac outstanding na dowolna date q: weź balance_mln_pln z ostatniego
-- wiersza dla danego ISIN gdzie change_date <= q.
--
-- Funkcja bonds_outstanding_at(d) zwraca outstanding wszystkich obligacji
-- na dany dzien (w PLN mln).
--
-- Widok v_bondspot_full_weighted laczy fixing + analytics + outstanding w
-- jednym query do agregacji portfelowych metryk (np. avg duration calej
-- emisji wazony nominal-em).

-- Schema jest idempotentny: tabele uzywaja CREATE IF NOT EXISTS, funkcje
-- wymagaja DROP+CREATE bo Postgres nie pozwala zmienic return type przez
-- CREATE OR REPLACE.

DROP FUNCTION IF EXISTS bonds_outstanding_at(DATE);
DROP FUNCTION IF EXISTS bond_outstanding_at(VARCHAR, DATE);

-- =====================================================================
--  BOND OUTSTANDING - punkty zmian salda per ISIN
-- =====================================================================
CREATE TABLE IF NOT EXISTS bond_outstanding (
    isin              VARCHAR(12) NOT NULL,
    change_date       DATE        NOT NULL,   -- DataRozliczenia (settlement)
    auction_date      DATE,                   -- MIN DataTransakcji per (isin,settle); NULL dla recon/redemption
    delta_mln_pln     NUMERIC(14,3),       -- net zmiana na ten dzien (+S, -O)
    balance_mln_pln   NUMERIC(14,3) NOT NULL,  -- saldo po tej zmianie
    op_type           TEXT,                -- 'sale','buyback','mixed','redemption'
    source            TEXT NOT NULL DEFAULT 'mf_xlsm',
    source_url        TEXT,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (isin, change_date)
);

-- Migracja dla istniejacych instalacji (idempotentne)
ALTER TABLE bond_outstanding ADD COLUMN IF NOT EXISTS auction_date DATE;

CREATE INDEX IF NOT EXISTS idx_bond_outstanding_isin_date
    ON bond_outstanding (isin, change_date DESC);
CREATE INDEX IF NOT EXISTS idx_bond_outstanding_date
    ON bond_outstanding (change_date);
-- Functional index dla LATERAL w v_bondspot_full_weighted ktore filtruje po
-- COALESCE(auction_date, change_date). Bez tego per-row LATERAL leci full
-- scan -> v_portfolio_metrics_daily timeoutuje (500 z PostgREST). Z tym
-- indexem seek per (isin, effective_date) jest O(log n).
CREATE INDEX IF NOT EXISTS idx_bond_outstanding_isin_effective_date
    ON bond_outstanding (isin, COALESCE(auction_date, change_date) DESC);

DROP TRIGGER IF EXISTS trg_bond_outstanding_updated_at ON bond_outstanding;
CREATE TRIGGER trg_bond_outstanding_updated_at
    BEFORE UPDATE ON bond_outstanding
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  RPC: outstanding pojedynczej obligacji na dany dzien
-- =====================================================================
CREATE OR REPLACE FUNCTION bond_outstanding_at(p_isin VARCHAR, p_date DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT balance_mln_pln
    FROM bond_outstanding
    WHERE isin = p_isin AND change_date <= p_date
    ORDER BY change_date DESC
    LIMIT 1;
$$;

-- =====================================================================
--  RPC: outstanding wszystkich obligacji na dany dzien
-- =====================================================================
CREATE OR REPLACE FUNCTION bonds_outstanding_at(p_date DATE)
RETURNS TABLE (isin VARCHAR, balance_mln_pln NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (isin) isin, balance_mln_pln
    FROM bond_outstanding
    WHERE change_date <= p_date
    ORDER BY isin, change_date DESC;
$$;

-- =====================================================================
--  WIDOK: pelen kontekst (fixing EOD + analytics + outstanding + spec)
--
--  WAZNE: bazujemy na CROSS JOIN calendar × bond_specs (nie na bondspot_fixing).
--  Powod: gdyby zaczac od bondspot_fixing-u, do agregacji wchodzilyby tylko
--  bondy ktore mialy fixing TEGO dnia (mniej plynne serie wypadaja losowo).
--  To powodowalo daily 'zabki' na chartach portfelowych metryk - bond mial
--  duzy outstanding ale nie byl quotowany na BondSpocie, wiec wypadal z
--  wazonej sredniej -> portfolio duration skakal o 0.1-0.2 lata day-over-day.
--
--  Teraz: dla kazdej daty x kazdy aktywny bond (issue<=date<maturity, balance>0)
--  bierzemy:
--    - outstanding z bond_outstanding (LATERAL: ostatnia zmiana <= data)
--    - analytics z bondspot_analytics (LATERAL: ostatnia <= data = ffill per ISIN)
--    - same-day fixing_yield z bondspot_fixing (NULL jesli brak quote tego dnia)
--  Reszta szumu (~25-tego miesiaca) to REAL maturity rolls, nie data issue.
-- =====================================================================
CREATE OR REPLACE VIEW v_bondspot_full_weighted AS
WITH calendar AS (
    SELECT DISTINCT fixing_date FROM bondspot_fixing WHERE fixing_session = 2
)
SELECT
    c.fixing_date,
    bs.isin,
    bs.name,
    bs.bond_type,
    bs.is_floating,
    bs.maturity_date,
    bs.coupon_rate,
    f.bid_price,
    f.ask_price,
    f.fixing_price,
    f.fixing_yield,
    a.atm_years,
    a.atr_years,
    a.mac_duration,
    a.mod_duration,
    o.balance_mln_pln AS outstanding_mln_pln
FROM calendar c
CROSS JOIN bond_specs bs
LEFT JOIN bondspot_fixing f
    ON f.isin = bs.isin
   AND f.fixing_date = c.fixing_date
   AND f.fixing_session = 2
LEFT JOIN LATERAL (
    SELECT atm_years, atr_years, mac_duration, mod_duration
    FROM bondspot_analytics
    WHERE isin = bs.isin AND fixing_date <= c.fixing_date
    ORDER BY fixing_date DESC
    LIMIT 1
) a ON true
LEFT JOIN LATERAL (
    -- Outstanding query po effective_date = COALESCE(auction_date, change_date)
    -- (analogicznie do v_bond_outstanding_by_type_events): aukcja przesuwa
    -- balance na auction_date a nie settle_date, dzieki czemu portfolio
    -- metryki w chart 1/2 odzwierciedlaja swieza emisje juz w dniu aukcji
    -- (nie 2 dni pozniej). Dla recon/redemption (auction_date NULL) leci
    -- change_date jak wczesniej.
    --
    -- balance_mln_pln jest pre-computed w refresh script po settle_date order;
    -- dla typowych aukcji T+2 oba porzadki sa identyczne, wiec lookup po
    -- auction_date z tego samego balance_mln_pln daje poprawny wynik. Edge
    -- case (overlapping auction-vs-settle ordering) jest rzadki w polskich
    -- aukcjach hurtowych i moze wprowadzic <0.01Y bias na chart 1/2 przez
    -- kilka dni - akceptowalne.
    SELECT balance_mln_pln
    FROM bond_outstanding
    WHERE isin = bs.isin
      AND COALESCE(auction_date, change_date) <= c.fixing_date
    ORDER BY COALESCE(auction_date, change_date) DESC
    LIMIT 1
) o ON true
WHERE bs.maturity_date > c.fixing_date
  AND COALESCE(bs.issue_date, '1990-01-01'::date) <= c.fixing_date
  AND o.balance_mln_pln IS NOT NULL
  AND o.balance_mln_pln > 0;

-- =====================================================================
--  WIDOK: portfelowe metryki dzien po dniu (wazone outstanding).
--  Mianownik per-metric (CASE WHEN metric IS NOT NULL) - bondy bez analytics
--  nie powinny biasowac wazonej sredniej w dol.
-- =====================================================================
CREATE OR REPLACE VIEW v_portfolio_metrics_daily AS
SELECT
    fixing_date,
    SUM(outstanding_mln_pln) AS total_outstanding_mln_pln,
    SUM(mod_duration * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN mod_duration IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS portfolio_mod_duration,
    SUM(mac_duration * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN mac_duration IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS portfolio_mac_duration,
    SUM(atm_years * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN atm_years IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS portfolio_atm,
    SUM(atr_years * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN atr_years IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS portfolio_atr,
    SUM(fixing_yield * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN fixing_yield IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS portfolio_yield_pct
FROM v_bondspot_full_weighted
WHERE outstanding_mln_pln IS NOT NULL AND outstanding_mln_pln > 0
GROUP BY fixing_date;
