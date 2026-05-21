-- Dashboard views - pre-aggregated time series do wykresow.
-- Wymaga juz odpalonych: bondspot_schema, bondspot_analytics_schema,
-- bond_outstanding_schema, tbill_schema.
--
-- Notebook fetchuje przez REST GET /rest/v1/<view>?... + paginacje Range.
-- Wczesniejsze RPCs (POST) nie dzialaly bo Supabase PostgREST ignoruje
-- Range header dla POST RPC - kazde wywolanie zwracalo te same 1000
-- wierszy. Widoki dzialaja z paginacja Range out-of-the-box.

DROP FUNCTION IF EXISTS portfolio_metrics_by_type(DATE, DATE);
DROP FUNCTION IF EXISTS debt_composition_by_type(DATE, DATE);
DROP VIEW IF EXISTS v_portfolio_metrics_by_type;
DROP VIEW IF EXISTS v_debt_composition_by_type;
DROP VIEW IF EXISTS v_debt_composition_bonds;

-- =====================================================================
--  VIEW: portfolio-weighted metryki per (data, typ obligacji)
--  Dla kazdego dnia x kazdy typ: laczne outstanding + weighted avg
--  Mod/Mac Duration, ATM, ATR (wazone outstanding-em).
-- =====================================================================
CREATE OR REPLACE VIEW v_portfolio_metrics_by_type AS
SELECT
    fixing_date,
    bond_type,
    SUM(outstanding_mln_pln) AS total_mln_pln,
    SUM(mod_duration * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS w_mod_duration,
    SUM(mac_duration * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS w_mac_duration,
    SUM(atm_years * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS w_atm,
    SUM(atr_years * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0)
        AS w_atr,
    SUM(fixing_yield * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN fixing_yield IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS w_yield_pct
FROM v_bondspot_full_weighted
WHERE outstanding_mln_pln IS NOT NULL
  AND outstanding_mln_pln > 0
  AND bond_type IS NOT NULL
GROUP BY fixing_date, bond_type;

-- =====================================================================
--  VIEW: sklad dlugu - bondy per (data, typ).
--  T-bille fetchowane osobno jako raw tbill_outstanding (zmiany salda)
--  i resamplowane w notebooku w pandasie. Wczesniej probowano UNION ALL
--  z LATERAL na tbills_outstanding_at(...) wewnatrz tego widoku - PostgREST
--  zwracal 500 (LATERAL + set-returning function w widoku, opakowany w
--  outer ORDER BY, nie planuje sie dobrze).
-- =====================================================================
CREATE OR REPLACE VIEW v_debt_composition_bonds AS
SELECT
    fixing_date,
    bond_type,
    SUM(outstanding_mln_pln) AS outstanding_mln_pln
FROM v_bondspot_full_weighted
WHERE outstanding_mln_pln IS NOT NULL
  AND outstanding_mln_pln > 0
  AND bond_type IS NOT NULL
GROUP BY fixing_date, bond_type;
