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
DROP VIEW IF EXISTS v_bond_outstanding_by_type_events;
DROP VIEW IF EXISTS v_tbill_outstanding_events;

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
--  Stara wersja oparta na v_bondspot_full_weighted (=GROUP BY z BondSpot
--  fixing dates) ma dwa problemy:
--    (1) NZ-tki pokazuja sie dopiero od kiedy BondSpot je kwotuje, a nie
--        od dnia pierwszej emisji (np. NZ0928: MF 2025-11-21, BondSpot
--        zaczyna ~kwiecien 2026 -> chart pokazuje NZ dopiero od kwietnia)
--    (2) Daty grupowania to fixing_dates BondSpota (codzienne), nie data
--        rzeczywistych zmian (aukcje, odkupy) - chart "wyglada na monthly"
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

-- =====================================================================
--  VIEW: sklad dlugu na bazie EVENT-DRIVEN delty (z MF bezposrednio,
--  niezalezne od BondSpota).
--
--  Algorytm: dla kazdego (change_date, bond_type) sumujemy delty wszystkich
--  ISIN-ow tego typu w tym dniu, potem cumulative sum WINDOW per typ daje
--  total outstanding per typ na ten dzien.
--
--  Wynik to sparse szereg event-driven (jedno row per (change_date, type)
--  gdzie wystapilo cokolwiek dla danego typu). Pandas potem forward-filluje
--  miedzy eventami.
--
--  Dla NZ0928 (MF issue 2025-11-21): rekord (2025-11-21, NZ, ~28000) -
--  chart pokazuje NZ od tego dnia, nie od BondSpota.
-- =====================================================================
CREATE OR REPLACE VIEW v_bond_outstanding_by_type_events AS
WITH per_date_type AS (
    SELECT
        bo.change_date,
        bs.bond_type,
        SUM(bo.delta_mln_pln) AS delta_per_date_type
    FROM bond_outstanding bo
    JOIN bond_specs bs ON bs.isin = bo.isin
    WHERE bs.bond_type IS NOT NULL
    GROUP BY bo.change_date, bs.bond_type
)
SELECT
    change_date,
    bond_type,
    SUM(delta_per_date_type) OVER (
        PARTITION BY bond_type
        ORDER BY change_date
        ROWS UNBOUNDED PRECEDING
    ) AS outstanding_mln_pln
FROM per_date_type
ORDER BY change_date, bond_type;

-- =====================================================================
--  VIEW: total tbill outstanding na bazie event-driven delty.
--  Analogiczne do v_bond_outstanding_by_type_events ale bez podzialu
--  na typy (bony skarbowe traktujemy jako jeden kubel).
-- =====================================================================
CREATE OR REPLACE VIEW v_tbill_outstanding_events AS
WITH per_date AS (
    SELECT
        change_date,
        SUM(delta_mln_pln) AS delta_per_date
    FROM tbill_outstanding
    GROUP BY change_date
)
SELECT
    change_date,
    SUM(delta_per_date) OVER (
        ORDER BY change_date
        ROWS UNBOUNDED PRECEDING
    ) AS outstanding_mln_pln
FROM per_date
ORDER BY change_date;
