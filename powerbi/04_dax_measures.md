# VISTA — Power BI model and measures

This document specifies the semantic model, DAX expressions and visual bindings
for the completed [VISTA report](VISTA-Power_BI_Report.pbix). The
[reproduction guide](../BUILD_GUIDE.md) covers setup and refresh; the
[build log](../docs/BUILD_LOG.md) contains execution and reconciliation evidence.

The SQL layer is defined in [03_views.sql](../sql/03_views.sql), with ten
reference-query blocks in [04_verify.sql](../sql/04_verify.sql).

## Contents

- [Imported objects](#1-imported-objects)
- [Relationships and model configuration](#2-relationships-and-model-configuration)
- [Calculated columns](#3-calculated-columns)
- [Measures by home table](#4-measures-by-home-table)
- [Calculation patterns](#calculation-patterns)
- [Measure formats](#5-measure-formats)
- [Completed report pages](#6-completed-report-pages)
- [Historical aging scope](#7-historical-aging-scope)

## 1. Imported objects

The report imports eight objects from the SQL Server database `VISTA_AR`.
Local instance configuration is covered in the reproduction guide.

| Object | Grain | Use |
|---|---|---|
| `dim_date` | one row per day | shared calendar |
| `customers` | one row per customer | shared customer dimension |
| `vw_invoice_status` | one row per invoice | current AR and aging |
| `vw_cash_application` | one row per payment | matchability and unapplied cash |
| `vw_dispute_analysis` | one row per dispute | dispute exposure |
| `vw_analyst_performance` | one row per analyst | all-period team scorecard |
| `vw_dso_monthly` | one row per month | historical DSO / BPDSO / CEI |
| `vw_customer_risk` | one row per customer | weekly risk worklist |

Raw `invoices` and `payment_applications` are excluded. The analytical views
define the reporting layer.

The model separates two reporting scopes:

- **Current book:** open AR, aging, risk and disputes at the synthetic data's
  reporting cutoff.
- **Historical trend:** monthly DSO, BPDSO and CEI calculated by SQL in
  `vw_dso_monthly`.

Current-book measures represent the final snapshot. Historical DSO uses the
monthly view.

## 2. Relationships and model configuration

The calendar is `dim_date`, with `date_key` as its date-table column.
Relationships are **one-to-many**, with single-direction filtering from the
table on the left to the table on the right.

| From | To | Status |
|---|---|---|
| `dim_date[date_key]` | `vw_invoice_status[invoice_date]` | active |
| `dim_date[date_key]` | `vw_invoice_status[due_date]` | inactive |
| `dim_date[date_key]` | `vw_cash_application[payment_date]` | active |
| `dim_date[date_key]` | `vw_dispute_analysis[dispute_date]` | active |
| `dim_date[date_key]` | `vw_dso_monthly[month_end]` | active |
| `customers[customer_id]` | `vw_invoice_status[customer_id]` | active |
| `customers[customer_id]` | `vw_cash_application[customer_id]` | active |
| `customers[customer_id]` | `vw_dispute_analysis[customer_id]` | active |
| `customers[customer_id]` | `vw_customer_risk[customer_id]` | active |

`vw_analyst_performance` remains disconnected because it is aggregated over the
full reporting period. The Team page has no date/customer slicers.

Model configuration:

- Imported date columns use the **Date** data type; visual bindings use date
  columns rather than automatic date hierarchies.
- Amount columns use decimal numbers; indicator/count columns use whole numbers.
  Measure display formats are listed in [section 5](#5-measure-formats).
- Technical keys are hidden except `vw_customer_risk[customer_id]` and
  `vw_dispute_analysis[dispute_id]`. These visible IDs distinguish detail rows
  that share a name and use **Do not summarize**.
- `vw_invoice_status[aging_bucket]` is sorted by `aging_sort`.
  `aging_sort` and `as_of_date` are hidden; `dim_date[date_key]` remains
  available for the Cash page date slicer.

**Model validation:** relationships filter in one direction, the invoice
due-date relationship is inactive, the analyst aggregate is disconnected, and
the model has no relationship ambiguity.

## 3. Calculated columns

**Table: `dim_date`**

The saved DSO chart uses these calculated columns:

```dax
Month Label =
FORMAT ( dim_date[date_key], "MMM yyyy", "en-US" )

Month Sort =
YEAR ( dim_date[date_key] ) * 100
    + MONTH ( dim_date[date_key] )
```

`Month Label` is sorted by `Month Sort`, which uses **Do not summarize**.
The chart uses `Month Label` as a categorical axis, preserving chronological
order across years. The imported `year_month` column remains available.

## 4. Measures by home table

The 33 measures are grouped by their home table. The home table organizes a
measure in the Fields pane; it does not add a relationship. When rebuilding,
create each measure separately.

### Calculation patterns

Measures evaluate within the filters supplied by slicers, visual rows and model
relationships. These functions make that context explicit:

| Pattern | Use in VISTA |
|---|---|
| `CALCULATE` | Evaluates an expression after applying its required filters. |
| `KEEPFILTERS` | Intersects open-status, route or risk conditions with the existing selection. |
| `REMOVEFILTERS` | Clears calendar filters for the current snapshot, or only the route filter for a percentage denominator. |
| `DIVIDE` | Returns blank for a zero denominator unless an alternative result is specified. |
| `VAR` and `EOMONTH` | Capture the visible month and calculate its preceding month-end before changing filters. |
| `HASONEVALUE` | Limits customer scores and analyst rates to their defined grain, avoiding misleading totals. |
| `ISBLANK` and `COALESCE` | Distinguish missing comparisons or selections from populated selections with zero eligible payments. |

The [README examples](../README.md#dax-and-filter-context) show two complete
measures alongside their reporting purpose. The [design walkthrough](../docs/PROJECT_DEEP_DIVE.md#power-bi-model-and-report-behavior)
explains the SQL/DAX boundary and prior-month lookup.

### 4.1 Current book — vw_invoice_status

The snapshot AR measures use `REMOVEFILTERS(dim_date)` to preserve the current
book while retaining customer and segment filtering. `Current Billed` and
`Current Collected` are direct sums and retain the active invoice-date context.

```dax
Current Total AR =
CALCULATE (
    SUM ( vw_invoice_status[open_amount] ),
    KEEPFILTERS ( vw_invoice_status[is_settled] = 0 ),
    REMOVEFILTERS ( dim_date )
)

Current Past Due AR =
CALCULATE (
    SUM ( vw_invoice_status[open_amount] ),
    KEEPFILTERS ( vw_invoice_status[is_settled] = 0 ),
    KEEPFILTERS ( vw_invoice_status[aging_sort] >= 2 ),
    REMOVEFILTERS ( dim_date )
)

Current % Past Due =
DIVIDE ( [Current Past Due AR], [Current Total AR] )

Current AR 90+ =
CALCULATE (
    SUM ( vw_invoice_status[open_amount] ),
    KEEPFILTERS ( vw_invoice_status[is_settled] = 0 ),
    KEEPFILTERS ( vw_invoice_status[aging_sort] = 5 ),
    REMOVEFILTERS ( dim_date )
)

Current Billed =
SUM ( vw_invoice_status[invoice_amount] )

Current Collected =
SUM ( vw_invoice_status[amount_applied] )
```

### 4.2 Historical DSO — vw_dso_monthly

SQL calculates the monthly DSO, BPDSO and CEI values; these DAX measures select
the last visible month. Cards show the latest month by default, while a line
chart evaluates each month. The view has no customer or segment grain, so DSO
is company-wide.

`DSO_measure` distinguishes the measure from the SQL column
`vw_dso_monthly[dso]`. Visuals and dependent formulas use `[DSO_measure]`;
the report display label is DSO.

```dax
DSO_measure =
VAR LastVisibleMonth = MAX ( vw_dso_monthly[month_end] )
RETURN
    CALCULATE (
        MAX ( vw_dso_monthly[dso] ),
        vw_dso_monthly[month_end] = LastVisibleMonth
    )

Best Possible DSO =
VAR LastVisibleMonth = MAX ( vw_dso_monthly[month_end] )
RETURN
    CALCULATE (
        MAX ( vw_dso_monthly[bpdso] ),
        vw_dso_monthly[month_end] = LastVisibleMonth
    )

DSO Opportunity Days =
VAR LastVisibleMonth = MAX ( vw_dso_monthly[month_end] )
RETURN
    CALCULATE (
        MAX ( vw_dso_monthly[dso_opportunity_days] ),
        vw_dso_monthly[month_end] = LastVisibleMonth
    )

Collection Effectiveness % =
VAR LastVisibleMonth = MAX ( vw_dso_monthly[month_end] )
RETURN
    CALCULATE (
        DIVIDE ( MAX ( vw_dso_monthly[cei_pct] ), 100 ),
        vw_dso_monthly[month_end] = LastVisibleMonth
    )

DSO Previous Month =
VAR LastVisibleMonth = MAX ( vw_dso_monthly[month_end] )
VAR PriorMonthEnd = EOMONTH ( LastVisibleMonth, -1 )
RETURN
    IF (
        NOT ISBLANK ( LastVisibleMonth ),
        CALCULATE (
            MAX ( vw_dso_monthly[dso] ),
            REMOVEFILTERS ( dim_date ),
            REMOVEFILTERS ( vw_dso_monthly ),
            vw_dso_monthly[month_end] = PriorMonthEnd
        )
    )

DSO MoM Change =
IF (
    NOT ISBLANK ( [DSO_measure] ) && NOT ISBLANK ( [DSO Previous Month] ),
    [DSO_measure] - [DSO Previous Month]
)

DSO Trend Label =
VAR Change = [DSO MoM Change]
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( Change ), "No prior month",
        Change <= -2, "▼ improving",
        Change >= 2, "▲ deteriorating",
        "► flat"
    )
```

`DSO Previous Month` captures `LastVisibleMonth` before clearing both the
calendar and monthly-view filters. Clearing only one can leave the prior month
outside the available context. The explicit month-end condition then retrieves
its value; `DSO MoM Change` stays blank when either comparison value is missing.

### 4.3 Customer risk — vw_customer_risk

```dax
High Risk Customers =
CALCULATE (
    DISTINCTCOUNT ( vw_customer_risk[customer_id] ),
    KEEPFILTERS ( vw_customer_risk[risk_band] = "HIGH" )
)

High Risk Exposure =
CALCULATE (
    SUM ( vw_customer_risk[open_ar] ),
    KEEPFILTERS ( vw_customer_risk[risk_band] = "HIGH" )
)

Risk Customers =
DISTINCTCOUNT ( vw_customer_risk[customer_id] )

Risk Open AR =
SUM ( vw_customer_risk[open_ar] )

Risk Score =
IF (
    HASONEVALUE ( vw_customer_risk[customer_id] ),
    MAX ( vw_customer_risk[risk_score] )
)
```

`Risk Score` is evaluated at customer grain. It returns blank across multiple
customers instead of displaying a portfolio score. Customer detail tables
include customer ID and have totals disabled.

### 4.4 Disputes — vw_dispute_analysis

```dax
Open Dispute Value =
CALCULATE (
    SUM ( vw_dispute_analysis[blocked_amount] ),
    KEEPFILTERS ( vw_dispute_analysis[status] = "OPEN" ),
    REMOVEFILTERS ( dim_date )
)

Open Disputes =
CALCULATE (
    DISTINCTCOUNT ( vw_dispute_analysis[dispute_id] ),
    KEEPFILTERS ( vw_dispute_analysis[status] = "OPEN" ),
    REMOVEFILTERS ( dim_date )
)

Avg Open Dispute Age =
CALCULATE (
    AVERAGE ( vw_dispute_analysis[days_open] ),
    KEEPFILTERS ( vw_dispute_analysis[status] = "OPEN" ),
    REMOVEFILTERS ( dim_date )
)
```

These measures retain OPEN status and remove calendar filters for the current
dispute snapshot. `Open Dispute Value` sums disputed amounts and is not capped
to remaining invoice balances; it does not represent guaranteed recoverable
cash or incremental AR.

### 4.5 Team performance — vw_analyst_performance

```dax
Team Touches =
SUM ( vw_analyst_performance[total_touches] )

Team Promises Obtained =
SUM ( vw_analyst_performance[promises_obtained] )

PTP Kept Rate =
IF (
    HASONEVALUE ( vw_analyst_performance[analyst] ),
    DIVIDE ( MAX ( vw_analyst_performance[ptp_kept_pct] ), 100 )
)

Productive Touch Rate =
IF (
    HASONEVALUE ( vw_analyst_performance[analyst] ),
    DIVIDE ( MAX ( vw_analyst_performance[productive_touch_pct] ), 100 )
)
```

The aggregate covers **January 2025–June 2026**. The two rates are defined for
individual analysts and return blank when more than one analyst is in scope;
table totals are disabled.

PTP kept uses the SQL payment-timing proxy. It does not establish receipt of a
specific promised amount. The view lacks the eligible-promise denominator needed
for a weighted team PTP rate, so analyst percentages are not averaged or summed
into a team rate.

### 4.6 Cash application — vw_cash_application

```dax
Payment Count =
COUNTROWS ( vw_cash_application )

Straight-Through % =
DIVIDE (
    CALCULATE (
        COUNTROWS ( vw_cash_application ),
        KEEPFILTERS ( vw_cash_application[application_route] = "STRAIGHT_THROUGH" )
    ),
    COUNTROWS ( vw_cash_application )
)

Auto-Matchable % =
VAR _AutoMatchCount =
    CALCULATE (
        COUNTROWS ( vw_cash_application ),
        KEEPFILTERS ( vw_cash_application[auto_matchable] = 1 )
    )
VAR _TotalCount =
    COUNTROWS ( vw_cash_application )

RETURN
    IF (
        NOT ISBLANK ( _TotalCount ),
        COALESCE ( DIVIDE ( _AutoMatchCount, _TotalCount ), 0 )
    )

Human-Review % =
DIVIDE (
    CALCULATE (
        COUNTROWS ( vw_cash_application ),
        KEEPFILTERS ( vw_cash_application[requires_human_review] = 1 )
    ),
    COUNTROWS ( vw_cash_application )
)

Manual Research Payments =
CALCULATE (
    COUNTROWS ( vw_cash_application ),
    KEEPFILTERS ( vw_cash_application[application_route] = "MANUAL_RESEARCH" )
)

Unapplied Cash =
SUM ( vw_cash_application[unapplied_amount] )

Average Invoices Per Payment =
AVERAGE ( vw_cash_application[invoices_covered] )

Payment Route Share % =
DIVIDE (
    [Payment Count],
    CALCULATE (
        [Payment Count],
        REMOVEFILTERS ( vw_cash_application[application_route] )
    )
)
```

`application_route` is mutually exclusive:

| Route | Meaning |
|---|---|
| `STRAIGHT_THROUGH` | clean remittance, one invoice, no residual |
| `AUTO_MATCH_BATCH` | clean remittance, multiple invoices, no residual |
| `ASSISTED_REVIEW` | partial reference that needs a quick review |
| `MANUAL_RESEARCH` | PO-only/no reference or unapplied cash |

Routes describe potential automation under policy rules in the synthetic
scenario. They are not measured success rates of a deployed matching engine.

`Auto-Matchable %` uses `COALESCE` to display 0% for a populated payment
selection with no eligible payments. It remains blank when the selection has
no payment rows.

`Payment Route Share %` keeps the selected route in its numerator and removes
only `application_route` from its denominator. Segment, payment date and quality
filters remain in both counts, so the result is a share of the current payment
context rather than the entire dataset.

`Unapplied Cash` by payment month shows the amounts recorded on payments
received that month. The model cannot reconstruct an outstanding unapplied-cash
balance at each historical date.

## 5. Measure formats

| Measures | Model format |
|---|---|
| AR / exposure / dispute / unapplied amounts | USD currency, 0 decimals |
| DSO, BPDSO, opportunity, MoM change, dispute age | Decimal number, 1 decimal |
| Current % Past Due, all cash %, CEI, PTP Kept Rate, Productive Touch Rate | Percentage, 1 decimal |
| Counts | Whole number with thousands separator |
| Risk Score, Average Invoices Per Payment | Decimal number, 1 decimal |

SQL `cei_pct`, `ptp_kept_pct` and `productive_touch_pct` use 0–100.
Their measures divide by 100 before Percentage formatting; formatting raw
49.1 as Percentage would display 4,910%.

## 6. Completed report pages

The saved report has five pages. Currency values use USD, counts use whole
numbers, and rates use one decimal place. The Disputes age card displays a
whole-day value (**197**); the underlying unfiltered average is **197.4 days**.
Static headings and takeaways do not recalculate with selections.

### Page 1 — Executive

- Five cards: `Current Total AR`, `DSO_measure`, `DSO Opportunity Days`, `Current % Past Due` and `High Risk Exposure`.
- DSO line: `dim_date[Month Label]` × `DSO_measure` and `Best Possible DSO`.
- DSO date filter: **2025-04-01–2026-06-30**. The first three months have no opening AR balance. Tooltips include `DSO Opportunity Days` and `Collection Effectiveness %`.
- Segment bar: `customers[segment]` × `Current Total AR`.
- Chart selections leave the five cards and the other chart unchanged. The page preserves June headline metrics and company-wide DSO.

### Page 2 — Aging & Risk

- Segment and Analyst slicers: `customers[segment]` and `customers[assigned_analyst]`.
- Aging bar: `vw_invoice_status[aging_bucket]` × `Current Total AR`, sorted by `aging_sort`.
- Matrix: `customers[segment]` by `aging_bucket`, with `Current Total AR` as values.
- Both invoice visuals have `is_settled = 0` filters.
- Risk table: customer ID, customer name, segment, assigned analyst, risk band, `risk_score`, `open_ar`, `past_due_ar` and `worst_dpd` from `vw_customer_risk`. Customer ID has a Top 20 filter by risk score, sorted descending. Customer ID is visible and totals are disabled.

The saved risk table aggregates numeric columns within each unique customer ID.
At this grain, one row per customer makes its displayed score equal to that
customer's score. The [Risk Score measure](#43-customer-risk--vw_customer_risk)
is available for measure-based customer displays and returns blank across
multiple customers.

Segment and Analyst filter all three data visuals. The saved interactions
configure the aging chart and matrix to filter each other and the risk table.
Single-direction relationships do not propagate an invoice aging bucket back
into the customer dimension, so this setting does not make customer risk
bucket-specific or recalculate its stored scores. Risk-table selections leave
the invoice visuals unchanged.

### Page 3 — Disputes

- Segment slicer: `customers[segment]`.
- Three cards: `Open Dispute Value`, `Open Disputes` and `Avg Open Dispute Age`.
- Reason bar: `reason_code` × `Open Dispute Value`; tooltips include `Open Disputes` and `Avg Open Dispute Age`.
- Oldest-case bar: dispute ID × days open, with customer, reason and disputed amount in tooltips.
- Detail table: dispute ID, customer, segment, reason, dispute date, disputed amount and days open; totals are disabled.
- Reason, oldest-case and detail visuals retain `status = OPEN`. The oldest-case bar and detail table use Top 10 dispute IDs by maximum days open, sorted descending.

Segment filters all data visuals. Reason selections filter the cards, oldest
cases and detail. Selecting an oldest case filters only detail; detail
selections leave the other visuals unchanged. OPEN and Top 10 filters remain
in place during selections.

### Page 4 — Team Performance

- Two cards: `Team Touches` and `Team Promises Obtained`.
- Analyst bar: `analyst` × `Team Touches`; tooltips include `Team Promises Obtained`, `PTP Kept Rate` and `Productive Touch Rate`.
- Table: analyst, touches, customers worked, invoices worked, promises obtained, `PTP Kept Rate` and `Productive Touch Rate`; totals are disabled.
- Analyst selection in the chart or table filters both cards and the other data visual.

All visuals use the disconnected `vw_analyst_performance` aggregate. The period
remains January 2025–June 2026, with no customer/date slicers.
[PTP kept](#45-team-performance--vw_analyst_performance) is a payment-timing proxy
and does not establish receipt of a specific promised amount.

### Page 5 — Cash Application

- Segment slicer: `customers[segment]`.
- Payment-date slicer: `dim_date[date_key]`, limited to **2025-01-01–2026-06-30**.
- Four cards: `Straight-Through %`, `Auto-Matchable %`, `Manual Research Payments` and `Unapplied Cash`.
- Route bar: `application_route` × `Payment Count`; tooltips include `Payment Route Share %`, `Unapplied Cash` and `Average Invoices Per Payment`.
- Quality bar: `remittance_quality` × `Auto-Matchable %`; tooltips include `Payment Count`, `Human-Review %` and `Unapplied Cash`.

Segment and payment dates filter all data visuals. Route and quality charts
filter the four cards and each other. Slicer-to-slicer and chart-to-slicer
interactions are None.

Percentages evaluate the selected payment context. A selected straight-through
route can therefore show 100% auto-matchability. The static **Unfiltered view**
takeaway describes the baseline rather than the filtered selection.

## 7. Historical aging scope

The v1 aging page is a fixed snapshot as of **30 June 2026**. Dynamic as-of-date
aging is deferred: the current model imports an invoice-level final-state view,
with no payment-application history by selected date. A future implementation
requires either raw payment applications in the model or a dedicated SQL
snapshot view.
