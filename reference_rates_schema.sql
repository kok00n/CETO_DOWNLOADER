-- Reference Rates - stopy/yieldy/FX z stooq.pl.
-- Wymaga juz odpalonego bondspot_schema.sql (uzywa bondspot_set_updated_at).
--
-- Series codes (matching scripts/refresh_reference_rates.py):
--   Stopy procentowe (value_pct = percent, np. 5.7500 = 5.75%):
--     'WIBOR6M' - WIBOR 6M daily fixing (stooq: plopln6m)
--     'POLSTR'  - POLSTR overnight (stooq: plspln00)
--     'CPI_YOY' - CPI rok do roku Polska, monthly (stooq: cpiypl.m)
--   Rentownosci benchmark 10Y govt bond (value_pct = percent yield):
--     'PL10Y'   - POLGB 10Y (stooq: 10yply.b)
--     'DE10Y'   - Bund 10Y (stooq: 10ydey.b)
--     'US10Y'   - UST 10Y (stooq: 10yusy.b)
--   FX (value_pct = poziom, jednostka waluty bazowej / waluta kwotowana):
--     'EURPLN'  - EUR/PLN (stooq: eurpln, np. 4.3243)
--     'USDPLN'  - USD/PLN (stooq: usdpln)
--     'EURUSD'  - EUR/USD (stooq: eurusd, np. 1.0823)
--
-- UWAGA naming: kolumna value_pct trzyma zarowno procenty jak i poziomy FX.
-- Interpretacja zalezna od series code (FX vs percent). Nazwa zostala dla
-- backward-compat z istniejacymi RPC reference_rate_at/latest.
--
-- Schema idempotentny - uzywa CREATE OR REPLACE bez wstepnego DROP.
-- (DROP zlamalby idempotentnosc gdyby cos w innych schemach mialo
-- dependency na reference_rate_at/latest, np. v_bond_servicing_cost
-- w dashboard_rpcs.sql).

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

-- =====================================================================
--  WIDOK: macro snapshot - jeden wiersz z najnowszymi wartosciami
--  wszystkich kluczowych serii + datami swiezosci. Konsumowany przez
--  notebook do injection do promptow LLM ('grounded macro context').
-- =====================================================================
CREATE OR REPLACE VIEW v_macro_snapshot_latest AS
SELECT
    (SELECT value_pct FROM reference_rates WHERE series='PL10Y'   ORDER BY rate_date DESC LIMIT 1) AS pl10y,
    (SELECT value_pct FROM reference_rates WHERE series='DE10Y'   ORDER BY rate_date DESC LIMIT 1) AS de10y,
    (SELECT value_pct FROM reference_rates WHERE series='US10Y'   ORDER BY rate_date DESC LIMIT 1) AS us10y,
    (SELECT value_pct FROM reference_rates WHERE series='WIBOR6M' ORDER BY rate_date DESC LIMIT 1) AS wibor6m,
    (SELECT value_pct FROM reference_rates WHERE series='POLSTR'  ORDER BY rate_date DESC LIMIT 1) AS polstr,
    (SELECT value_pct FROM reference_rates WHERE series='CPI_YOY' ORDER BY rate_date DESC LIMIT 1) AS cpi_yoy,
    (SELECT value_pct FROM reference_rates WHERE series='EURPLN'  ORDER BY rate_date DESC LIMIT 1) AS eurpln,
    (SELECT value_pct FROM reference_rates WHERE series='USDPLN'  ORDER BY rate_date DESC LIMIT 1) AS usdpln,
    (SELECT value_pct FROM reference_rates WHERE series='EURUSD'  ORDER BY rate_date DESC LIMIT 1) AS eurusd,
    (SELECT MAX(rate_date) FROM reference_rates WHERE series IN ('PL10Y','DE10Y','US10Y')) AS as_of_yields,
    (SELECT MAX(rate_date) FROM reference_rates WHERE series IN ('EURPLN','USDPLN','EURUSD')) AS as_of_fx,
    (SELECT MAX(rate_date) FROM reference_rates WHERE series IN ('WIBOR6M','POLSTR'))        AS as_of_rates;

-- =====================================================================
--  WIDOK: macro history 30d - do liczenia delty (latest vs ~30d temu).
--  Notebook bierze min(rate_date) i max(rate_date) per series w oknie
--  zeby pokazac modelowi 'WIBOR6M zmiana 30d: -25bp' = sygnal market
--  expectations. To DROGA bez FRA/OIS do wnioskowania o ruchach stop.
-- =====================================================================
CREATE OR REPLACE VIEW v_macro_history_30d AS
SELECT series, rate_date, value_pct
FROM reference_rates
WHERE rate_date >= CURRENT_DATE - INTERVAL '35 days'
  AND series IN ('PL10Y','DE10Y','US10Y','EURPLN','USDPLN','EURUSD','WIBOR6M','POLSTR')
ORDER BY series, rate_date;
