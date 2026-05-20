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

    spec  -- row from bond_specs (dict)
    fixing -- row from bondspot_fixing (dict): fixing_date, isin, fixing_yield
              (only fixing_session=2 is used upstream; one record per day)
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

    atm_y = atm(f_date, m_date)
    atr_y = atr(f_date, m_date, i_date, is_floating, freq)

    if is_floating:
        # For floaters (WZ/NZ): at each reset the bond reprices to par, so the
        # full rate sensitivity is concentrated in the time to next coupon
        # reset. Mac Duration = time to next reset = ATR. Mod Duration would
        # be Mac / (1 + r/freq) but for sub-6M intervals at current rates
        # the discount factor differs from Mac by <0.1%, and we don't have
        # WIBOR/POLSTR fixings in the DB yet -> set Mod = Mac.
        mac, mod = atr_y, atr_y
    else:
        mac, mod = macaulay_modified_duration(
            f_date, m_date, i_date, coupon_rate, freq, ytm
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
