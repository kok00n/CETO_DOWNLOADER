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
--  VIEW: sklad dlugu (outstanding per typ + tbill) - dla stacked area
--  Bondy z v_bondspot_full_weighted; bony jako oddzielny 'tbill' kubel
--  liczony per dzien dla ktorego istnieje fixing 2 (zeby siatka dat
--  byla wspolna - inaczej stacked area mialoby dziury w weekendy).
-- =====================================================================
CREATE OR REPLACE VIEW v_debt_composition_by_type AS
    -- Bondy: per (date, type)
    SELECT
        fixing_date,
        bond_type,
        SUM(outstanding_mln_pln) AS outstanding_mln_pln
    FROM v_bondspot_full_weighted
    WHERE outstanding_mln_pln IS NOT NULL
      AND outstanding_mln_pln > 0
      AND bond_type IS NOT NULL
    GROUP BY fixing_date, bond_type

    UNION ALL

    -- Bony skarbowe: per dzien fixingu (kubelek 'tbill')
    SELECT
        f.fixing_date,
        'tbill'::TEXT AS bond_type,
        COALESCE(SUM(t.balance_mln_pln), 0) AS outstanding_mln_pln
    FROM (
        SELECT DISTINCT fixing_date
        FROM bondspot_fixing
        WHERE fixing_session = 2
    ) f
    LEFT JOIN LATERAL tbills_outstanding_at(f.fixing_date) t ON true
    GROUP BY f.fixing_date
    HAVING COALESCE(SUM(t.balance_mln_pln), 0) > 0;
