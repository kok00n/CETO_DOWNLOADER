"""Refresh reference rates + benchmark yields + FX z stooq.pl.

Wymaga STOOQ_API_KEY env var. Klucz uzyskac jednorazowo przez captcha:
    https://stooq.pl/q/d/?s=plopln6m&get_apikey
Wartosc stala - dodac jako GitHub secret STOOQ_API_KEY.

Tickery i mapping:
  Stopy procentowe (percent):
    plopln6m  -> WIBOR6M  (daily fixing, percent)
    plspln00  -> POLSTR   (overnight, percent)
    cpiypl.m  -> CPI_YOY  (Polska, monthly, percent)
  Rentownosci benchmarkowe 10Y (percent):
    10yply.b  -> PL10Y    (POLGB 10Y govt bond yield)
    10ydey.b  -> DE10Y    (Bund 10Y govt bond yield)
    10yusy.b  -> US10Y    (UST 10Y govt bond yield)
  Kursy walutowe (poziom, nie percent - jednostka waluty/waluta):
    eurpln    -> EURPLN
    usdpln    -> USDPLN
    eurusd    -> EURUSD

UWAGA: kolumna value_pct trzyma zarowno procenty (stopy/yieldy) jak i
poziomy FX. Interpretacja zalezna od series code (zob. komentarz w
reference_rates_schema.sql).

Stooq CSV format:
    Data,Otwarcie,Najwyzszy,Najnizszy,Zamkniecie[,Wolumen]
    YYYY-MM-DD,...,close[,vol]

Uzywamy 'Zamkniecie' (close) jako wartosc EOD.

Idempotentny - upsert ON CONFLICT DO UPDATE.
"""

from __future__ import annotations

import csv
import os
import sys
from io import StringIO
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
from lib.supabase import upsert  # noqa: E402


STOOQ_TICKERS = {
    # Stopy procentowe (percent)
    "WIBOR6M": "plopln6m",
    "POLSTR":  "plspln00",
    "CPI_YOY": "cpiypl.m",
    # Rentownosci benchmarkowe 10Y govt bond (percent)
    "PL10Y":   "10yply.b",
    "DE10Y":   "10ydey.b",
    "US10Y":   "10yusy.b",
    # FX - poziom (jednostka waluty bazowej / waluta kwotowana)
    "EURPLN":  "eurpln",
    "USDPLN":  "usdpln",
    "EURUSD":  "eurusd",
}

UA = "Mozilla/5.0 (compatible; CETO-dashboard/1.0)"
TIMEOUT_S = 30


def fetch_csv(ticker: str, apikey: str) -> list[dict]:
    """Pobierz dzienny CSV z stooq. Zwraca [{date, value}, ...]."""
    url = f"https://stooq.pl/q/d/l/?s={ticker}&i=d&apikey={apikey}"
    r = requests.get(url, headers={"User-Agent": UA}, timeout=TIMEOUT_S)
    r.raise_for_status()
    txt = r.text
    # Sanity check - jesli stooq wzieal token za zly i wraca HTML/komunikat
    if txt.lstrip().startswith("<") or "Uzyskaj apikey" in txt[:300]:
        raise RuntimeError(
            f"Stooq returned HTML/auth challenge for {ticker} - "
            f"sprawdz czy STOOQ_API_KEY jest poprawny/aktywny"
        )

    rows = []
    reader = csv.DictReader(StringIO(txt))
    for row in reader:
        date = (row.get("Data") or row.get("Date") or "").strip()
        close = (row.get("Zamkniecie") or row.get("Close") or "").strip()
        if not date or not close:
            continue
        try:
            rows.append({"date": date, "value": float(close)})
        except ValueError:
            continue
    return rows


def main() -> None:
    apikey = os.environ.get("STOOQ_API_KEY", "").strip()
    if not apikey:
        print("ERROR: STOOQ_API_KEY env var required.", flush=True)
        print("  Uzyskaj jednorazowo przez captcha:", flush=True)
        print("  https://stooq.pl/q/d/?s=plopln6m&get_apikey", flush=True)
        print("  i dodaj jako GitHub secret STOOQ_API_KEY.", flush=True)
        sys.exit(1)

    all_rows: list[dict] = []
    for series, ticker in STOOQ_TICKERS.items():
        print(f"[{series}] fetching {ticker}...", flush=True)
        try:
            data = fetch_csv(ticker, apikey)
        except Exception as exc:
            print(f"   ! ERROR fetching {ticker}: {exc}", flush=True)
            continue
        if not data:
            print(f"   ! empty data for {ticker}", flush=True)
            continue
        first, last = data[0], data[-1]
        # FX series sa poziomami (np. 4.32), reszta to procenty
        unit = "" if series in ("EURPLN", "USDPLN", "EURUSD") else "%"
        print(
            f"   -> {len(data)} rows ({first['date']} -> {last['date']}, "
            f"latest={last['value']:.4f}{unit})",
            flush=True,
        )
        url = f"https://stooq.pl/q/?s={ticker}"
        for r in data:
            all_rows.append({
                "series": series,
                "rate_date": r["date"],
                "value_pct": round(r["value"], 4),
                "source_url": url,
            })

    if not all_rows:
        print("No data fetched from any series - exiting with error", flush=True)
        sys.exit(1)

    posted = upsert(
        "reference_rates", all_rows,
        on_conflict="series,rate_date", batch_size=2000,
    )
    print(f"Upserted {posted} rows.", flush=True)


if __name__ == "__main__":
    main()
