-- Dashboard RPCs - pre-aggregated time series do wykresow.
-- Wymaga juz odpalonych: bondspot_schema, bondspot_analytics_schema,
-- bond_outstanding_schema, tbill_schema.
--
-- Notebook woła te funkcje przez REST /rpc/<name>, dostaje gotowe DataFrame-y
-- bez sciagania surowych ~75k wierszy z v_bondspot_full_weighted.

DROP FUNCTION IF EXISTS portfolio_metrics_by_type(DATE, DATE);
DROP FUNCTION IF EXISTS debt_composition_by_type(DATE, DATE);

-- =====================================================================
--  RPC: portfolio-weighted metryki per (data, typ obligacji)
--  Zwraca dla kazdego dnia x kazdy typ: laczne outstanding + weighted avg
--  Mod/Mac Duration, ATM, ATR (wazone outstanding-em).
-- =====================================================================
CREATE OR REPLACE FUNCTION portfolio_metrics_by_type(
    p_from DATE DEFAULT '2011-01-01',
    p_to   DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    fixing_date          DATE,
    bond_type            TEXT,
    total_mln_pln        NUMERIC,
    w_mod_duration       NUMERIC,
    w_mac_duration       NUMERIC,
    w_atm                NUMERIC,
    w_atr                NUMERIC,
    w_yield_pct          NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT
        fixing_date,
        bond_type,
        SUM(outstanding_mln_pln) AS total_mln_pln,
        SUM(mod_duration * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0),
        SUM(mac_duration * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0),
        SUM(atm_years * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0),
        SUM(atr_years * outstanding_mln_pln) / NULLIF(SUM(outstanding_mln_pln), 0),
        SUM(fixing_yield * outstanding_mln_pln) / NULLIF(
            SUM(CASE WHEN fixing_yield IS NOT NULL THEN outstanding_mln_pln END), 0
        )
    FROM v_bondspot_full_weighted
    WHERE fixing_date BETWEEN p_from AND p_to
      AND outstanding_mln_pln IS NOT NULL
      AND outstanding_mln_pln > 0
      AND bond_type IS NOT NULL
    GROUP BY fixing_date, bond_type
    ORDER BY fixing_date, bond_type;
$$;

-- =====================================================================
--  RPC: sklad dlugu (outstanding per typ + tbill) - dla stacked area
--  Bondy bierzemy z v_bondspot_full_weighted (per fixing_date), tbille
--  z tbills_outstanding_at - dla kazdego dnia.
-- =====================================================================
CREATE OR REPLACE FUNCTION debt_composition_by_type(
    p_from DATE DEFAULT '2011-01-01',
    p_to   DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    fixing_date          DATE,
    bond_type            TEXT,
    outstanding_mln_pln  NUMERIC
)
LANGUAGE sql STABLE AS $$
    -- Bondy: per (date, type) - laczne outstanding
    SELECT
        fixing_date,
        bond_type,
        SUM(outstanding_mln_pln) AS outstanding_mln_pln
    FROM v_bondspot_full_weighted
    WHERE fixing_date BETWEEN p_from AND p_to
      AND outstanding_mln_pln IS NOT NULL
      AND outstanding_mln_pln > 0
      AND bond_type IS NOT NULL
    GROUP BY fixing_date, bond_type

    UNION ALL

    -- Bony skarbowe: per dzien (jako jeden 'tbill' kubel). Bierzemy dni
    -- ktore istnieja w bondspot_fixing (fixing_session=2) zeby siatka dat
    -- byla wspolna - inaczej stacked area mialoby dziury w weekendy.
    SELECT
        f.fixing_date,
        'tbill'::TEXT AS bond_type,
        COALESCE(SUM(t.balance_mln_pln), 0) AS outstanding_mln_pln
    FROM (
        SELECT DISTINCT fixing_date
        FROM bondspot_fixing
        WHERE fixing_session = 2
          AND fixing_date BETWEEN p_from AND p_to
    ) f
    LEFT JOIN LATERAL tbills_outstanding_at(f.fixing_date) t ON true
    GROUP BY f.fixing_date
    HAVING COALESCE(SUM(t.balance_mln_pln), 0) > 0

    ORDER BY fixing_date, bond_type;
$$;
