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
--  WAZNE: effective_date dla aukcji ktore juz sie odbyly ale settlement
--  jeszcze nie nastapil (T+1/T+2) = auction_date (nie settlement). Inaczej
--  outstanding na ten dzien wieczorny raport jeszcze nie pokazuje aukcji.
--
--  Implementacja: UNION ALL
--    1. bond_outstanding (settled) - change_date = settle_date z MF
--    2. bond_auctions WHERE auction <= today AND settle > today (pending
--       overlay) - delta = sold_total_mln (sign juz poprawny: + sale, - buyback)
--
--  Po settlement: WHERE settle_date > CURRENT_DATE staje sie FALSE, pending
--  znika; jednoczesnie bond_outstanding ma nowy wpis na settle_date -> zero
--  double counting.
-- =====================================================================
CREATE OR REPLACE VIEW v_bond_outstanding_by_type_events AS
WITH all_deltas AS (
    -- Settled deltas (bond_outstanding dated at settlement)
    SELECT
        bo.change_date AS effective_date,
        bs.bond_type,
        bo.delta_mln_pln AS delta
    FROM bond_outstanding bo
    JOIN bond_specs bs ON bs.isin = bo.isin
    WHERE bs.bond_type IS NOT NULL
    UNION ALL
    -- Pending overlay: aukcje odbyte ale jeszcze nierozliczone, datowane
    -- na auction_date. type_op AS/AU/AZ/AO + type_tx S/O zeby zlapac
    -- wszystkie legi (sale + buyback w switch + standalone odkup).
    SELECT
        ba.auction_date AS effective_date,
        bs.bond_type,
        ba.sold_total_mln AS delta
    FROM bond_auctions ba
    JOIN bond_specs bs ON bs.isin = ba.isin
    WHERE ba.auction_date <= CURRENT_DATE
      AND ba.settle_date > CURRENT_DATE
      AND ba.type_tx IN ('S', 'O')
      AND ba.type_op IN ('AS', 'AU', 'AZ', 'AO')
      AND ba.sold_total_mln IS NOT NULL
      AND bs.bond_type IS NOT NULL
),
per_date_type AS (
    SELECT
        effective_date AS change_date,
        bond_type,
        SUM(delta) AS delta_per_date_type
    FROM all_deltas
    GROUP BY effective_date, bond_type
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
--  Analogiczne do v_bond_outstanding_by_type_events: dla rowow ktore sa
--  jeszcze nierozliczone (change_date > today) i ktore maja auction_date,
--  uzywamy auction_date jako effective. Pozostale - change_date.
-- =====================================================================
CREATE OR REPLACE VIEW v_tbill_outstanding_events AS
WITH per_date AS (
    SELECT
        CASE
            WHEN auction_date IS NOT NULL AND change_date > CURRENT_DATE
                THEN auction_date
            ELSE change_date
        END AS effective_date,
        SUM(delta_mln_pln) AS delta_per_date
    FROM tbill_outstanding
    GROUP BY 1
)
SELECT
    effective_date AS change_date,
    SUM(delta_per_date) OVER (
        ORDER BY effective_date
        ROWS UNBOUNDED PRECEDING
    ) AS outstanding_mln_pln
FROM per_date
ORDER BY effective_date;
