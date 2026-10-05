"""
VISTA - AR Collections Analytics
Synthetic data generator for a multi-segment optical distributor.

Models three receivables segments that behave very differently:
  MANAGED_CARE - vision insurance payers. Slow, adjudication write-offs,
                 remittance-heavy, high denial/eligibility dispute volume.
  RETAIL       - optical retail chains. High volume, small tickets,
                 chronic deductions (short-ship, damage, promo allowances).
  KEY_ACCOUNT  - national accounts / large distributors. Few invoices,
                 very large balances, negotiated terms, concentration risk.

Target shape: ~$215M monthly billing, 18 months of history, 300 customers,
15 collections analysts.

Output: CSV files in ../data/
"""

import numpy as np
import pandas as pd
from datetime import date, timedelta
import os

RNG = np.random.default_rng(42)          # reproducible
START = date(2025, 1, 1)
END = date(2026, 6, 30)                  # "as of" date for the analysis
OUT = os.path.join(os.path.dirname(__file__), "..", "data")
os.makedirs(OUT, exist_ok=True)

# --------------------------------------------------------------------------
# Segment behaviour profiles - this is where the domain realism lives
# --------------------------------------------------------------------------
SEGMENTS = {
    "MANAGED_CARE": dict(
        n_customers=90,
        terms=45,
        inv_per_month=(3, 8),           # invoices per customer per month
        inv_value=(18_000, 140_000),
        pay_delay=(8, 32),              # days past due, mean/std
        pay_prob=0.985,                 # true write-off/never-pay tail only
        short_pay_rate=0.34,            # adjudication adjustments are common
        short_pay_pct=(0.03, 0.18),
        dispute_rate=0.075,
        overpay_rate=0.012,
        consolidated_pay_rate=0.55,     # one remittance covering many claims
    ),
    "RETAIL": dict(
        n_customers=175,
        terms=30,
        inv_per_month=(3, 7),
        inv_value=(4_000, 62_000),
        pay_delay=(6, 24),
        pay_prob=0.988,
        short_pay_rate=0.27,            # deductions / chargebacks
        short_pay_pct=(0.02, 0.12),
        dispute_rate=0.055,
        overpay_rate=0.008,
        consolidated_pay_rate=0.40,
    ),
    "KEY_ACCOUNT": dict(
        n_customers=35,
        terms=60,
        inv_per_month=(2, 5),
        inv_value=(280_000, 1_400_000),
        pay_delay=(4, 26),
        pay_prob=0.99,
        short_pay_rate=0.14,
        short_pay_pct=(0.01, 0.07),
        dispute_rate=0.045,             # rare, but each one is worth millions
        overpay_rate=0.004,
        consolidated_pay_rate=0.30,
    ),
}

REGIONS = ["West", "Southwest", "Midwest", "Northeast", "Southeast"]

# --------------------------------------------------------------------------
# Domain-specific naming (beats generic fake names for credibility)
# --------------------------------------------------------------------------
CITY = ["Phoenix", "Denver", "Austin", "Portland", "Tucson", "Boise", "Omaha",
        "Reno", "Fresno", "Tulsa", "Wichita", "Mesa", "Tampa", "Raleigh",
        "Spokane", "Albany", "Dayton", "Fargo", "Salem", "Aurora", "Laredo",
        "Modesto", "Akron", "Provo", "Erie", "Peoria", "Bend", "Ogden"]
STATE = ["Arizona", "Colorado", "Texas", "Oregon", "Nevada", "Kansas", "Iowa",
         "Utah", "Idaho", "Montana", "Nebraska", "Missouri", "Ohio", "Georgia"]
OPT_A = ["Clear", "Bright", "True", "Prime", "Focus", "Crystal", "Summit",
         "Pioneer", "Horizon", "Meridian", "Apex", "Vista", "Lumen", "Optic"]
OPT_B = ["View", "Sight", "Vision", "Lens", "Eye", "Optical", "Optics"]
RETAIL_SUFFIX = ["Eyewear Centers", "Optical Group", "Vision Stores",
                 "Eye Care Partners", "Optical Retail", "Vision Centers",
                 "Eyewear Collective", "Optical Outfitters"]
MC_SUFFIX = ["Vision Plan", "Health Benefits", "Vision Administrators",
             "Managed Vision Care", "Benefit Solutions", "Health Alliance",
             "Vision Trust", "Care Network"]
KA_SUFFIX = ["National Optical", "Eyewear Holdings", "Optical Distributors",
             "Vision Group International", "Eyewear Brands", "Optical Partners"]

ANALYSTS = ["A. Reyes", "M. Contreras", "J. Villalobos", "S. Duarte",
            "L. Moreno", "R. Salazar", "P. Ibarra", "C. Fuentes",
            "D. Aguilar", "N. Espinoza", "V. Cardenas", "T. Rivas",
            "G. Montoya", "F. Zamora", "B. Quintana"]      # 15 analysts

DISPUTE_REASONS = {
    "MANAGED_CARE": ["COVERAGE_DENIED", "ADJUDICATION_ADJ", "ELIGIBILITY_LAPSE",
                     "DUPLICATE_CLAIM", "AUTH_MISSING", "COORD_OF_BENEFITS"],
    "RETAIL": ["SHORT_SHIP", "DAMAGED_GOODS", "PROMO_ALLOWANCE",
               "PRICING_VARIANCE", "UNAUTH_CHARGEBACK", "RETURN_CREDIT"],
    "KEY_ACCOUNT": ["PRICING_VARIANCE", "CONTRACT_TERMS", "VOLUME_REBATE",
                    "QUALITY_CLAIM", "SHORT_SHIP"],
}

PAY_METHOD = ["ACH", "WIRE", "CHECK", "VIRTUAL_CARD"]
PAY_METHOD_P = [0.46, 0.19, 0.24, 0.11]


def month_starts(a, b):
    out, cur = [], date(a.year, a.month, 1)
    while cur <= b:
        out.append(cur)
        cur = date(cur.year + (cur.month == 12), (cur.month % 12) + 1, 1)
    return out


MONTHS = month_starts(START, END)


# --------------------------------------------------------------------------
# 1. CUSTOMERS
# --------------------------------------------------------------------------
def build_customers():
    rows, cid = [], 1
    for seg, cfg in SEGMENTS.items():
        for _ in range(cfg["n_customers"]):
            if seg == "RETAIL":
                name = (f"{RNG.choice(OPT_A)}{RNG.choice(OPT_B)} "
                        f"{RNG.choice(RETAIL_SUFFIX)}") if RNG.random() < .5 else \
                       f"{RNG.choice(CITY)} {RNG.choice(RETAIL_SUFFIX)}"
            elif seg == "MANAGED_CARE":
                name = f"{RNG.choice(STATE)} {RNG.choice(MC_SUFFIX)}" \
                    if RNG.random() < .55 else \
                    f"{RNG.choice(OPT_A)}{RNG.choice(OPT_B)} {RNG.choice(MC_SUFFIX)}"
            else:
                name = f"{RNG.choice(OPT_A)}{RNG.choice(OPT_B)} {RNG.choice(KA_SUFFIX)}"

            # credit limit scales with expected monthly volume
            lo, hi = cfg["inv_value"]
            avg_month = np.mean(cfg["inv_per_month"]) * (lo + hi) / 2
            credit = float(np.round(avg_month * RNG.uniform(1.6, 3.4), -3))

            # ~11% of the book quietly degrades over the 18 months.
            # This is what the risk model is supposed to catch.
            degrading = RNG.random() < 0.11
            # a small set are chronically bad from day one
            chronic = (not degrading) and RNG.random() < 0.13

            rows.append(dict(
                customer_id=f"C{cid:05d}",
                customer_name=name.strip(),
                segment=seg,
                region=str(RNG.choice(REGIONS)),
                payment_terms_days=cfg["terms"],
                credit_limit=credit,
                onboard_date=START - timedelta(days=int(RNG.integers(120, 2600))),
                assigned_analyst=str(RNG.choice(ANALYSTS)),
                _degrading=degrading,
                _chronic=chronic,
                _base_delay=float(RNG.normal(cfg["pay_delay"][0], 6)),
            ))
            cid += 1
    return pd.DataFrame(rows)


# --------------------------------------------------------------------------
# 2. INVOICES  (with quarter-end seasonality)
# --------------------------------------------------------------------------
def build_invoices(cust):
    rows, inv = [], 1
    for c in cust.itertuples():
        cfg = SEGMENTS[c.segment]
        lo_n, hi_n = cfg["inv_per_month"]
        lo_v, hi_v = cfg["inv_value"]
        for m_i, m in enumerate(MONTHS):
            # quarter-end push: optical distributors bill hard in Mar/Jun/Sep/Dec
            season = 1.35 if m.month in (3, 6, 9, 12) else 1.0
            # gentle organic growth across the 18 months
            growth = 1 + 0.012 * m_i
            n = max(0, int(RNG.integers(lo_n, hi_n + 1) * season * growth))
            days_in_month = ((date(m.year + (m.month == 12), (m.month % 12) + 1, 1))
                             - m).days
            for _ in range(n):
                d = m + timedelta(days=int(RNG.integers(0, days_in_month)))
                if d > END:
                    continue
                amt = float(np.round(RNG.uniform(lo_v, hi_v), 2))
                rows.append(dict(
                    invoice_id=f"INV-{inv:07d}",
                    customer_id=c.customer_id,
                    invoice_date=d,
                    due_date=d + timedelta(days=c.payment_terms_days),
                    invoice_amount=amt,
                    po_number=(f"PO{RNG.integers(100000, 999999)}"
                               if RNG.random() < 0.62 else None),
                    currency="USD",
                ))
                inv += 1
    return pd.DataFrame(rows)


# --------------------------------------------------------------------------
# 3. PAYMENTS + APPLICATIONS + DISPUTES
#    The messy core: partial pays, consolidated remittances, unapplied cash,
#    bad references, disputes that block payment.
# --------------------------------------------------------------------------
def build_cash(cust, inv):
    cmap = cust.set_index("customer_id").to_dict("index")
    payments, applications, disputes = [], [], []
    pid = aid = did = 1

    inv = inv.sort_values(["customer_id", "invoice_date"])
    for cid, grp in inv.groupby("customer_id", sort=False):
        c = cmap[cid]
        cfg = SEGMENTS[c["segment"]]
        reasons = DISPUTE_REASONS[c["segment"]]
        base_delay = c["_base_delay"]

        # bucket invoices into remittance groups (consolidated payments)
        recs = grp.to_dict("records")
        i = 0
        while i < len(recs):
            if RNG.random() < cfg["consolidated_pay_rate"]:
                k = int(RNG.integers(2, 6))
            else:
                k = 1
            batch = recs[i:i + k]
            i += k

            anchor = max(r["due_date"] for r in batch)
            first_dt = min(r["invoice_date"] for r in batch)

            # how far into the 18 months are we? drives the degradation
            progress = (first_dt - START).days / max(1, (END - START).days)
            delay = base_delay
            if c["_degrading"]:
                delay += progress * RNG.uniform(28, 55)   # gets worse over time
            if c["_chronic"]:
                delay += RNG.uniform(18, 40)
            delay += RNG.normal(0, cfg["pay_delay"][1] * 0.55)

            # dispute? blocks or delays the cash
            disputed_ids = []
            for r in batch:
                if RNG.random() < cfg["dispute_rate"]:
                    d_open = r["due_date"] + timedelta(days=int(RNG.integers(2, 30)))
                    if d_open > END:
                        continue
                    d_amt = float(np.round(
                        r["invoice_amount"] * RNG.uniform(0.08, 0.85), 2))
                    resolved = RNG.random() < 0.66
                    d_close = (d_open + timedelta(days=int(RNG.integers(9, 115)))
                               if resolved else None)
                    if d_close and d_close > END:
                        d_close, resolved = None, False
                    disputes.append(dict(
                        dispute_id=f"D{did:06d}",
                        invoice_id=r["invoice_id"],
                        customer_id=cid,
                        dispute_date=d_open,
                        reason_code=str(RNG.choice(reasons)),
                        amount_disputed=d_amt,
                        resolved_date=d_close,
                        status="RESOLVED" if resolved else "OPEN",
                    ))
                    did += 1
                    disputed_ids.append(r["invoice_id"])
                    if not resolved:
                        delay += 60          # open dispute stalls the cash

            pay_date = anchor + timedelta(days=int(max(-9, round(delay))))
            if pay_date > END or RNG.random() > cfg["pay_prob"]:
                continue                      # still open at as-of date

            # build the applications for this remittance
            batch_apps, total = [], 0.0
            for r in batch:
                if r["invoice_id"] in disputed_ids and RNG.random() < 0.45:
                    continue                  # disputed line withheld entirely
                amt = r["invoice_amount"]
                if RNG.random() < cfg["short_pay_rate"]:
                    lo, hi = cfg["short_pay_pct"]
                    amt = float(np.round(amt * (1 - RNG.uniform(lo, hi)), 2))
                elif RNG.random() < cfg["overpay_rate"]:
                    amt = float(np.round(amt * RNG.uniform(1.01, 1.06), 2))
                batch_apps.append((r["invoice_id"], amt))
                total += amt

            if not batch_apps:
                continue

            total = float(np.round(total, 2))
            unapplied = 0.0
            # ~3.5% of remittances arrive with cash we can't place
            if RNG.random() < 0.035:
                unapplied = float(np.round(total * RNG.uniform(0.04, 0.22), 2))

            # remittance reference quality - this is what breaks auto-matching
            roll = RNG.random()
            if roll < 0.58:
                ref = " ".join(a[0] for a in batch_apps)[:180]      # clean
                ref_q = "CLEAN"
            elif roll < 0.78:
                ref = (batch_apps[0][0].replace("INV-", "")
                       + f" +{len(batch_apps)-1} more" if len(batch_apps) > 1
                       else batch_apps[0][0].replace("INV-", ""))
                ref_q = "PARTIAL"
            elif roll < 0.92:
                ref = f"PO{RNG.integers(100000, 999999)} REMIT {c['customer_name'][:22]}"
                ref_q = "PO_ONLY"
            else:
                ref = f"PMT{RNG.integers(10**7, 10**8)}"            # useless
                ref_q = "NONE"

            payments.append(dict(
                payment_id=f"PMT-{pid:07d}",
                customer_id=cid,
                payment_date=pay_date,
                payment_amount=float(np.round(total + unapplied, 2)),
                payment_method=str(RNG.choice(PAY_METHOD, p=PAY_METHOD_P)),
                remittance_reference=ref,
                remittance_quality=ref_q,
                unapplied_amount=unapplied,
            ))
            for invid, amt in batch_apps:
                applications.append(dict(
                    application_id=f"APP-{aid:07d}",
                    payment_id=f"PMT-{pid:07d}",
                    invoice_id=invid,
                    applied_amount=amt,
                    applied_date=pay_date,
                ))
                aid += 1
            pid += 1

    return (pd.DataFrame(payments), pd.DataFrame(applications),
            pd.DataFrame(disputes))


# --------------------------------------------------------------------------
# 3b. LATE COLLECTION SWEEP
#     Synthetic late collections clear a proportion of aged invoice balances.
#     Deduction residuals have a higher modeled clearing probability than fully
#     unpaid invoices; uncleared balances remain open at the reporting cutoff.
# --------------------------------------------------------------------------
def late_collection_sweep(cust, inv, pay, apps):
    cmap = cust.set_index("customer_id").to_dict("index")
    paid = apps.groupby("invoice_id")["applied_amount"].sum()
    inv2 = inv.copy()
    inv2["paid"] = inv2["invoice_id"].map(paid).fillna(0.0)
    inv2["open_amt"] = (inv2["invoice_amount"] - inv2["paid"]).round(2)

    aged = inv2[(inv2["open_amt"] > 1) &
                (pd.to_datetime(inv2["due_date"]) <
                 pd.Timestamp(END) - pd.Timedelta(days=75))]

    new_pay, new_app = [], []
    pid = len(pay) + 1
    aid = len(apps) + 1
    for r in aged.itertuples():
        residual_only = r.paid > 0
        # deduction residuals clear more often than fully unpaid invoices
        p_clear = 0.88 if residual_only else 0.72
        if RNG.random() > p_clear:
            continue                       # genuine bad debt / still chasing
        c = cmap[r.customer_id]
        earliest = pd.Timestamp(r.due_date) + pd.Timedelta(days=60)
        span = (pd.Timestamp(END) - earliest).days
        if span < 5:
            continue
        d = (earliest + pd.Timedelta(days=int(RNG.integers(3, span)))).date()
        amt = float(np.round(r.open_amt * (1.0 if RNG.random() < 0.85
                                           else RNG.uniform(0.55, 0.95)), 2))
        new_pay.append(dict(
            payment_id=f"PMT-L{pid:06d}",
            customer_id=r.customer_id,
            payment_date=d,
            payment_amount=amt,
            payment_method=str(RNG.choice(PAY_METHOD, p=PAY_METHOD_P)),
            remittance_reference=(f"{r.invoice_id} BAL"
                                  if RNG.random() < 0.7 else
                                  f"DEDUCTION CLEAR {r.customer_id}"),
            remittance_quality="CLEAN" if RNG.random() < 0.7 else "NONE",
            unapplied_amount=0.0,
        ))
        new_app.append(dict(
            application_id=f"APP-L{aid:06d}",
            payment_id=f"PMT-L{pid:06d}",
            invoice_id=r.invoice_id,
            applied_amount=amt,
            applied_date=d,
        ))
        pid += 1
        aid += 1

    if new_pay:
        pay = pd.concat([pay, pd.DataFrame(new_pay)], ignore_index=True)
        apps = pd.concat([apps, pd.DataFrame(new_app)], ignore_index=True)
    return pay.sort_values("payment_date").reset_index(drop=True), apps


# --------------------------------------------------------------------------
# 4. COLLECTION ACTIVITY  (what the 15 analysts actually did)
# --------------------------------------------------------------------------
def build_activity(cust, inv, apps):
    paid = apps.groupby("invoice_id")["applied_amount"].sum() if len(apps) else pd.Series(dtype=float)
    cmap = cust.set_index("customer_id").to_dict("index")
    rows, act = [], 1

    inv2 = inv.copy()
    inv2["paid"] = inv2["invoice_id"].map(paid).fillna(0.0)
    inv2["open_amt"] = inv2["invoice_amount"] - inv2["paid"]
    # analysts chase invoices that went past due
    chase = inv2[(inv2["due_date"] < END) & (inv2["open_amt"] > 1)]
    chase = chase.sample(frac=0.34, random_state=7)

    for r in chase.itertuples():
        c = cmap[r.customer_id]
        n = int(RNG.integers(1, 5))
        for j in range(n):
            d = r.due_date + timedelta(days=int(RNG.integers(3, 95)) + j * 12)
            if d > END:
                break
            typ = str(RNG.choice(["EMAIL", "CALL", "STATEMENT", "ESCALATION"],
                                 p=[0.45, 0.33, 0.14, 0.08]))
            outcome = str(RNG.choice(
                ["PROMISE_TO_PAY", "NO_ANSWER", "DISPUTE_RAISED",
                 "PAYMENT_CONFIRMED", "INFO_REQUESTED"],
                p=[0.31, 0.26, 0.11, 0.17, 0.15]))
            ptp = (d + timedelta(days=int(RNG.integers(5, 40)))
                   if outcome == "PROMISE_TO_PAY" else None)
            rows.append(dict(
                activity_id=f"ACT-{act:07d}",
                invoice_id=r.invoice_id,
                customer_id=r.customer_id,
                activity_date=d,
                activity_type=typ,
                analyst=c["assigned_analyst"],
                outcome=outcome,
                promise_to_pay_date=ptp,
            ))
            act += 1
    return pd.DataFrame(rows)


# --------------------------------------------------------------------------
# 5. DATE DIMENSION
# --------------------------------------------------------------------------
def build_dim_date():
    days = pd.date_range(START - timedelta(days=90), END, freq="D")
    df = pd.DataFrame({"date_key": days})
    d = df["date_key"].dt
    df["year"] = d.year
    df["quarter"] = d.quarter
    df["month_num"] = d.month
    df["month_name"] = d.strftime("%b")
    df["year_month"] = d.strftime("%Y-%m")
    df["day_of_month"] = d.day
    df["day_name"] = d.strftime("%a")
    df["is_weekend"] = d.dayofweek.isin([5, 6]).astype(int)
    df["is_month_end"] = d.is_month_end.astype(int)
    df["is_quarter_end"] = d.is_quarter_end.astype(int)
    return df


# --------------------------------------------------------------------------
if __name__ == "__main__":
    print("building customers ...")
    cust = build_customers()
    print("building invoices ...")
    inv = build_invoices(cust)
    print("building cash / disputes ...")
    pay, apps, disp = build_cash(cust, inv)
    print("building collection activity ...")
    act = build_activity(cust, inv, apps)     # analysts chase BEFORE cash lands
    print("late collection sweep ...")
    pay, apps = late_collection_sweep(cust, inv, pay, apps)
    dim = build_dim_date()

    cust_out = cust.drop(columns=[c for c in cust.columns if c.startswith("_")])

    files = {
        "dim_date.csv": dim,
        "customers.csv": cust_out,
        "invoices.csv": inv,
        "payments.csv": pay,
        "payment_applications.csv": apps,
        "disputes.csv": disp,
        "collection_activity.csv": act,
    }
    for name, df in files.items():
        # The SQL Server loader uses LF row endings explicitly. Writing them
        # here avoids a Windows CRLF edge case during BULK INSERT.
        df.to_csv(
            os.path.join(OUT, name),
            index=False,
            encoding="utf-8",
            lineterminator="\n",
        )
        print(f"  {name:28s} {len(df):>8,} rows")

    billed = inv["invoice_amount"].sum()
    months = len(MONTHS)
    collected = apps["applied_amount"].sum()
    open_ar = billed - collected
    print(f"\n  total billed      ${billed:,.0f}")
    print(f"  avg monthly bill  ${billed/months:,.0f}")
    print(f"  cash applied      ${collected:,.0f}")
    print(f"  open AR @ {END}  ${open_ar:,.0f}")
    print(f"  open disputes     {(disp['status']=='OPEN').sum():,}")
