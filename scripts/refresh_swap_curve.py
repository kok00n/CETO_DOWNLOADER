"""Refresh PLN swap curve snapshot z bluegamma.io (public, no-auth).

Source URL (publicznie dostepny, bez logowania):
    https://app.bluegamma.io/public/swap-rates/pln

Strona to Next.js SSR z RSC payload - dane sa w HTML jako embedded
React Server Components. Wyciagamy przez regex po '"children":"VALUE"'
patterns + zmiany d1 jako osobne {"value":...} pola.

Struktura tabeli (przyklad fragmentu):
    Tenor | Rate  | 1 day ago | 1d change
    6M    | 3.95% | 3.96%     | -0.01
    1Y    | 4.45% | 4.48%     | -0.03
    ...
    20Y   | 5.37% | 5.41%     | -0.04

Idempotentny - upsert ON CONFLICT (rate_date, tenor) DO UPDATE.

Tradeoff fragility:
- Bluegamma to startup, struktura strony moze sie zmienic
- Workflow ma continue-on-error, jak parse fail to LLM nie dostanie swap
  block ale reszta dashboard'u dziala
"""

from __future__ import annotations

import os
import re
import sys
from datetime import date as _date
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
from lib.supabase import upsert  # noqa: E402


SOURCE_URL = "https://app.bluegamma.io/public/swap-rates/pln"
UA = "Mozilla/5.0 (compatible; CETO-dashboard/1.0; +github.com/kok00n/CETO_DOWNLOADER)"
TIMEOUT_S = 30

# Mapping tenor string -> miesiace (do sortowania krzywej + delty 1Y-6M itd)
TENOR_TO_MONTHS = {
    "6M": 6, "1Y": 12, "18M": 18, "2Y": 24, "3Y": 36, "4Y": 48,
    "5Y": 60, "6Y": 72, "7Y": 84, "8Y": 96, "9Y": 108, "10Y": 120,
    "12Y": 144, "15Y": 180, "20Y": 240,
}


def fetch_html() -> str:
    r = requests.get(SOURCE_URL, headers={"User-Agent": UA}, timeout=TIMEOUT_S)
    r.raise_for_status()
    return r.text


def parse_curve(html: str) -> tuple[_date, list[dict]]:
    """Returns (snapshot_date, [{tenor, tenor_months, rate_pct, prev_day_pct, change_pp}, ...]).

    Raises RuntimeError if parsing fails (struktura strony sie zmienila).
    """
    # Wszystkie "children":"VALUE" patterns w kolejnosci tabeli
    cells = re.findall(r'\\"children\\":\\"([^\\"]+)\\"', html)
    if not cells:
        raise RuntimeError("No table cells found - page structure changed?")

    try:
        start = cells.index("Tenor")
    except ValueError:
        raise RuntimeError("'Tenor' header not found in cells")

    # Header: [Tenor, Rate, 1 day ago, 1d change], potem rows po 3 cells string
    # (4. column 1d change to React component, nie string, lapie sie osobno)
    headers = cells[start:start + 4]
    if headers[:3] != ["Tenor", "Rate", "1 day ago"]:
        raise RuntimeError(f"Unexpected headers: {headers!r}")

    body = cells[start + 4:]
    # Group by 3: [tenor_label, today_pct, prev_pct]
    rows = []
    for i in range(0, len(body) - 2, 3):
        label, today_s, prev_s = body[i], body[i + 1], body[i + 2]
        # label: 'PLN 6M Swap Rate' -> '6M'
        m = re.match(r"PLN\s+(\d+[YMW])\s+Swap Rate", label)
        if not m:
            # Stop at first non-row (np. footer text)
            break
        tenor = m.group(1)
        months = TENOR_TO_MONTHS.get(tenor)
        if months is None:
            print(f"[swap] WARN: nieznany tenor {tenor!r} - skip", flush=True)
            continue
        try:
            today = float(today_s.rstrip("%"))
            prev = float(prev_s.rstrip("%"))
        except ValueError:
            print(f"[swap] WARN: nie-numeryczny rate dla {tenor}: {today_s!r}/{prev_s!r}", flush=True)
            continue
        rows.append({
            "tenor": tenor,
            "tenor_months": months,
            "rate_pct": round(today, 4),
            "prev_day_pct": round(prev, 4),
            "change_pp": round(today - prev, 4),
        })

    if not rows:
        raise RuntimeError("Parsed 0 rows - struktura strony sie zmienila")

    # Snapshot date - bluegamma renderuje '$D2026-05-22T13:00:00.000Z' na dole
    m_date = re.search(r"\$D(\d{4}-\d{2}-\d{2})T\d{2}:\d{2}:\d{2}", html)
    if not m_date:
        # Fallback: dzisiaj
        snapshot_date = _date.today()
        print(f"[swap] WARN: brak date w HTML, uzywam today={snapshot_date}", flush=True)
    else:
        from datetime import datetime
        snapshot_date = datetime.strptime(m_date.group(1), "%Y-%m-%d").date()

    return snapshot_date, rows


def main() -> None:
    print(f"[swap] fetching {SOURCE_URL}...", flush=True)
    html = fetch_html()
    print(f"[swap] got {len(html)} bytes", flush=True)

    snapshot_date, rows = parse_curve(html)
    print(f"[swap] parsed {len(rows)} tenors for {snapshot_date}:", flush=True)
    for r in rows:
        print(f"   {r['tenor']:>4s}: {r['rate_pct']:.2f}%  "
              f"(prev {r['prev_day_pct']:.2f}, Δ {r['change_pp']:+.2f}pp)",
              flush=True)

    payload = [{
        "rate_date": snapshot_date.isoformat(),
        "tenor": r["tenor"],
        "tenor_months": r["tenor_months"],
        "rate_pct": r["rate_pct"],
        "prev_day_pct": r["prev_day_pct"],
        "change_pp": r["change_pp"],
        "source_url": SOURCE_URL,
    } for r in rows]

    posted = upsert("swap_curve_pln", payload,
                    on_conflict="rate_date,tenor", batch_size=100)
    print(f"[swap] upserted {posted} rows.", flush=True)


if __name__ == "__main__":
    main()
