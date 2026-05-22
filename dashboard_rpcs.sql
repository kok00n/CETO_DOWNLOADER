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
DROP VIEW IF EXISTS v_bond_servicing_cost;
DROP VIEW IF EXISTS v_tbill_servicing_cost;

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

-- =====================================================================
--  VIEW: per-ISIN current servicing rate dla aktywnych obligacji.
--
--  Logic per coupon_kind:
--    'S' (stale)        - waz. srednia yield_avg ze wszystkich aukcji ISIN-u
--                         (zamrozony koszt z momentu emisji, jaki MF placi)
--    'O' (zerokup, OK)  - jak 'S'
--    'Z' WZ             - bieżący WIBOR6M (z reference_rates, zaklada spread=0)
--    'Z' NZ             - bieżący POLSTR
--    'I' (IZ inflation) - real_coupon + biezacy CPI_YoY (uproszczenie -
--                         dokladna formula uzywa CPI ratio z issue, tu YoY proxy)
--    fallback           - NULL
--
--  Pre-requisite: zaaplikowane reference_rates_schema.sql + dane wpisane przez
--  refresh_reference_rates.py. Jesli brak danych w reference_rates -> floatery
--  i IZ wracaja NULL i sa wylaczone z weighted avg w Python.
-- =====================================================================
CREATE OR REPLACE VIEW v_bond_servicing_cost AS
WITH latest_rates AS (
    SELECT
        reference_rate_latest('WIBOR6M') AS wibor6m,
        reference_rate_latest('POLSTR')  AS polstr,
        reference_rate_latest('CPI_YOY') AS cpi_yoy
),
isin_auction_yield AS (
    SELECT
        isin,
        SUM(yield_avg * ABS(sold_total_mln))
            / NULLIF(SUM(ABS(sold_total_mln)), 0) AS w_yield_pct
    FROM bond_auctions
    WHERE type_tx = 'S'
      AND type_op IN ('AS','AU','SD','AZ')
      AND yield_avg IS NOT NULL
      AND sold_total_mln IS NOT NULL
    GROUP BY isin
),
active_bonds AS (
    SELECT DISTINCT ON (bs.isin)
        bs.isin, bs.bond_type, bs.coupon_kind, bs.coupon_rate,
        bs.maturity_date, bo.balance_mln_pln
    FROM bond_specs bs
    JOIN bond_outstanding bo
      ON bo.isin = bs.isin AND bo.change_date <= CURRENT_DATE
    WHERE bs.maturity_date > CURRENT_DATE
    ORDER BY bs.isin, bo.change_date DESC
)
SELECT
    ab.isin, ab.bond_type, ab.coupon_kind, ab.maturity_date,
    ab.balance_mln_pln,
    iay.w_yield_pct AS auction_avg_yield_pct,
    lr.wibor6m, lr.polstr, lr.cpi_yoy,
    CASE
        WHEN ab.coupon_kind IN ('S','O')   THEN iay.w_yield_pct
        WHEN ab.bond_type = 'WZ'           THEN lr.wibor6m
        WHEN ab.bond_type = 'NZ'           THEN lr.polstr
        WHEN ab.coupon_kind = 'I'          THEN (ab.coupon_rate * 100) + lr.cpi_yoy
        ELSE NULL
    END AS servicing_rate_pct,
    CASE
        WHEN ab.coupon_kind IN ('S','O')   THEN 'auction yield'
        WHEN ab.bond_type = 'WZ'           THEN 'WIBOR6M'
        WHEN ab.bond_type = 'NZ'           THEN 'POLSTR'
        WHEN ab.coupon_kind = 'I'          THEN 'real coupon + CPI YoY'
        ELSE 'unknown'
    END AS servicing_rate_source
FROM active_bonds ab
LEFT JOIN isin_auction_yield iay ON iay.isin = ab.isin
CROSS JOIN latest_rates lr
WHERE ab.balance_mln_pln > 0;

-- =====================================================================
--  VIEW: per-ISIN current servicing rate dla aktywnych bonow skarbowych.
--  T-bille sa zerokuponowe, koszt = yield przy aukcji (last sold).
-- =====================================================================
CREATE OR REPLACE VIEW v_tbill_servicing_cost AS
WITH active_tbills AS (
    SELECT DISTINCT ON (ts.isin)
        ts.isin, ts.bill_type, ts.maturity_date, to_.balance_mln_pln
    FROM tbill_specs ts
    JOIN tbill_outstanding to_
      ON to_.isin = ts.isin AND to_.change_date <= CURRENT_DATE
    WHERE ts.maturity_date > CURRENT_DATE
    ORDER BY ts.isin, to_.change_date DESC
)
-- Tbille nie maja wlasnej tabeli auctions; cost approximowac przez
-- effective implied yield z ich dyskontowej ceny w bond_outstanding.
-- Tu uproszczenie: nie liczymy per-tbill servicing rate, agregacja w Python
-- po prostu sumuje outstanding bez yield.
SELECT
    at.isin, at.bill_type, at.maturity_date, at.balance_mln_pln,
    NULL::NUMERIC AS servicing_rate_pct,
    'n/a (tbill - liczone osobno z discount/yield aukcyjnego)' AS servicing_rate_source
FROM active_tbills at
WHERE at.balance_mln_pln > 0;
