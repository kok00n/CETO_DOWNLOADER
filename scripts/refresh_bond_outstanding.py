"""Refresh bond_outstanding from the MF 'Obligacje hurtowe' XLSM.

Algorithm:
  1. Read Operacje sheet (every wholesale-bond auction/buyback since 1994)
  2. For each (isin, settlement_date): sum signed deltas
     (TypTransakcji='S' = +sale_amount, 'O' = -buyback_amount)
  3. Per ISIN, sort by settlement date, compute running balance
  4. Add a synthetic 'redemption' entry on each bond's DataWykupu (maturity)
     with delta = -final_balance, balance = 0 (so post-maturity queries
     correctly return 0 outstanding)
  5. Upsert to bond_outstanding

Amounts are in PLN mln (zgodnie z konwencja MF).
"""

from __future__ import annotations

import sys
from collections import defaultdict
from datetime import date, datetime
from io import BytesIO
from pathlib import Path

import openpyxl

sys.path.insert(0, str(Path(__file__).parent))
from lib.mf_xlsm import download_xlsm, find_xlsm_url  # noqa: E402
from lib.supabase import upsert  # noqa: E402


def _to_date(value) -> date | None:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    return None


def _to_float(value) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_outstanding(xlsm_bytes: BytesIO, source_url: str) -> list[dict]:
    wb = openpyxl.load_workbook(xlsm_bytes, read_only=True, data_only=True, keep_vba=False)
    ws = wb["Operacje"]
    headers = [c.value for c in next(ws.iter_rows(min_row=1, max_row=1))]

    # Step 1: aggregate deltas by (isin, settlement_date)
    deltas: dict[str, dict[date, float]] = defaultdict(lambda: defaultdict(float))
    op_kinds: dict[str, dict[date, set[str]]] = defaultdict(lambda: defaultdict(set))
    maturity_by_isin: dict[str, date] = {}

    for row in ws.iter_rows(min_row=2, values_only=True):
        d = dict(zip(headers, row))
        isin = d.get("KodISIN")
        if not isinstance(isin, str) or not isin:
            continue
        settle = _to_date(d.get("DataRozliczenia")) or _to_date(d.get("DataTransakcji"))
        if settle is None:
            continue
        # MF encodes sign in the amount itself: sales positive, buybacks
        # negative. We sum as-is and only use TypTransakcji to label op_type.
        amount = _to_float(d.get("SprzedażLubOdkupŁącznie")) or _to_float(
            d.get("Sprzedaż lub Odkup Łącznie")
        )
        if amount is None or amount == 0:
            continue
        type_tx = (d.get("TypTransakcji") or "").strip()
        if type_tx not in ("S", "O"):
            continue
        deltas[isin][settle] += amount
        op_kinds[isin][settle].add("sale" if type_tx == "S" else "buyback")

        mat = _to_date(d.get("DataWykupu"))
        if mat:
            maturity_by_isin[isin] = mat

    # Step 2: per ISIN, sort dates, compute running balance, add redemption
    rows: list[dict] = []
    for isin, by_date in deltas.items():
        balance = 0.0
        sorted_dates = sorted(by_date.keys())
        last_change_date = sorted_dates[-1] if sorted_dates else None
        for cd in sorted_dates:
            delta = by_date[cd]
            balance += delta
            kinds = op_kinds[isin][cd]
            if len(kinds) == 1:
                op_type = next(iter(kinds))
            else:
                op_type = "mixed"
            rows.append({
                "isin": isin,
                "change_date": cd.isoformat(),
                "delta_mln_pln": round(delta, 3),
                "balance_mln_pln": round(max(balance, 0.0), 3),
                "op_type": op_type,
                "source_url": source_url,
            })

        # Synthetic redemption row on maturity (only if balance still positive
        # and maturity is AFTER the last recorded change; otherwise the bond
        # was fully bought back early or maturity already encoded somewhere).
        mat = maturity_by_isin.get(isin)
        if mat and balance > 0.001 and (last_change_date is None or mat > last_change_date):
            rows.append({
                "isin": isin,
                "change_date": mat.isoformat(),
                "delta_mln_pln": -round(balance, 3),
                "balance_mln_pln": 0.0,
                "op_type": "redemption",
                "source_url": source_url,
            })

    return rows


def main() -> None:
    print("[1/4] Locating MF Obligacje_Hurtowe.xlsm URL...", flush=True)
    url = find_xlsm_url()
    print(f"  -> {url}", flush=True)

    print("[2/4] Downloading XLSM...", flush=True)
    xlsm = download_xlsm(url)
    print(f"  -> {xlsm.getbuffer().nbytes / 1024:.0f} KB", flush=True)

    print("[3/4] Parsing Operacje sheet, building running balances...", flush=True)
    rows = parse_outstanding(xlsm, url)
    distinct_isins = len({r["isin"] for r in rows})
    redemptions = sum(1 for r in rows if r["op_type"] == "redemption")
    print(
        f"  -> {len(rows)} balance-change rows across {distinct_isins} ISINs "
        f"({redemptions} synthetic redemptions)",
        flush=True,
    )

    # Print a few sanity samples (top 5 ISINs by current balance)
    latest_by_isin: dict[str, dict] = {}
    for r in rows:
        prev = latest_by_isin.get(r["isin"])
        if prev is None or r["change_date"] > prev["change_date"]:
            latest_by_isin[r["isin"]] = r
    active = [r for r in latest_by_isin.values() if r["balance_mln_pln"] > 0]
    active.sort(key=lambda r: r["balance_mln_pln"], reverse=True)
    print("  -> top 5 by current balance (PLN mln):", flush=True)
    for r in active[:5]:
        print(f"     {r['isin']}  {r['balance_mln_pln']:>14,.1f}  "
              f"(last change {r['change_date']}, {r['op_type']})", flush=True)

    print("[4/4] Upserting to bond_outstanding (batched)...", flush=True)
    posted = upsert("bond_outstanding", rows, on_conflict="isin,change_date", batch_size=1000)
    print(f"  -> {posted} rows posted", flush=True)
    print("Done.", flush=True)


if __name__ == "__main__":
    main()
