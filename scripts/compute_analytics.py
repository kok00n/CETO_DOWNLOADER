"""Compute ATM/ATR/MacDur/ModDur for every (fixing_date, fixing_session, isin)
that doesn't yet have a row in bondspot_analytics. Upserts results back.

Loops in chunks: RPC bondspot_missing_analytics returns up to CHUNK rows per
call (capped by PostgREST default 1000-row response), we compute + upsert,
then call again - the just-upserted rows are no longer "missing", so next
call returns the next chunk. Stops when nothing left OR MAX_ROWS_PER_RUN
reached. Crash-safe: progress persists after each upsert.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lib.calc import compute_metrics  # noqa: E402
from lib.supabase import rpc, select_all, upsert  # noqa: E402


MAX_ROWS_PER_RUN = int(os.environ.get("MAX_ROWS_PER_RUN", "200000"))
CHUNK = int(os.environ.get("CHUNK_SIZE", "1000"))  # matches PostgREST default cap


def main() -> None:
    print("[1/2] Loading bond_specs...", flush=True)
    specs = select_all(
        "bond_specs",
        "?select=isin,bond_type,coupon_kind,is_floating,issue_date,maturity_date,coupon_rate,coupon_freq",
    )
    by_isin = {s["isin"]: s for s in specs}
    print(f"  -> {len(by_isin)} bond_specs loaded", flush=True)

    print(f"[2/2] Looping in chunks of {CHUNK} (cap {MAX_ROWS_PER_RUN} per run)...", flush=True)
    started = time.time()
    total_in = 0
    total_out = 0
    skipped_no_spec_total: set[str] = set()
    skipped_past_maturity_total = 0
    iteration = 0

    while total_in < MAX_ROWS_PER_RUN:
        iteration += 1
        missing = rpc("bondspot_missing_analytics", {"p_limit": CHUNK})
        if not missing:
            print(f"  iter {iteration}: nothing left - done", flush=True)
            break

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

        if out:
            upsert(
                "bondspot_analytics",
                out,
                on_conflict="fixing_date,isin",
                batch_size=1000,
            )

        total_in += len(missing)
        total_out += len(out)
        skipped_no_spec_total |= skipped_no_spec
        skipped_past_maturity_total += skipped_past_maturity

        elapsed = time.time() - started
        rate = total_in / elapsed if elapsed > 0 else 0
        print(
            f"  iter {iteration:>4}: in={len(missing):>4} out={len(out):>4} "
            f"| total in={total_in:>6} out={total_out:>6} "
            f"| {rate:.0f} rows/s | {elapsed:.0f}s elapsed",
            flush=True,
        )

        # If RPC returned fewer than CHUNK, we've drained the queue
        if len(missing) < CHUNK:
            print(f"  iter {iteration}: short batch - queue drained", flush=True)
            break

    print("---", flush=True)
    print(f"Total fixing rows seen:     {total_in}", flush=True)
    print(f"Total analytics upserted:   {total_out}", flush=True)
    if skipped_no_spec_total:
        print(
            f"WARNING: {len(skipped_no_spec_total)} ISIN(s) without bond_specs "
            f"(first: {sorted(skipped_no_spec_total)[:10]})",
            flush=True,
        )
    if skipped_past_maturity_total:
        print(
            f"Info: {skipped_past_maturity_total} rows skipped (fixing >= maturity)",
            flush=True,
        )
    print("Done.", flush=True)


if __name__ == "__main__":
    main()
