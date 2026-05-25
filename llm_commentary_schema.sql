-- LLM Commentary - historia odpowiedzi modelu jezykowego per sekcja dashboard'u.
-- Wymaga juz odpalonego bondspot_schema.sql (uzywa bondspot_set_updated_at).
--
-- Kazdy render dashboard'u zapisuje per chart + final report:
--   - snapshot_date  = TODAY w momencie renderu
--   - section        = stabilny identyfikator sekcji (chart name lub "final_auction_report")
--   - prompt         = pelny prompt wyslany do modelu (debug + audit)
--   - response       = tekst odpowiedzi
--   - input/output_tokens = do trackowania kosztu
--
-- Przy nastepnym renderze LLM dostaje last N historycznych odpowiedzi tej sekcji
-- i moze sie do nich odwolac ('jak wskazywalem ostatnio...', 'trend kontynuuje...').
--
-- Schema idempotentny.

DROP FUNCTION IF EXISTS llm_commentary_history(TEXT, INT);

CREATE TABLE IF NOT EXISTS llm_commentary (
    id             BIGSERIAL PRIMARY KEY,
    rendered_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    snapshot_date  DATE NOT NULL,        -- TODAY w momencie renderu
    section        TEXT NOT NULL,        -- 'Chart N — name' lub 'final_auction_report'
    chart_name     TEXT,                 -- pelna nazwa chartu (audit)
    model          TEXT NOT NULL,        -- 'claude-opus-4-7' itd.
    prompt         TEXT NOT NULL,
    response       TEXT NOT NULL,
    input_tokens   INT,
    output_tokens  INT,
    inserted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_llm_commentary_section_date
    ON llm_commentary (section, snapshot_date DESC, rendered_at DESC);
CREATE INDEX IF NOT EXISTS idx_llm_commentary_rendered
    ON llm_commentary (rendered_at DESC);

-- =====================================================================
--  RPC: ostatnie N analiz dla danej sekcji (do injection do nowych promptow)
-- =====================================================================
CREATE OR REPLACE FUNCTION llm_commentary_history(
    p_section TEXT,
    p_limit   INT DEFAULT 3
)
RETURNS TABLE (
    snapshot_date DATE,
    rendered_at   TIMESTAMPTZ,
    response      TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT snapshot_date, rendered_at, response
    FROM llm_commentary
    WHERE section = p_section
    ORDER BY rendered_at DESC
    LIMIT p_limit;
$$;
