"""Gate: render dashboard tylko gdy jest NOWA aukcja od ostatniego renderu.

Logika:
  Porownuje MAX(bond_auctions.auction_date) z MAX(llm_commentary.snapshot_date
  WHERE section='final_auction_report'). Jesli ostatnia aukcja nowsza niz
  ostatni final report -> has_new=true (render leci, LLM placi).
  Inaczej has_new=false (render skip, $0 LLM cost).

Edge cases:
  - bond_auctions pusty (bootstrap)              -> has_new=true (force initial render)
  - llm_commentary pusty (pierwszy ever render)  -> has_new=true (bootstrap)
  - last_auction == last_report                  -> has_new=false (no new auction)

Output:
  Pisze do $GITHUB_OUTPUT:
    has_new        = 'true' | 'false'
    last_auction   = 'YYYY-MM-DD' | 'none'
    last_report    = 'YYYY-MM-DD' | 'none'

Wymaga env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
"""

from __future__ import annotations

import os
import sys

import requests


def main() -> None:
    supabase_url = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}

    def fetch_one(url: str) -> dict | None:
        r = requests.get(url, headers=headers, timeout=30)
        r.raise_for_status()
        rows = r.json()
        return rows[0] if rows else None

    # Ostatnia aukcja w bond_auctions (po publikacji wynikow MF)
    auction_row = fetch_one(
        f"{supabase_url}/rest/v1/bond_auctions"
        "?select=auction_date&order=auction_date.desc&limit=1"
    )
    last_auction = auction_row["auction_date"] if auction_row else None

    # Ostatni final_auction_report w llm_commentary (snapshot poprzedniego renderu)
    report_row = fetch_one(
        f"{supabase_url}/rest/v1/llm_commentary"
        "?section=eq.final_auction_report&select=snapshot_date"
        "&order=snapshot_date.desc&limit=1"
    )
    last_report = report_row["snapshot_date"] if report_row else None

    if last_auction is None:
        has_new = True
        reason = "no bond_auctions rows yet - bootstrap"
    elif last_report is None:
        has_new = True
        reason = "no prior final reports - bootstrap"
    else:
        has_new = last_auction > last_report
        reason = (
            f"last_auction={last_auction} {'>' if has_new else '<='} "
            f"last_report={last_report}"
        )

    print(f"[gate] has_new={has_new} ({reason})")

    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a", encoding="utf-8") as f:
            f.write(f"has_new={'true' if has_new else 'false'}\n")
            f.write(f"last_auction={last_auction or 'none'}\n")
            f.write(f"last_report={last_report or 'none'}\n")


if __name__ == "__main__":
    main()
