-- Bond Auctions - dane z aukcji obligacji hurtowych (MF Operacje).
-- Wymaga juz odpalonego bondspot_schema.sql + bond_outstanding_schema.sql.
--
-- Tabela bond_auctions trzyma jeden wiersz per aukcyjny event z MF XLSM:
-- każda strona (sale leg / buyback leg) ma swoje wpisy.
-- Wlaczone TypOperacji:
--   AS - Aukcja Sprzedazy (primary auction)
--   AU - Aukcja Uzupelniajaca (top-up, dzien po AS, te same series)
--   AZ - Aukcja Zamiany (switch - jedna noga buy-back stara serie, druga sell nowa)
--   AO - Aukcja Odkupu (buyback auction)
--
-- Schema idempotentny: tabela CREATE IF NOT EXISTS, widoki CREATE OR REPLACE.

-- Kolejnosc DROP musi byc liscie -> korzen (PostgreSQL nie pozwala
-- zdropowac widoku, jesli inny widok zalezy od niego). Drzewo:
--    bond_auctions
--      └─ v_auction_metrics
--          └─ v_auction_with_market_context
--              ├─ v_recent_auctions
--              ├─ v_auction_day_totals
--              ├─ v_auction_by_tenor
--              └─ v_auction_by_coupon_bucket
DROP VIEW IF EXISTS v_recent_auctions;
DROP VIEW IF EXISTS v_auction_day_totals;
DROP VIEW IF EXISTS v_auction_by_tenor;
DROP VIEW IF EXISTS v_auction_by_coupon_bucket;
DROP VIEW IF EXISTS v_auction_with_market_context;
DROP VIEW IF EXISTS v_auction_metrics;

-- Dodanie kolumny years_to_maturity (LataDoWykupu z MF) - idempotentne
ALTER TABLE IF EXISTS bond_auctions
    ADD COLUMN IF NOT EXISTS years_to_maturity SMALLINT;

-- =====================================================================
--  BOND AUCTIONS - raw + cleaned auction data per ISIN per event
-- =====================================================================
CREATE TABLE IF NOT EXISTS bond_auctions (
    auction_id        TEXT PRIMARY KEY,        -- #ID z MF (unique per row)
    auction_date      DATE NOT NULL,           -- DataTransakcji
    settle_date       DATE,                    -- DataRozliczenia
    type_tx           CHAR(1) NOT NULL,        -- 'S' (sale leg) / 'O' (buyback leg)
    type_op           TEXT NOT NULL,           -- 'AS','AU','AZ','AO'
    seria             VARCHAR(32) NOT NULL,
    isin              VARCHAR(12) NOT NULL,
    maturity_date     DATE,
    years_to_maturity SMALLINT,                -- LataDoWykupu z MF (orig. tenor, np. 5/10/30)
    coupon_kind       CHAR(1),                 -- 'S','Z','I','O'
    offer_min_mln     NUMERIC(14,3),           -- Podaz Min
    offer_max_mln     NUMERIC(14,3),           -- Podaz Max (= zwykle target ilosc)
    demand_total_mln  NUMERIC(14,3),           -- Popyt Laczny
    demand_nc_mln     NUMERIC(14,3),           -- Popyt NK (non-competitive)
    sold_total_mln    NUMERIC(14,3),           -- Sprzedaz/Odkup Lacznie (signed; - dla O)
    sold_nc_mln       NUMERIC(14,3),           -- Sprzedaz NK
    price_min         NUMERIC(10,4),           -- Cena Min (lub Zamiany)
    price_avg         NUMERIC(10,4),           -- Cena Sr
    price_max         NUMERIC(10,4),           -- Cena Max
    yield_max         NUMERIC(8,4),            -- Rent Max  (stop yield dla sale)
    yield_avg         NUMERIC(8,4),            -- Rent Sr
    yield_min         NUMERIC(8,4),            -- Rent Min
    source            TEXT NOT NULL DEFAULT 'mf_xlsm',
    source_url        TEXT,
    inserted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_bond_auctions_date ON bond_auctions(auction_date DESC);
CREATE INDEX IF NOT EXISTS idx_bond_auctions_isin ON bond_auctions(isin, auction_date DESC);
CREATE INDEX IF NOT EXISTS idx_bond_auctions_type ON bond_auctions(type_op, auction_date DESC);

DROP TRIGGER IF EXISTS trg_bond_auctions_updated_at ON bond_auctions;
CREATE TRIGGER trg_bond_auctions_updated_at
    BEFORE UPDATE ON bond_auctions
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  VIEW: aukcyjne metryki - bid/cover, tail, NK share, dispersion
--  Wszystkie metryki w jednostkach branzowych:
--    bid_to_cover    - dimensionless (>2 silny popyt)
--    bid_to_offer    - dimensionless (>1 popyt pokryl oferte)
--    nc_share_*      - frakcja [0,1]
--    tail_yield_bp   - basis points (>5 = rozeprzony popyt)
--    price_dispersion_bp - basis points
-- =====================================================================
CREATE OR REPLACE VIEW v_auction_metrics AS
SELECT
    a.*,
    -- Bid-to-cover: total bids / accepted
    a.demand_total_mln / NULLIF(ABS(a.sold_total_mln), 0)    AS bid_to_cover,
    -- Bid-to-offer: bids / offered
    a.demand_total_mln / NULLIF(a.offer_max_mln, 0)          AS bid_to_offer,
    -- Allocation rate (= 1/bid_to_cover)
    ABS(a.sold_total_mln) / NULLIF(a.demand_total_mln, 0)    AS allocation_rate,
    -- Non-competitive share
    a.demand_nc_mln / NULLIF(a.demand_total_mln, 0)          AS nc_share_demand,
    a.sold_nc_mln / NULLIF(ABS(a.sold_total_mln), 0)         AS nc_share_sold,
    -- Tail w bp: stop yield (max) - avg yield. Dla sale wieksze niz 0.
    (a.yield_max - a.yield_avg) * 100                         AS tail_yield_bp,
    -- Price dispersion w bp
    (a.price_max - a.price_min) * 100                         AS price_dispersion_bp
FROM bond_auctions a;

-- =====================================================================
--  VIEW: aukcje + market context (concession vs najswiezszy pre-auction fixing)
--  concession_bp > 0  - aukcja "tail" vs rynek (MF musial podniesc rentownosc)
--  concession_bp < 0  - aukcja "through" (uplasowala sie nizej niz rynek wtorny)
--
--  Wybor pre-auction fixingu (priorytet):
--    1) ten sam dzien, sesja 1 (~11:00 - przed wynikiem aukcji ~11:30)
--    2) poprzednie dni, sesja 2 (EOD)
--    3) poprzednie dni, sesja 1
--  Nigdy nie bierzemy sesji 2 z dnia aukcji (jest PO aukcji - data leakage).
-- =====================================================================
CREATE OR REPLACE VIEW v_auction_with_market_context AS
SELECT
    m.*,
    f.fixing_yield                                            AS prior_fixing_yield,
    f.fixing_date                                             AS prior_fixing_date,
    (m.yield_avg - f.fixing_yield) * 100                      AS concession_bp,
    (m.yield_max - f.fixing_yield) * 100                      AS stop_concession_bp
FROM v_auction_metrics m
LEFT JOIN LATERAL (
    SELECT fixing_yield, fixing_date
    FROM bondspot_fixing
    WHERE isin = m.isin
      AND fixing_yield IS NOT NULL
      AND (
          (fixing_date = m.auction_date AND fixing_session = 1)
          OR fixing_date < m.auction_date
      )
    ORDER BY fixing_date DESC, fixing_session DESC
    LIMIT 1
) f ON true;

-- =====================================================================
--  VIEW: ostatnie aukcje sprzedazowe (do raportu/dashboardu).
--  Filtr na primary/top-up/switch-sell. Z buyback-only (AO) zwykle nie
--  liczymy "auction performance" tak samo.
-- =====================================================================
CREATE OR REPLACE VIEW v_recent_auctions AS
SELECT *
FROM v_auction_with_market_context
WHERE type_tx = 'S'
  AND type_op IN ('AS', 'AU', 'AZ')
ORDER BY auction_date DESC, isin;

-- =====================================================================
--  VIEW: statystyki CALEJ aukcji per dzien + type_op (zlozone aukcje
--  maja wiele serii - tu sumujemy je do jednego wiersza).
--  Metryki:
--    n_series         - ile serii sprzedanych w tym dniu/type_op
--    bid_to_cover     - sum(demand) / sum(sold)
--    bid_to_offer     - sum(demand) / sum(offer_max)
--    w_yield_avg      - srednia wazona sold-em
--    w_tail_bp        - sredni tail wazony sold-em
--    w_concession_bp  - srednia wazona concession (gdy dostepny prior fixing)
-- =====================================================================
CREATE OR REPLACE VIEW v_auction_day_totals AS
SELECT
    auction_date,
    type_op,
    COUNT(*) AS n_series,
    SUM(offer_max_mln)              AS total_offer_mln,
    SUM(demand_total_mln)           AS total_demand_mln,
    SUM(demand_nc_mln)              AS total_demand_nc_mln,
    SUM(ABS(sold_total_mln))        AS total_sold_mln,
    SUM(sold_nc_mln)                AS total_sold_nc_mln,
    SUM(demand_total_mln) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS bid_to_cover,
    SUM(demand_total_mln) / NULLIF(SUM(offer_max_mln), 0)
        AS bid_to_offer,
    SUM(yield_avg * ABS(sold_total_mln)) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS w_yield_avg,
    SUM(tail_yield_bp * ABS(sold_total_mln)) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS w_tail_bp,
    SUM(concession_bp * ABS(sold_total_mln)) FILTER (WHERE concession_bp IS NOT NULL)
        / NULLIF(SUM(ABS(sold_total_mln)) FILTER (WHERE concession_bp IS NOT NULL), 0)
        AS w_concession_bp,
    SUM(demand_nc_mln) / NULLIF(SUM(demand_total_mln), 0)
        AS nc_share_demand,
    SUM(sold_nc_mln) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS nc_share_sold
FROM v_auction_with_market_context
WHERE type_tx = 'S'
GROUP BY auction_date, type_op;

-- =====================================================================
--  VIEW: aukcje pogrupowane per (data, type_op, years_to_maturity).
--  Pozwala porownywac B/C i tail w czasie dla tej samej kategorii tenoru
--  (np. tylko 10Y, tylko 30Y).
-- =====================================================================
CREATE OR REPLACE VIEW v_auction_by_tenor AS
SELECT
    auction_date,
    type_op,
    years_to_maturity,
    COUNT(*) AS n_series,
    SUM(offer_max_mln)              AS total_offer_mln,
    SUM(demand_total_mln)           AS total_demand_mln,
    SUM(ABS(sold_total_mln))        AS total_sold_mln,
    SUM(demand_total_mln) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS bid_to_cover,
    SUM(yield_avg * ABS(sold_total_mln)) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS w_yield_avg,
    SUM(tail_yield_bp * ABS(sold_total_mln)) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS w_tail_bp,
    SUM(concession_bp * ABS(sold_total_mln)) FILTER (WHERE concession_bp IS NOT NULL)
        / NULLIF(SUM(ABS(sold_total_mln)) FILTER (WHERE concession_bp IS NOT NULL), 0)
        AS w_concession_bp
FROM v_auction_with_market_context
WHERE type_tx = 'S'
  AND years_to_maturity IS NOT NULL
GROUP BY auction_date, type_op, years_to_maturity;

-- =====================================================================
--  VIEW: aukcje pogrupowane per (data, type_op, coupon_bucket).
--  Kubelki kuponowe:
--    'I'  - inflation-linked (Oprocentowanie='I', np. IZ)
--    'OS' - zero-coupon + stale (O+S laczone, np. OK/PS/DS/WS)
--    'Z'  - zmienne (WZ/NZ)
-- =====================================================================
CREATE OR REPLACE VIEW v_auction_by_coupon_bucket AS
SELECT
    auction_date,
    type_op,
    CASE coupon_kind
        WHEN 'I' THEN 'I'
        WHEN 'Z' THEN 'Z'
        WHEN 'O' THEN 'OS'
        WHEN 'S' THEN 'OS'
        ELSE coupon_kind
    END AS coupon_bucket,
    COUNT(*) AS n_series,
    SUM(offer_max_mln)              AS total_offer_mln,
    SUM(demand_total_mln)           AS total_demand_mln,
    SUM(ABS(sold_total_mln))        AS total_sold_mln,
    SUM(demand_total_mln) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS bid_to_cover,
    SUM(yield_avg * ABS(sold_total_mln)) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS w_yield_avg,
    SUM(tail_yield_bp * ABS(sold_total_mln)) / NULLIF(SUM(ABS(sold_total_mln)), 0)
        AS w_tail_bp,
    SUM(concession_bp * ABS(sold_total_mln)) FILTER (WHERE concession_bp IS NOT NULL)
        / NULLIF(SUM(ABS(sold_total_mln)) FILTER (WHERE concession_bp IS NOT NULL), 0)
        AS w_concession_bp
FROM v_auction_with_market_context
WHERE type_tx = 'S'
  AND coupon_kind IS NOT NULL
GROUP BY auction_date, type_op,
    CASE coupon_kind
        WHEN 'I' THEN 'I'
        WHEN 'Z' THEN 'Z'
        WHEN 'O' THEN 'OS'
        WHEN 'S' THEN 'OS'
        ELSE coupon_kind
    END;
