"""Compute auction-derived analytics as fallback for bonds without BondSpot fixing yet.

Dla nowych serii (np. NZ0928 issued 2025-11-21) MF aukcja sie odbywa zanim
BondSpot zaczyna kwotowac dany ISIN (czasem dopiero kilka tygodni pozniej).
Bez tego skryptu bondspot_analytics nie ma rekordow dla okresu auction -> first
fixing, wiec v_bondspot_full_weighted ffill-uje od momentu pierwszego fixingu
(nie od aukcji) - portfolio metrics niedoceniaja swiezo wyemitowanych bondow.

Ten skrypt:
  1. Iteruje wszystkie sale legs (type_tx='S') z bond_auctions
  2. Buduje syntetyczny "fixing" dict z auction_date + yield_avg + price_avg
  3. Wywoluje compute_metrics() - dokladnie te same wzory co dla BondSpota
  4. Wrzuca do bondspot_analytics z ON CONFLICT DO NOTHING

ON CONFLICT DO NOTHING zapewnia ze prawdziwy fixing zawsze wygrywa - jesli na
ten sam (date, isin) istnieje juz wpis (np. z compute_analytics.py), auction
wersja jest pomijana.

Order w CI: PO compute_analytics.py (fixings first), wtedy auction tylko
wypelni dziury.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lib.calc import compute_metrics  # noqa: E402
from lib.supabase import select_all, upsert  # noqa: E402


def main() -> None:
    print("[1/3] Loading bond_specs...", flush=True)
    specs = select_all(
        "bond_specs",
        "?select=isin,bond_type,coupon_kind,is_floating,issue_date,maturity_date,coupon_rate,coupon_freq",
    )
    by_isin = {s["isin"]: s for s in specs}
    print(f"  -> {len(by_isin)} bond_specs loaded", flush=True)

    print("[2/3] Loading bond_auctions (sale legs only)...", flush=True)
    # type_tx='S' = sale leg (kazda aukcja ma S + opcjonalnie O dla switchy/odkupow).
    # Bierzemy tylko S - to nasz primary yield observation dla nowo emitowanej serii.
    auctions = select_all(
        "bond_auctions",
        "?type_tx=eq.S&select=auction_date,isin,yield_avg,price_avg&order=auction_date.asc",
    )
    print(f"  -> {len(auctions)} sale-leg auctions loaded", flush=True)

    print("[3/3] Computing analytics from auction yields...", flush=True)
    out: list[dict] = []
    skipped_no_spec: set[str] = set()
    skipped_no_yield = 0
    skipped_past_maturity = 0
    for a in auctions:
        isin = a["isin"]
        spec = by_isin.get(isin)
        if spec is None:
            skipped_no_spec.add(isin)
            continue
        # yield_avg moze byc None dla aukcji ktore nie pokazaly rentownosci
        # (np. nieudane lub konkurencyjne bez avg). compute_metrics i tak by
        # zwrocil duration=None dla fixed-coupon bez ytm, ale dla zerocoup ma
        # fallback na coupon_rate; lepiej jednak pominac w ogole.
        if a.get("yield_avg") is None:
            skipped_no_yield += 1
            continue
        # Syntetyczny fixing dict - compute_metrics oczekuje tych samych
        # kluczy co bondspot_fixing row:
        #   fixing_date, isin, fixing_yield (w %), fixing_price (clean)
        # refresh_bond_auctions._yield_to_pct juz normalizuje yield_avg do
        # konwencji procentowej (5.4 = 5.4%), wiec mozna podstawic bezposrednio.
        fixing = {
            "fixing_date": a["auction_date"],
            "isin": isin,
            "fixing_yield": a["yield_avg"],
            "fixing_price": a.get("price_avg"),
        }
        rec = compute_metrics(spec, fixing)
        if rec is None:
            skipped_past_maturity += 1
            continue
        out.append(rec)

    print(f"  -> {len(out)} analytics records computed", flush=True)
    print(
        f"  -> skipped: {len(skipped_no_spec)} no_spec ISINs, "
        f"{skipped_no_yield} no_yield, "
        f"{skipped_past_maturity} past_maturity",
        flush=True,
    )

    posted = upsert(
        "bondspot_analytics",
        out,
        on_conflict="fixing_date,isin",
        batch_size=1000,
        ignore_duplicates=True,
    )
    print(f"  -> {posted} rows posted (DO NOTHING - existing fixings preserved)", flush=True)
    print("Done.", flush=True)


if __name__ == "__main__":
    main()
