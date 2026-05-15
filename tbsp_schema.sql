-- BondSpot TBSP - notowania obligacji PLN (PODSUMOWANIE OBROTU - OBLIGACJE PLN)
-- Source: https://www.bondspot.pl/notowania_TBSPoland?date=YYYYMMDD&month=MM&year=YYYY
-- Jedna sesja na dzien (vs fixingi gdzie sa dwie), wiec PK = (trade_date, isin).

-- =====================================================================
--  GLOWNA TABELA OBROTU PLN
-- =====================================================================
CREATE TABLE IF NOT EXISTS tbsp_trading (
    trade_date     DATE         NOT NULL,
    isin           VARCHAR(12)  NOT NULL,
    name           VARCHAR(32)  NOT NULL,
    bid_price      NUMERIC(10,4),    -- Cena K (%)  - najlepsza oferta kupna
    ask_price      NUMERIC(10,4),    -- Cena S (%)  - najlepsza oferta sprzedazy
    first_price    NUMERIC(10,4),    -- Transakcje: Pierwsza (%)
    max_price      NUMERIC(10,4),    -- Transakcje: Maks. (%)
    min_price      NUMERIC(10,4),    -- Transakcje: Min. (%)
    last_price     NUMERIC(10,4),    -- Transakcje: Ostatnia (%)
    avg_price      NUMERIC(10,4),    -- Transakcje: Srednia (%)
    volume         BIGINT,           -- Obroty: Wolumen (szt.)
    value_mln_pln  NUMERIC(14,4),    -- Obroty: Wartosc (mln zl)
    trade_count    INT,              -- Obroty: Liczba trans. (szt.)
    source_url     TEXT,
    inserted_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (trade_date, isin)
);

CREATE INDEX IF NOT EXISTS idx_tbsp_trading_isin_date
    ON tbsp_trading (isin, trade_date DESC);

CREATE INDEX IF NOT EXISTS idx_tbsp_trading_date
    ON tbsp_trading (trade_date DESC);

-- Trigger bumpujacy updated_at (reuze funkcji z bondspot, jesli juz istnieje)
CREATE OR REPLACE FUNCTION bondspot_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_tbsp_trading_updated_at ON tbsp_trading;
CREATE TRIGGER trg_tbsp_trading_updated_at
    BEFORE UPDATE ON tbsp_trading
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  LOG SCRAPOWANIA (jeden status per data, bo tu nie ma sesji)
-- =====================================================================
CREATE TABLE IF NOT EXISTS tbsp_scrape_log (
    trade_date      DATE         NOT NULL PRIMARY KEY,
    status          TEXT         NOT NULL CHECK (status IN ('ok','empty','error')),
    rows_count      INT,
    error_message   TEXT,
    source_url      TEXT,
    scraped_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tbsp_scrape_log_status
    ON tbsp_scrape_log (status, trade_date);

-- =====================================================================
--  FUNKCJA: brakujace dni (pon-pt) od p_from do CURRENT_DATE.
--  Dni z status='error' (lub brakiem wpisu) sa retryowane.
-- =====================================================================
CREATE OR REPLACE FUNCTION tbsp_missing_dates(
    p_from   DATE DEFAULT DATE '2011-01-01',
    p_limit  INT  DEFAULT 200
)
RETURNS TABLE (trade_date DATE)
LANGUAGE sql STABLE AS $$
    WITH calendar AS (
        SELECT d::DATE AS trade_date
        FROM generate_series(p_from, CURRENT_DATE, INTERVAL '1 day') AS d
        WHERE EXTRACT(ISODOW FROM d) BETWEEN 1 AND 5
    )
    SELECT c.trade_date
    FROM calendar c
    LEFT JOIN tbsp_scrape_log l ON l.trade_date = c.trade_date
    WHERE l.status IS NULL OR l.status = 'error'
    ORDER BY c.trade_date ASC
    LIMIT p_limit;
$$;

-- =====================================================================
--  WIDOKI POMOCNICZE
-- =====================================================================

-- Dzien z faktycznym obrotem (>0 transakcji)
CREATE OR REPLACE VIEW v_tbsp_trading_active AS
SELECT *
FROM tbsp_trading
WHERE trade_count IS NOT NULL AND trade_count > 0;

-- Postep backfillu
CREATE OR REPLACE VIEW v_tbsp_backfill_progress AS
WITH calendar AS (
    SELECT d::DATE AS trade_date
    FROM generate_series(DATE '2011-01-01', CURRENT_DATE, INTERVAL '1 day') AS d
    WHERE EXTRACT(ISODOW FROM d) BETWEEN 1 AND 5
),
expected AS (
    SELECT COUNT(*) AS total_days FROM calendar
),
done AS (
    SELECT
        COUNT(*) FILTER (WHERE status = 'ok')    AS days_ok,
        COUNT(*) FILTER (WHERE status = 'empty') AS days_empty,
        COUNT(*) FILTER (WHERE status = 'error') AS days_error,
        COUNT(*)                                 AS days_logged
    FROM tbsp_scrape_log
)
SELECT
    e.total_days,
    d.days_logged,
    d.days_ok,
    d.days_empty,
    d.days_error,
    e.total_days - d.days_logged AS days_remaining,
    ROUND(100.0 * d.days_logged / NULLIF(e.total_days,0), 2) AS pct_done
FROM expected e CROSS JOIN done d;
