"""Shared helpers for downloading the MF Obligacje_Hurtowe.xlsm file.

The attachment URL contains a UUID that may change between MF updates,
so we scrape the parent page on each run to find the current link.
"""

from __future__ import annotations

import re
from io import BytesIO

import requests


MF_PAGE_URL = "https://www.gov.pl/web/finanse/bony-i-obligacje-hurtowe1"
USER_AGENT = "Mozilla/5.0 (compatible; bondspot-analytics/1.0)"


def find_xlsm_url() -> str:
    """Locate the current 'Baza transakcji - obligacje hurtowe' attachment URL."""
    r = requests.get(MF_PAGE_URL, headers={"User-Agent": USER_AGENT}, timeout=30)
    r.raise_for_status()
    html = r.text

    pattern = re.compile(
        r'href="(/attachment/[a-f0-9-]+)"[^>]*download[^>]*'
        r'aria-label="[^"]*obligacje hurtowe[^"]*"',
        re.IGNORECASE | re.DOTALL,
    )
    m = pattern.search(html)
    if not m:
        # Fallback: locate by filename mentioned in the link block
        pattern2 = re.compile(
            r'href="(/attachment/[a-f0-9-]+)"[^>]*download'
            r'[\s\S]{0,400}?Obligacje[_​]*Hurtowe\.xlsm',
            re.IGNORECASE,
        )
        m = pattern2.search(html)
    if not m:
        raise RuntimeError(
            "Could not find Obligacje_Hurtowe.xlsm link on MF page. "
            "Page structure may have changed."
        )
    return "https://www.gov.pl" + m.group(1)


def download_xlsm(url: str) -> BytesIO:
    """Download the MF XLSM. Returns BytesIO suitable for openpyxl."""
    r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=120)
    r.raise_for_status()
    return BytesIO(r.content)
