-- BondSpot Fixing Obligacji - schema
-- Source: https://www.bondspot.pl/fixing_obligacji
-- Tabela trzyma oba fixingi (1 i 2) per dzien, per ISIN.

-- =====================================================================
--  GLOWNA TABELA Z FIXINGAMI
-- =====================================================================
CREATE TABLE IF NOT EXISTS bondspot_fixing (
    fixing_date     DATE         NOT NULL,
    fixing_session  SMALLINT     NOT NULL CHECK (fixing_session IN (1, 2)),
    isin            VARCHAR(12)  NOT NULL,
    lp              SMALLINT,
    name            VARCHAR(32)  NOT NULL,    -- bumped z 20 (zdarzaja sie dluzsze symbole)
    bid_price       NUMERIC(10,4),            -- Cena K (kupna)
    ask_price       NUMERIC(10,4),            -- Cena S (sprzedazy)
    bid_yield       NUMERIC(8,4),             -- Rent.K   (NULL dla WZ/IZ)
    ask_yield       NUMERIC(8,4),             -- Rent.S   (NULL dla WZ/IZ)
    fixing_price    NUMERIC(10,4),            -- Cena fix
    fixing_yield    NUMERIC(8,4),             -- Rent fix (NULL dla WZ/IZ)
    source_url      TEXT,                     -- audit: skad pobrano
    inserted_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (fixing_date, fixing_session, isin)
);

CREATE INDEX IF NOT EXISTS idx_bondspot_fixing_isin_date
    ON bondspot_fixing (isin, fixing_date DESC);

CREATE INDEX IF NOT EXISTS idx_bondspot_fixing_date
    ON bondspot_fixing (fixing_date DESC);

-- Trigger bumpujacy updated_at na UPDATE
CREATE OR REPLACE FUNCTION bondspot_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_bondspot_fixing_updated_at ON bondspot_fixing;
CREATE TRIGGER trg_bondspot_fixing_updated_at
    BEFORE UPDATE ON bondspot_fixing
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  LOG SCRAPOWANIA - per (data, sesja). Pozwala odroznic:
--   'ok'    - sciagnieto N wierszy
--   'empty' - strona istnieje ale brak tabeli (weekend / swieto / brak danych)
--   'error' - blad sieciowy / parsera
-- =====================================================================
CREATE TABLE IF NOT EXISTS bondspot_scrape_log (
    fixing_date     DATE         NOT NULL,
    fixing_session  SMALLINT     NOT NULL CHECK (fixing_session IN (1, 2)),
    status          TEXT         NOT NULL CHECK (status IN ('ok','empty','error')),
    rows_count      INT,
    error_message   TEXT,
    source_url      TEXT,
    scraped_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (fixing_date, fixing_session)
);

CREATE INDEX IF NOT EXISTS idx_bondspot_scrape_log_status
    ON bondspot_scrape_log (status, fixing_date);

-- =====================================================================
--  FUNKCJA: lista (data, sesja) ktore wymagaja jeszcze scrapowania.
--  Zwraca daty robocze (pon-pt) od p_from do CURRENT_DATE,
--  ktorych brakuje w bondspot_scrape_log albo dla ktorych ostatnia
--  proba zakonczyla sie statusem 'error'. Posortowane od najstarszych.
-- =====================================================================
CREATE OR REPLACE FUNCTION bondspot_missing_fixings(
    p_from   DATE DEFAULT DATE '2011-01-01',
    p_limit  INT  DEFAULT 200
)
RETURNS TABLE (fixing_date DATE, fixing_session SMALLINT)
LANGUAGE sql STABLE AS $$
    WITH calendar AS (
        SELECT d::DATE AS fixing_date
        FROM generate_series(p_from, CURRENT_DATE, INTERVAL '1 day') AS d
        WHERE EXTRACT(ISODOW FROM d) BETWEEN 1 AND 5
    ),
    sessions AS (
        SELECT 1::SMALLINT AS s UNION ALL SELECT 2::SMALLINT
    ),
    pairs AS (
        SELECT c.fixing_date, s.s AS fixing_session
        FROM calendar c CROSS JOIN sessions s
    )
    SELECT p.fixing_date, p.fixing_session
    FROM pairs p
    LEFT JOIN bondspot_scrape_log l
      ON l.fixing_date = p.fixing_date
     AND l.fixing_session = p.fixing_session
    WHERE l.status IS NULL OR l.status = 'error'
    ORDER BY p.fixing_date ASC, p.fixing_session ASC
    LIMIT p_limit;
$$;

-- =====================================================================
--  WIDOKI POMOCNICZE
-- =====================================================================

-- Tylko fixing 2 (referencyjny do konca dnia)
CREATE OR REPLACE VIEW v_bondspot_fixing_eod AS
SELECT *
FROM bondspot_fixing
WHERE fixing_session = 2;

-- Spread bid/ask w bp dla obligacji o stalym kuponie
CREATE OR REPLACE VIEW v_bondspot_fixing_spread AS
SELECT
    fixing_date,
    fixing_session,
    isin,
    name,
    fixing_price,
    fixing_yield,
    (ask_yield - bid_yield) * 100 AS bid_ask_spread_bp
FROM bondspot_fixing
WHERE bid_yield IS NOT NULL AND ask_yield IS NOT NULL;

-- Postep backfillu: ile sesji juz zaciagnietych vs pozostalo
CREATE OR REPLACE VIEW v_bondspot_backfill_progress AS
WITH calendar AS (
    SELECT d::DATE AS fixing_date
    FROM generate_series(DATE '2011-01-01', CURRENT_DATE, INTERVAL '1 day') AS d
    WHERE EXTRACT(ISODOW FROM d) BETWEEN 1 AND 5
),
expected AS (
    SELECT COUNT(*) * 2 AS total_sessions FROM calendar
),
done AS (
    SELECT
        COUNT(*) FILTER (WHERE status = 'ok')    AS sessions_ok,
        COUNT(*) FILTER (WHERE status = 'empty') AS sessions_empty,
        COUNT(*) FILTER (WHERE status = 'error') AS sessions_error,
        COUNT(*)                                 AS sessions_logged
    FROM bondspot_scrape_log
)
SELECT
    e.total_sessions,
    d.sessions_logged,
    d.sessions_ok,
    d.sessions_empty,
    d.sessions_error,
    e.total_sessions - d.sessions_logged AS sessions_remaining,
    ROUND(100.0 * d.sessions_logged / NULLIF(e.total_sessions,0), 2) AS pct_done
FROM expected e CROSS JOIN done d;
