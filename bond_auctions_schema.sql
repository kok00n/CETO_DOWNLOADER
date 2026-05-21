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

DROP VIEW IF EXISTS v_recent_auctions;
DROP VIEW IF EXISTS v_auction_with_market_context;
DROP VIEW IF EXISTS v_auction_metrics;

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
--  VIEW: aukcje + market context (concession vs ostatni fixing przed aukcja)
--  concession_bp > 0 oznacza ze aukcja byla droga (avg yield > pre-mkt yield)
--  concession_bp < 0 oznacza "through" - aukcja tansza niz rynek wtorny
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
      AND fixing_date < m.auction_date
      AND fixing_session = 2
      AND fixing_yield IS NOT NULL
    ORDER BY fixing_date DESC
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
