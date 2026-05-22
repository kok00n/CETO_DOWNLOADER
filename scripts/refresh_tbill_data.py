"""Refresh tbill_specs + tbill_outstanding from MF Bony_Skarbowe.xls.

Single script because both tables come from the same source file. Mirrors
the bond_outstanding approach: forward-walk Operacje, reconcile to Zadluzenie
snapshot for the small set of currently-active bills, add synthetic
redemption at maturity for already-matured ones.

T-bills are zero-coupon, so specs are minimal (issue/maturity/tenor only).
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta
from io import BytesIO
from pathlib import Path

import xlrd

sys.path.insert(0, str(Path(__file__).parent))
from lib.mf_bony import download_xls, find_xls_url  # noqa: E402
from lib.supabase import upsert  # noqa: E402


_SNAPSHOT_DATE_RX = re.compile(
    r"stanu\s+na\s+(\d{2})\.(\d{2})\.(\d{4})", re.IGNORECASE
)
_EXCEL_EPOCH = datetime(1899, 12, 30)


def _excel_to_date(value) -> date | None:
    """Convert Excel serial number (or datetime/str) to date."""
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    try:
        n = float(value)
        if n <= 0:
            return None
        return (_EXCEL_EPOCH + timedelta(days=n)).date()
    except (TypeError, ValueError):
        return None


def _to_float(value) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_zadluzenie(xls_bytes: BytesIO) -> tuple[dict[str, float], date | None]:
    """Parse Zadluzenie_Outstanding sheet. Returns ({isin: balance}, snapshot_date).

    Format: header rows with "lacze zadluzenie wedlug stanu na DD.MM.YYYY" text,
    then per-bill rows with columns: maturity_date_excel, ISIN, PLN_mln.
    """
    xls_bytes.seek(0)
    wb = xlrd.open_workbook(file_contents=xls_bytes.read())
    # bilingual sheet name "Zadłużenie_Outstanding"
    sheet_name = next((s for s in wb.sheet_names() if "stand" in s.lower()
                       or "zad" in s.lower()), None)
    if sheet_name is None:
        return {}, None
    ws = wb.sheet_by_name(sheet_name)

    snapshot_date: date | None = None
    balances: dict[str, float] = {}
    for i in range(ws.nrows):
        first = ws.cell_value(i, 0) if ws.ncols > 0 else ""
        if isinstance(first, str) and snapshot_date is None:
            m = _SNAPSHOT_DATE_RX.search(first)
            if m:
                dd, mm, yyyy = m.groups()
                try:
                    snapshot_date = date(int(yyyy), int(mm), int(dd))
                except ValueError:
                    pass

        # Bill rows: col 0 = maturity (Excel serial), col 1 = ISIN, col 2 = balance
        if ws.ncols >= 3:
            isin = ws.cell_value(i, 1)
            bal = ws.cell_value(i, 2)
            if isinstance(isin, str) and isin.startswith("PL"):
                f = _to_float(bal)
                if f is not None:
                    balances[isin.strip()] = f

    return balances, snapshot_date


def parse_tbill_data(
    xls_bytes: BytesIO, source_url: str
) -> tuple[list[dict], list[dict]]:
    """Returns (specs_rows, outstanding_rows). Both upserted to their tables."""
    xls_bytes.seek(0)
    wb = xlrd.open_workbook(file_contents=xls_bytes.read())
    sheet_name = next((s for s in wb.sheet_names() if "perac" in s.lower()), None)
    if sheet_name is None:
        raise RuntimeError("Could not find Operacje sheet in Bony_Skarbowe.xls")
    ws = wb.sheet_by_name(sheet_name)

    # Column indices (positional - headers bilingual with newlines; layout stable)
    COL_AUCTION = 1  # DataTransakcji (auction/transaction date)
    COL_SETTLE = 2   # DataRozliczenia (settlement date)
    COL_TYPE_TX = 3
    COL_TYPE_OP = 4
    COL_RODZAJ = 5
    COL_MATURITY = 6
    COL_ISIN = 7
    COL_AMOUNT = 12  # Sprzedaż/Odkup Łącznie

    # Aggregate per (isin, settle_date); track earliest settle + maturity per ISIN.
    # Also track MIN auction_date per (isin, settle_date) - dla dashboard chartow:
    # jak aukcja sie odbyla ale settlement jeszcze nie (T+1/T+2), chcemy pokazac
    # outstanding na auction_date a nie czekac do settlement.
    deltas: dict[str, dict[date, float]] = defaultdict(lambda: defaultdict(float))
    op_kinds: dict[str, dict[date, set[str]]] = defaultdict(lambda: defaultdict(set))
    auction_dates: dict[str, dict[date, date]] = defaultdict(dict)  # (isin,settle) -> min auction
    earliest_settle: dict[str, date] = {}
    maturity_by_isin: dict[str, date] = {}
    rodzaj_by_isin: dict[str, str] = {}

    for i in range(1, ws.nrows):
        isin = ws.cell_value(i, COL_ISIN)
        if not isinstance(isin, str) or not isin:
            continue
        settle = _excel_to_date(ws.cell_value(i, COL_SETTLE))
        if settle is None:
            continue
        amount = _to_float(ws.cell_value(i, COL_AMOUNT))
        if amount is None or amount == 0:
            continue
        type_tx = str(ws.cell_value(i, COL_TYPE_TX) or "").strip()
        if type_tx not in ("S", "O"):
            continue
        # Sign convention: MF encodes buyback as negative amount (like bondy)
        deltas[isin][settle] += amount
        op_kinds[isin][settle].add("sale" if type_tx == "S" else "buyback")

        auction = _excel_to_date(ws.cell_value(i, COL_AUCTION))
        if auction is not None:
            prior = auction_dates[isin].get(settle)
            if prior is None or auction < prior:
                auction_dates[isin][settle] = auction

        mat = _excel_to_date(ws.cell_value(i, COL_MATURITY))
        if mat:
            maturity_by_isin[isin] = mat
        if isin not in earliest_settle or settle < earliest_settle[isin]:
            earliest_settle[isin] = settle
        rodzaj = str(ws.cell_value(i, COL_RODZAJ) or "").strip()
        if rodzaj:
            rodzaj_by_isin[isin] = rodzaj

    # Reconciliation truth
    xls_bytes.seek(0)
    zad_balances, snapshot_date = parse_zadluzenie(xls_bytes)
    if snapshot_date is None:
        print("  ! WARN: snapshot date not found in Zadluzenie header", flush=True)

    # Build specs rows
    specs_rows: list[dict] = []
    for isin in sorted(set(maturity_by_isin) | set(earliest_settle)):
        mat = maturity_by_isin.get(isin)
        issue = earliest_settle.get(isin)
        if mat is None:
            continue
        tenor = (mat - issue).days if issue else None
        specs_rows.append({
            "isin": isin,
            "bill_type": rodzaj_by_isin.get(isin) or "",
            "tenor_days": tenor,
            "issue_date": issue.isoformat() if issue else None,
            "maturity_date": mat.isoformat(),
            "source": "mf_xls",
            "source_url": source_url,
        })

    # Build outstanding rows (forward walk + reconciliation + redemption)
    out_rows: list[dict] = []
    for isin, by_date in deltas.items():
        sorted_dates = sorted(by_date.keys())
        balance = 0.0
        balance_at_snapshot: float | None = None
        for cd in sorted_dates:
            delta = by_date[cd]
            balance += delta
            kinds = op_kinds[isin][cd]
            op_type = next(iter(kinds)) if len(kinds) == 1 else "mixed"
            ad = auction_dates[isin].get(cd)
            out_rows.append({
                "isin": isin,
                "change_date": cd.isoformat(),
                "auction_date": ad.isoformat() if ad else None,
                "delta_mln_pln": round(delta, 3),
                "balance_mln_pln": round(max(balance, 0.0), 3),
                "op_type": op_type,
                "source": "mf_xls",
                "source_url": source_url,
            })
            if snapshot_date and cd <= snapshot_date:
                balance_at_snapshot = balance

        last_change_date = sorted_dates[-1] if sorted_dates else None
        mat = maturity_by_isin.get(isin)

        # Reconciliation to Zadluzenie truth
        if snapshot_date and last_change_date and snapshot_date >= sorted_dates[0]:
            target: float | None = zad_balances.get(isin)
            if target is None and balance > 0.001 and mat and mat > snapshot_date:
                target = 0.0
            if target is not None and balance_at_snapshot is not None:
                diff = target - balance_at_snapshot
                if abs(diff) > 0.005:
                    recon_date = snapshot_date
                    if recon_date in by_date:
                        recon_date = recon_date + timedelta(days=1)
                    out_rows.append({
                        "isin": isin,
                        "change_date": recon_date.isoformat(),
                        "auction_date": None,  # recon nie pochodzi z aukcji
                        "delta_mln_pln": round(diff, 3),
                        "balance_mln_pln": round(target, 3),
                        "op_type": "reconciliation",
                        "source": "mf_xls",
                        "source_url": source_url,
                    })
                    balance = target

        # Redemption at maturity (mat+1 if collides with last op, typical for bills)
        if mat and balance > 0.001:
            last_rec = max(
                (date.fromisoformat(r["change_date"]) for r in out_rows if r["isin"] == isin),
                default=None,
            )
            if last_rec is None or mat > last_rec:
                redemption_date = mat
            elif mat == last_rec:
                redemption_date = mat + timedelta(days=1)
            else:
                redemption_date = None
            if redemption_date is not None:
                out_rows.append({
                    "isin": isin,
                    "change_date": redemption_date.isoformat(),
                    "auction_date": None,  # redemption nie pochodzi z aukcji
                    "delta_mln_pln": -round(balance, 3),
                    "balance_mln_pln": 0.0,
                    "op_type": "redemption",
                    "source": "mf_xls",
                    "source_url": source_url,
                })

    return specs_rows, out_rows


def main() -> None:
    print("[1/4] Locating MF Bony_Skarbowe.xls URL...", flush=True)
    url = find_xls_url()
    print(f"  -> {url}", flush=True)

    print("[2/4] Downloading XLS...", flush=True)
    xls = download_xls(url)
    print(f"  -> {xls.getbuffer().nbytes / 1024:.0f} KB", flush=True)

    print("[3/4] Parsing Operacje + Zadluzenie...", flush=True)
    specs, out = parse_tbill_data(xls, url)
    redemptions = sum(1 for r in out if r["op_type"] == "redemption")
    recons = sum(1 for r in out if r["op_type"] == "reconciliation")
    print(f"  -> tbill_specs: {len(specs)} ISINs", flush=True)
    print(f"  -> tbill_outstanding: {len(out)} balance-change rows "
          f"({redemptions} redemption, {recons} reconciliation)", flush=True)

    print("[4/4] Upserting...", flush=True)
    n1 = upsert("tbill_specs", specs, on_conflict="isin", batch_size=1000)
    n2 = upsert("tbill_outstanding", out, on_conflict="isin,change_date", batch_size=1000)
    print(f"  -> tbill_specs: {n1} rows posted", flush=True)
    print(f"  -> tbill_outstanding: {n2} rows posted", flush=True)
    print("Done.", flush=True)


if __name__ == "__main__":
    main()
