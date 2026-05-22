-- Reference Rates - WIBOR/POLSTR/CPI fetched from stooq.pl.
-- Wymaga juz odpalonego bondspot_schema.sql (uzywa bondspot_set_updated_at).
--
-- Wartosci to procent (np. 5.7500 = 5.75%).
-- Series codes (matching scripts/refresh_reference_rates.py):
--   'WIBOR6M' - WIBOR 6M daily fixing (stooq: plopln6m)
--   'POLSTR'  - POLSTR overnight (stooq: plspln00)
--   'CPI_YOY' - CPI rok do roku Polska, monthly (stooq: cpiypl.m)
--
-- Schema idempotentny.

DROP FUNCTION IF EXISTS reference_rate_at(TEXT, DATE);
DROP FUNCTION IF EXISTS reference_rate_latest(TEXT);

CREATE TABLE IF NOT EXISTS reference_rates (
    series       TEXT NOT NULL,         -- 'WIBOR6M' | 'POLSTR' | 'CPI_YOY'
    rate_date    DATE NOT NULL,
    value_pct    NUMERIC(8,4) NOT NULL, -- percent (5.75 = 5.75%)
    source       TEXT NOT NULL DEFAULT 'stooq',
    source_url   TEXT,
    inserted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (series, rate_date)
);

CREATE INDEX IF NOT EXISTS idx_reference_rates_series_date
    ON reference_rates (series, rate_date DESC);

DROP TRIGGER IF EXISTS trg_reference_rates_updated_at ON reference_rates;
CREATE TRIGGER trg_reference_rates_updated_at
    BEFORE UPDATE ON reference_rates
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- RPC: ostatnia wartosc <= podanej daty
CREATE OR REPLACE FUNCTION reference_rate_at(p_series TEXT, p_date DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT value_pct FROM reference_rates
    WHERE series = p_series AND rate_date <= p_date
    ORDER BY rate_date DESC LIMIT 1;
$$;

-- RPC: latest wartosc dla danej series
CREATE OR REPLACE FUNCTION reference_rate_latest(p_series TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT value_pct FROM reference_rates
    WHERE series = p_series
    ORDER BY rate_date DESC LIMIT 1;
$$;
