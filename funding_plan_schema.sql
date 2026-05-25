-- Funding Plan - roczny plan pozyczkowy MF (manualnie wpisywany).
-- Wymaga juz odpalonego bond_outstanding_schema.sql.
--
-- Tabela funding_plan_annual ma JEDEN wiersz per rok kalendarzowy z liczbami
-- z "Strategii zarzadzania dlugiem" MF. Zrodlo: gov.pl/web/finanse, raporty
-- kwartalne. Trzeba aktualizowac recznie kiedy MF publikuje rewizje.
--
-- View v_funding_pace_ytd liczy aktualny YTD vs plan zeby pokazac jak
-- szybko MF emituje - kluczowe dla interpretacji aukcji ("MF wykonal juz
-- 75% planu w polowie roku - moze sobie pozwolic na mocne ciecia NK").
--
-- Schema idempotentny.

DROP VIEW IF EXISTS v_funding_pace_ytd;

CREATE TABLE IF NOT EXISTS funding_plan_annual (
    year                   INT PRIMARY KEY,
    plan_gross_mln_pln     NUMERIC(14,1),    -- roczne potrzeby brutto (issuance target)
    plan_net_mln_pln       NUMERIC(14,1),    -- przyrost netto dlugu
    notes                  TEXT,
    source_url             TEXT,
    inserted_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS trg_funding_plan_annual_updated_at ON funding_plan_annual;
CREATE TRIGGER trg_funding_plan_annual_updated_at
    BEFORE UPDATE ON funding_plan_annual
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  WIDOK: funding pace YTD (gross/net vs plan + pct year elapsed).
--  LEFT JOIN do funding_plan_annual - jesli plan dla biezacego roku nie
--  jest jeszcze wpisany, kolumny plan_* / pct_*_executed wracaja NULL ale
--  ytd_gross/net/buybacks/redemptions zawsze sa policzone.
--
--  Heurystyki:
--    op_type='sale'        -> issuance brutto
--    op_type='buyback'     -> wykup wczesny (negatywna delta)
--    op_type='redemption'  -> wykup w terminie (negatywna delta)
--    op_type='mixed'/inne  -> nie klasyfikujemy, leci tylko do net
-- =====================================================================
CREATE OR REPLACE VIEW v_funding_pace_ytd AS
WITH ytd AS (
    SELECT
        EXTRACT(YEAR FROM CURRENT_DATE)::INT AS year,
        COALESCE(SUM(CASE WHEN op_type = 'sale'       AND delta_mln_pln > 0
                           THEN delta_mln_pln END), 0) AS ytd_gross_sale_mln_pln,
        COALESCE(SUM(CASE WHEN op_type = 'buyback'    AND delta_mln_pln < 0
                           THEN -delta_mln_pln END), 0) AS ytd_buybacks_mln_pln,
        COALESCE(SUM(CASE WHEN op_type = 'redemption' AND delta_mln_pln < 0
                           THEN -delta_mln_pln END), 0) AS ytd_redemptions_mln_pln,
        COALESCE(SUM(delta_mln_pln), 0)                 AS ytd_net_mln_pln
    FROM bond_outstanding
    WHERE change_date >= DATE_TRUNC('year', CURRENT_DATE)::DATE
      AND change_date <= CURRENT_DATE
)
SELECT
    ytd.year,
    ytd.ytd_gross_sale_mln_pln,
    ytd.ytd_buybacks_mln_pln,
    ytd.ytd_redemptions_mln_pln,
    ytd.ytd_net_mln_pln,
    fp.plan_gross_mln_pln,
    fp.plan_net_mln_pln,
    CASE WHEN fp.plan_gross_mln_pln > 0
         THEN ROUND(100.0 * ytd.ytd_gross_sale_mln_pln / fp.plan_gross_mln_pln, 1)
    END AS pct_gross_executed,
    CASE WHEN fp.plan_net_mln_pln > 0
         THEN ROUND(100.0 * ytd.ytd_net_mln_pln / fp.plan_net_mln_pln, 1)
    END AS pct_net_executed,
    EXTRACT(DOY FROM CURRENT_DATE)::INT AS day_of_year,
    ROUND(100.0 * EXTRACT(DOY FROM CURRENT_DATE) /
          (CASE WHEN EXTRACT(YEAR FROM CURRENT_DATE)::INT % 4 = 0
                 AND (EXTRACT(YEAR FROM CURRENT_DATE)::INT % 100 <> 0
                      OR EXTRACT(YEAR FROM CURRENT_DATE)::INT % 400 = 0)
                THEN 366 ELSE 365 END), 1) AS pct_year_elapsed,
    fp.source_url AS plan_source_url
FROM ytd
LEFT JOIN funding_plan_annual fp ON fp.year = ytd.year;
