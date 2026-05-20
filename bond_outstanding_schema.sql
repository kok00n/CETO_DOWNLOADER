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
    change_date       DATE        NOT NULL,
    delta_mln_pln     NUMERIC(14,3),       -- net zmiana na ten dzien (+S, -O)
    balance_mln_pln   NUMERIC(14,3) NOT NULL,  -- saldo po tej zmianie
    op_type           TEXT,                -- 'sale','buyback','mixed','redemption'
    source            TEXT NOT NULL DEFAULT 'mf_xlsm',
    source_url        TEXT,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (isin, change_date)
);

CREATE INDEX IF NOT EXISTS idx_bond_outstanding_isin_date
    ON bond_outstanding (isin, change_date DESC);
CREATE INDEX IF NOT EXISTS idx_bond_outstanding_date
    ON bond_outstanding (change_date);

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
--  Do agregacji portfelowych: avg duration wazony nominal-em, total debt
--  per typ obligacji, itd.
-- =====================================================================
CREATE OR REPLACE VIEW v_bondspot_full_weighted AS
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
    a.mod_duration,
    o.balance_mln_pln AS outstanding_mln_pln
FROM bondspot_fixing f
LEFT JOIN bond_specs s ON s.isin = f.isin
LEFT JOIN bondspot_analytics a
    ON a.fixing_date = f.fixing_date AND a.isin = f.isin
LEFT JOIN LATERAL (
    SELECT balance_mln_pln
    FROM bond_outstanding o
    WHERE o.isin = f.isin AND o.change_date <= f.fixing_date
    ORDER BY o.change_date DESC
    LIMIT 1
) o ON true
WHERE f.fixing_session = 2;

-- =====================================================================
--  WIDOK: portfelowe metryki dzien po dniu (wazone outstanding)
--  Pominiete wiersze gdzie brak duration albo zero outstanding.
-- =====================================================================
CREATE OR REPLACE VIEW v_portfolio_metrics_daily AS
SELECT
    fixing_date,
    SUM(outstanding_mln_pln) AS total_outstanding_mln_pln,
    SUM(mod_duration * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS portfolio_mod_duration,
    SUM(mac_duration * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS portfolio_mac_duration,
    SUM(atm_years * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS portfolio_atm,
    SUM(atr_years * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS portfolio_atr,
    SUM(fixing_yield * outstanding_mln_pln) / NULLIF(SUM(CASE WHEN fixing_yield IS NOT NULL THEN outstanding_mln_pln END), 0)
        AS portfolio_yield_pct
FROM v_bondspot_full_weighted
WHERE outstanding_mln_pln IS NOT NULL AND outstanding_mln_pln > 0
GROUP BY fixing_date;
