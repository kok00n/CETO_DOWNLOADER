"""Bond analytics: ATM, ATR, Macaulay Duration, Modified Duration.

Conventions follow Polish wholesale T-bonds (PS/DS/WS = annual ACT/ACT, WZ = semi-annual,
IZ = annual inflation-linked, OK = zero-coupon, NZ = compound POLSTR).
"""

from datetime import date

from dateutil.relativedelta import relativedelta

YEAR = 365.25  # ACT/365.25 approximation for time fractions


def years_between(d1: date, d2: date) -> float:
    return (d2 - d1).days / YEAR


def generate_coupon_dates(issue_date: date | None, maturity_date: date, freq: int) -> list[date]:
    """Build coupon payment dates from maturity backwards by 12/freq months.

    Stops once we reach or pass issue_date. Returns sorted ascending list,
    always including maturity_date as the last element.
    """
    if freq <= 0:
        return [maturity_date]
    months = 12 // freq
    dates: list[date] = []
    d = maturity_date
    earliest = issue_date or date(1900, 1, 1)
    # Safety cap: 100 coupons (covers 100Y annual or 50Y semi-annual)
    for _ in range(100):
        dates.append(d)
        nxt = d + relativedelta(months=-months)
        if nxt <= earliest:
            break
        d = nxt
    return sorted(dates)


def atm(fixing_date: date, maturity_date: date) -> float:
    """Average Time to Maturity (years)."""
    return years_between(fixing_date, maturity_date)


def atr(
    fixing_date: date,
    maturity_date: date,
    issue_date: date | None,
    is_floating: bool,
    freq: int | None,
) -> float:
    """Average Time to Refixing (years).

    Fixed-coupon and zero-coupon: ATR == ATM (one final 'refix' at maturity).
    Floating-rate (WZ/NZ): time to next coupon reset.
    """
    if not is_floating or not freq or freq <= 0:
        return years_between(fixing_date, maturity_date)
    coupons = generate_coupon_dates(issue_date, maturity_date, freq)
    future = [c for c in coupons if c > fixing_date]
    if not future:
        return years_between(fixing_date, maturity_date)
    return years_between(fixing_date, future[0])


def accrued_interest(
    fixing_date: date,
    issue_date: date | None,
    maturity_date: date,
    coupon_rate: float | None,
    freq: int | None,
    face: float = 100.0,
) -> float:
    """Accrued interest from last coupon to fixing_date, ACT/365.25 simplified.

    Works for any freq: annual_rate * face * fraction_of_year_since_last_coupon
    naturally gives the right amount regardless of payment frequency.
    """
    if not freq or freq <= 0 or coupon_rate is None:
        return 0.0
    coupons = generate_coupon_dates(issue_date, maturity_date, freq)
    past = [c for c in coupons if c <= fixing_date]
    last = past[-1] if past else (issue_date or coupons[0])
    if last is None:
        return 0.0
    days_since = (fixing_date - last).days
    if days_since <= 0:
        return 0.0
    return coupon_rate * face * (days_since / 365.25)


def solve_ytm(
    clean_price: float,
    fixing_date: date,
    issue_date: date | None,
    maturity_date: date,
    coupon_rate: float,
    freq: int,
    face: float = 100.0,
) -> float | None:
    """Bisection solver: find y such that dirty_price == sum(CF_t / (1+y/freq)^(t*freq)).

    Returns None if a bracket couldn't be found or solver didn't converge.
    """
    if freq <= 0 or coupon_rate is None or clean_price is None:
        return None

    coupons = generate_coupon_dates(issue_date, maturity_date, freq)
    future = [c for c in coupons if c > fixing_date]
    if not future:
        return None

    cpn = coupon_rate * face / freq
    ai = accrued_interest(fixing_date, issue_date, maturity_date, coupon_rate, freq, face)
    dirty = clean_price + ai

    def pv(y: float) -> float:
        total = 0.0
        for cf_date in future:
            t = years_between(fixing_date, cf_date)
            cf = cpn + (face if cf_date == maturity_date else 0.0)
            total += cf / (1 + y / freq) ** (t * freq)
        return total

    lo, hi = -0.20, 0.50
    pv_lo, pv_hi = pv(lo), pv(hi)
    # extend bracket if needed (rare, e.g. junk-yield territory)
    tries = 0
    while pv_lo < dirty and tries < 5:
        lo -= 0.20
        pv_lo = pv(lo)
        tries += 1
    tries = 0
    while pv_hi > dirty and tries < 5:
        hi += 0.50
        pv_hi = pv(hi)
        tries += 1
    if not (pv_lo >= dirty >= pv_hi):
        return None  # couldn't bracket

    for _ in range(80):
        mid = 0.5 * (lo + hi)
        pv_mid = pv(mid)
        if pv_mid > dirty:
            lo = mid
        else:
            hi = mid
        if hi - lo < 1e-9:
            break
    return 0.5 * (lo + hi)


def macaulay_modified_duration(
    fixing_date: date,
    maturity_date: date,
    issue_date: date | None,
    coupon_rate: float | None,
    freq: int | None,
    ytm: float | None,
) -> tuple[float | None, float | None]:
    """Macaulay + Modified Duration for fixed-coupon and zero-coupon bonds.

    Returns (None, None) when we lack YTM (e.g. WZ/IZ where BondSpot doesn't quote yield).
    """
    if ytm is None:
        return None, None

    # Zero-coupon: closed form
    if not freq or freq == 0:
        t = years_between(fixing_date, maturity_date)
        if t <= 0:
            return None, None
        return t, t / (1 + ytm)

    if coupon_rate is None:
        return None, None

    coupons = generate_coupon_dates(issue_date, maturity_date, freq)
    future = [c for c in coupons if c > fixing_date]
    if not future:
        return None, None

    face = 100.0
    cpn = coupon_rate * face / freq  # coupon per period

    pv = 0.0
    weighted_t = 0.0
    for cf_date in future:
        t = years_between(fixing_date, cf_date)
        cf = cpn + (face if cf_date == maturity_date else 0.0)
        df = (1 + ytm / freq) ** (t * freq)
        pv_cf = cf / df
        pv += pv_cf
        weighted_t += t * pv_cf

    if pv <= 0:
        return None, None
    mac = weighted_t / pv
    mod = mac / (1 + ytm / freq)
    return mac, mod


def compute_metrics(spec: dict, fixing: dict) -> dict | None:
    """Combine ATM/ATR/Mac/Mod into a single analytics record.

    spec   -- row from bond_specs (dict)
    fixing -- row from bondspot_fixing (dict): fixing_date, isin, fixing_yield,
              fixing_price. Only fixing_session=2 is used upstream
              (one record per day).
    """
    f_date = _to_date(fixing["fixing_date"])
    m_date = _to_date(spec["maturity_date"])
    i_date = _to_date(spec.get("issue_date")) if spec.get("issue_date") else None

    if not m_date or f_date >= m_date:
        return None  # bond already matured at this fixing date

    is_floating = bool(spec.get("is_floating"))
    freq = spec.get("coupon_freq")
    coupon_rate = spec.get("coupon_rate")
    if coupon_rate is not None:
        coupon_rate = float(coupon_rate)
    raw_ytm = fixing.get("fixing_yield")
    # BondSpot publishes yield in percent (e.g. 3.56 means 3.56%).
    ytm = float(raw_ytm) / 100.0 if raw_ytm is not None else None
    raw_price = fixing.get("fixing_price")
    price = float(raw_price) if raw_price is not None else None
    # short_rate_proxy (decimal, e.g. 0.0356 = 3.56%) comes from the RPC:
    # AVG(fixing_yield) over fixed-coupon bonds on the same fixing_date.
    # Best available proxy for "current short rate" without WIBOR ingestion.
    raw_proxy = fixing.get("short_rate_proxy")
    short_rate_proxy = float(raw_proxy) / 100.0 if raw_proxy is not None else None

    atm_y = atm(f_date, m_date)
    atr_y = atr(f_date, m_date, i_date, is_floating, freq)

    if is_floating:
        # Floaters (WZ/NZ): at each reset the bond reprices to par, so the
        # full rate sensitivity is concentrated in the time to next coupon
        # reset. Mac Duration = time to next reset = ATR.
        #
        # Mod Duration = Mac / (1 + y/freq) by definition. Without WIBOR/
        # POLSTR data we use the same-date avg YTM of fixed-coupon bonds
        # as a short-rate proxy. Adjustment magnitude is small (0.25-2.5%
        # of Mac for typical sub-6M ATR values), but honest about the
        # formula rather than collapsing Mod = Mac. Fallback 5% if proxy
        # unavailable (e.g. early backfill before any fixed bonds priced).
        mac = atr_y
        y_proxy = short_rate_proxy if short_rate_proxy is not None else 0.05
        mod = mac / (1 + y_proxy / freq) if freq else mac
    else:
        # Fixed-coupon / IZ / OK: prefer BondSpot's quoted YTM. If missing
        # (typically IZ - BondSpot doesn't quote nominal yield for linkers
        # because the concept splits into real yield + breakeven inflation),
        # solve YTM from the quoted clean price + cash flow schedule.
        # For IZ specifically, the quoted price is on real terms and CFs are
        # real coupons, so the back-solved YTM is the real yield.
        effective_ytm = ytm
        if effective_ytm is None and coupon_rate is not None and freq and price is not None:
            effective_ytm = solve_ytm(
                price, f_date, i_date, m_date, coupon_rate, freq
            )
        # Last-resort fallback: par approximation (coupon_rate as YTM).
        if effective_ytm is None and coupon_rate is not None:
            effective_ytm = coupon_rate
        mac, mod = macaulay_modified_duration(
            f_date, m_date, i_date, coupon_rate, freq, effective_ytm
        )

    return {
        "fixing_date": fixing["fixing_date"],
        "isin": fixing["isin"],
        "bond_type": spec.get("bond_type"),
        "atm_years": round(atm_y, 4),
        "atr_years": round(atr_y, 4),
        "mac_duration": round(mac, 4) if mac is not None else None,
        "mod_duration": round(mod, 4) if mod is not None else None,
    }


def _to_date(value) -> date | None:
    if value is None:
        return None
    if isinstance(value, date):
        return value
    return date.fromisoformat(str(value)[:10])
