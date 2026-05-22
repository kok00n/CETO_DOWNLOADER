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
-- Mianownik per-metric (CASE WHEN metric IS NOT NULL) - bondy ktore istnieja
-- ale nie maja jeszcze policzonych analytics nie powinny biasowac wazonej
-- sredniej w dol. Reszta - jak v_portfolio_metrics_daily, tylko grupa
-- dodatkowo po bond_type.
CREATE OR REPLACE VIEW v_portfolio_metrics_by_type AS
SELECT
    fixing_date,
    bond_type,
    SUM(outstanding_mln_pln) AS total_mln_pln,
    SUM(mod_duration * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN mod_duration IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS w_mod_duration,
    SUM(mac_duration * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN mac_duration IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS w_mac_duration,
    SUM(atm_years * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN atm_years IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS w_atm,
    SUM(atr_years * outstanding_mln_pln) / NULLIF(
        SUM(CASE WHEN atr_years IS NOT NULL THEN outstanding_mln_pln END), 0
    ) AS w_atr,
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
--  Algorytm: dla kazdego (effective_date, bond_type) sumujemy delty wszystkich
--  ISIN-ow tego typu w tym dniu, potem cumulative sum WINDOW per typ daje
--  total outstanding per typ na ten dzien.
--
--  WAZNE: effective_date = COALESCE(auction_date, change_date)
--   - dla aukcji (sale/buyback): auction_date = DataTransakcji z MF, czyli
--     chart pokazuje aukcje w dniu transakcji (nie 2 dni pozniej na settle).
--     Dziala dla pending (settle w przyszlosci) ORAZ historycznych
--     (juz rozliczonych) - zawsze auction_date.
--   - dla recon/redemption: auction_date jest NULL, COALESCE fall-through
--     do change_date (snapshot_date dla recon, maturity dla redemption).
--
--  bond_outstanding zawiera wszystkie wiersze z MF Operacje (lacznie z
--  pending settlements - settle_date > today), wiec nie potrzeba UNION ALL
--  z bond_auctions; refresh_bond_outstanding wstawia je przy kazdym uruchomieniu.
-- =====================================================================
CREATE OR REPLACE VIEW v_bond_outstanding_by_type_events AS
WITH per_date_type AS (
    SELECT
        COALESCE(bo.auction_date, bo.change_date) AS effective_date,
        bs.bond_type,
        SUM(bo.delta_mln_pln) AS delta_per_date_type
    FROM bond_outstanding bo
    JOIN bond_specs bs ON bs.isin = bo.isin
    WHERE bs.bond_type IS NOT NULL
    GROUP BY COALESCE(bo.auction_date, bo.change_date), bs.bond_type
)
SELECT
    effective_date AS change_date,
    bond_type,
    SUM(delta_per_date_type) OVER (
        PARTITION BY bond_type
        ORDER BY effective_date
        ROWS UNBOUNDED PRECEDING
    ) AS outstanding_mln_pln
FROM per_date_type
ORDER BY effective_date, bond_type;

-- =====================================================================
--  VIEW: total tbill outstanding na bazie event-driven delty.
--  Analogiczne do v_bond_outstanding_by_type_events: COALESCE(auction_date,
--  change_date) - aukcyjne wiersze datowane na auction_date, redemption/
--  recon (auction_date NULL) fall-through do change_date.
-- =====================================================================
CREATE OR REPLACE VIEW v_tbill_outstanding_events AS
WITH per_date AS (
    SELECT
        COALESCE(auction_date, change_date) AS effective_date,
        SUM(delta_mln_pln) AS delta_per_date
    FROM tbill_outstanding
    GROUP BY COALESCE(auction_date, change_date)
)
SELECT
    effective_date AS change_date,
    SUM(delta_per_date) OVER (
        ORDER BY effective_date
        ROWS UNBOUNDED PRECEDING
    ) AS outstanding_mln_pln
FROM per_date
ORDER BY effective_date;
