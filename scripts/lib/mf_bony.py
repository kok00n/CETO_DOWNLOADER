"""Helpers for downloading the MF 'Baza transakcji - bony skarbowe' .xls file.

Lives on the same gov.pl page as the bonds XLSM; UUID attachment URL may
change between updates so we scrape the page on each run.
"""

from __future__ import annotations

import re
from io import BytesIO

import requests


MF_PAGE_URL = "https://www.gov.pl/web/finanse/bony-i-obligacje-hurtowe1"
USER_AGENT = "Mozilla/5.0 (compatible; bondspot-analytics/1.0)"


def find_xls_url() -> str:
    """Locate the current 'Baza transakcji - bony skarbowe' attachment URL."""
    r = requests.get(MF_PAGE_URL, headers={"User-Agent": USER_AGENT}, timeout=30)
    r.raise_for_status()
    html = r.text

    pattern = re.compile(
        r'href="(/attachment/[a-f0-9-]+)"[^>]*download[^>]*'
        r'aria-label="[^"]*bony skarbowe[^"]*"',
        re.IGNORECASE | re.DOTALL,
    )
    m = pattern.search(html)
    if not m:
        pattern2 = re.compile(
            r'href="(/attachment/[a-f0-9-]+)"[^>]*download'
            r'[\s\S]{0,400}?Bony[_​]*Skarbowe\.xls',
            re.IGNORECASE,
        )
        m = pattern2.search(html)
    if not m:
        raise RuntimeError(
            "Could not find Bony_Skarbowe.xls link on MF page. "
            "Page structure may have changed."
        )
    return "https://www.gov.pl" + m.group(1)


def download_xls(url: str) -> BytesIO:
    """Download the .xls. Returns BytesIO ready for xlrd.open_workbook(file_contents=...)."""
    r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=120)
    r.raise_for_status()
    return BytesIO(r.content)
