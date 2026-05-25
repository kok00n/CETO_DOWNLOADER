-- PLN Swap Curve - krzywa PLN 6M WIBOR swap rates (par yields) z bluegamma.io.
-- Wymaga juz odpalonego bondspot_schema.sql (uzywa bondspot_set_updated_at).
--
-- Bluegamma publikuje publicznie (bez logowania) snapshot krzywej swapowej
-- na stronie:
--   https://app.bluegamma.io/public/swap-rates/pln
-- Tabela ma per tenor (6M, 1Y, 18M, 2Y, ..., 20Y) wartosci na ostatnia
-- sesje + dzien poprzedni + zmiana 1d. Update raz dziennie po sesji LDN/WAW.
--
-- Dlaczego to wazne dla LLM commentary:
--   Krzywa swap = market-implied scieżka stop. Inverted front-end (1Y < 6M)
--   = rynek wycenia cuts. Steep belly = expansion expectations. Tym samym
--   model NIE MUSI zgadywac z treningu czy NBP bedzie tnac/podnosic - widzi
--   realne kwotowania i moze sie do nich odwolac konkretnie ("krzywa 1Y/2Y
--   plaska na poziomie 4.45% = brak material price action w 12M").
--
-- Schema idempotentny.

DROP VIEW IF EXISTS v_swap_curve_pln_latest;

CREATE TABLE IF NOT EXISTS swap_curve_pln (
    rate_date     DATE         NOT NULL,
    tenor         TEXT         NOT NULL,    -- '6M', '1Y', '18M', '2Y', ..., '20Y'
    tenor_months  INT          NOT NULL,    -- 6, 12, 18, 24, ..., 240 (sortowanie + delty)
    rate_pct      NUMERIC(8,4) NOT NULL,    -- 4.4500 = 4.45%
    prev_day_pct  NUMERIC(8,4),             -- snapshot D-1 z tego samego fetch
    change_pp     NUMERIC(8,4),             -- rate_pct - prev_day_pct (signed)
    source        TEXT         NOT NULL DEFAULT 'bluegamma',
    source_url    TEXT,
    inserted_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (rate_date, tenor)
);

CREATE INDEX IF NOT EXISTS idx_swap_curve_pln_date
    ON swap_curve_pln (rate_date DESC);

DROP TRIGGER IF EXISTS trg_swap_curve_pln_updated_at ON swap_curve_pln;
CREATE TRIGGER trg_swap_curve_pln_updated_at
    BEFORE UPDATE ON swap_curve_pln
    FOR EACH ROW
    EXECUTE FUNCTION bondspot_set_updated_at();

-- =====================================================================
--  WIDOK: ostatnia dostepna krzywa (jeden snapshot, posortowany po tenor)
--  Konsumowany przez notebook do injection do promptu LLM - model dostaje
--  pelna krzywa zamiast pojedynczych punktow.
-- =====================================================================
CREATE OR REPLACE VIEW v_swap_curve_pln_latest AS
WITH latest AS (
    SELECT MAX(rate_date) AS d FROM swap_curve_pln
)
SELECT s.rate_date, s.tenor, s.tenor_months, s.rate_pct,
       s.prev_day_pct, s.change_pp
FROM swap_curve_pln s
JOIN latest l ON s.rate_date = l.d
ORDER BY s.tenor_months;
