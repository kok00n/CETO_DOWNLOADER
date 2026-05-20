"""Compute ATM/ATR/MacDur/ModDur for every (fixing_date, fixing_session, isin)
that doesn't yet have a row in bondspot_analytics. Upserts results back.

Pulls missing rows via RPC bondspot_missing_analytics(p_limit) and joins them
locally with bond_specs (loaded once into a dict).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lib.calc import compute_metrics  # noqa: E402
from lib.supabase import rpc, select_all, upsert  # noqa: E402


MAX_ROWS_PER_RUN = int(os.environ.get("MAX_ROWS_PER_RUN", "200000"))


def main() -> None:
    print("[1/3] Loading bond_specs...", flush=True)
    specs = select_all(
        "bond_specs",
        "?select=isin,bond_type,coupon_kind,is_floating,issue_date,maturity_date,coupon_rate,coupon_freq",
    )
    by_isin = {s["isin"]: s for s in specs}
    print(f"  -> {len(by_isin)} bond_specs loaded", flush=True)

    print(f"[2/3] Fetching missing analytics rows (limit={MAX_ROWS_PER_RUN})...", flush=True)
    missing = rpc("bondspot_missing_analytics", {"p_limit": MAX_ROWS_PER_RUN})
    print(f"  -> {len(missing)} fixing rows to compute", flush=True)

    if not missing:
        print("Nothing to do.", flush=True)
        return

    print("[3/3] Computing + upserting...", flush=True)
    out: list[dict] = []
    skipped_no_spec: set[str] = set()
    skipped_past_maturity = 0
    for fixing in missing:
        isin = fixing["isin"]
        spec = by_isin.get(isin)
        if spec is None:
            skipped_no_spec.add(isin)
            continue
        rec = compute_metrics(spec, fixing)
        if rec is None:
            skipped_past_maturity += 1
            continue
        out.append(rec)

    print(f"  -> {len(out)} analytics rows ready", flush=True)
    if skipped_no_spec:
        print(
            f"  -> WARNING: {len(skipped_no_spec)} ISIN(s) without bond_specs - "
            f"skipped. First few: {sorted(skipped_no_spec)[:10]}",
            flush=True,
        )
    if skipped_past_maturity:
        print(
            f"  -> info: {skipped_past_maturity} rows skipped (fixing >= maturity)",
            flush=True,
        )

    if out:
        posted = upsert(
            "bondspot_analytics",
            out,
            on_conflict="fixing_date,fixing_session,isin",
            batch_size=1000,
        )
        print(f"  -> {posted} rows upserted", flush=True)

    print("Done.", flush=True)


if __name__ == "__main__":
    main()
