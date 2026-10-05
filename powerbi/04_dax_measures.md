# VISTA — Power BI model and measures

This document specifies the semantic model, DAX measures and visual bindings
for the completed [VISTA report](VISTA.pbix). The
[reproduction guide](../BUILD_GUIDE.md) covers setup and refresh; the
[build log](../docs/BUILD_LOG.md) links execution and reconciliation evidence.

The SQL layer is defined in [03_views.sql](../sql/03_views.sql), with ten
reference-query blocks in [04_verify.sql](../sql/04_verify.sql). Measures below
are grouped by home table. When rebuilding, create each measure separately.

The model deliberately separates two kinds of question:

- **Current book:** open AR, aging, risk and disputes as of the final date in
  the synthetic data.
- **Historical trend:** monthly DSO, BPDSO and CEI from the SQL snapshot view.

Do not use the current-book measures to draw a historical DSO line. SQL has
already calculated that history in `vw_dso_monthly`.

## 1. Import exactly these objects

Power BI Desktop → **Get data** → **SQL Server**:

- Server: use the exact server name that worked in SSMS.
- Database: `VISTA_AR`.
- Data connectivity mode: **Import**.

Select these eight objects and nothing else:

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

Do **not** import raw `invoices` or `payment_applications`. The views are
the analytical contract for this report.

## 2. Model the relationships

First, mark `dim_date` as a date table using `date_key`.

Create the following relationships. Every relationship is **one-to-many**,
single-direction from the table on the left to the table on the right.

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

Do not create a relationship to `vw_analyst_performance`: it is already
aggregated for the full history. Keep the Team page free of date/customer
slicers.

Set all imported date columns to **Date**, not Text or Date hierarchy.
Set amount columns to decimal numbers and the indicator/count columns to
whole numbers. Section 5.2 defines the measure formats.

Hide technical keys after creating the relationships, but keep
`vw_customer_risk[customer_id]` and `vw_dispute_analysis[dispute_id]` visible:
the detail tables use those IDs to distinguish customers/disputes that share
a name. Set those IDs to **Do not summarize**.
Sort `vw_invoice_status[aging_bucket]` by `aging_sort`, then hide `aging_sort`
and `as_of_date`. Keep `date_key` available for the Cash page date slicer.

**Done test:** Model view looks like a star, has no bidirectional arrows and
has no ambiguity warning.

## 3. Current-book measures

Create these measures in `vw_invoice_status`. `REMOVEFILTERS(dim_date)` is
intentional: these are the current snapshot, not an invoice-month cohort.
Customer and segment filters still work.

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

## 4. Historical DSO measures

Create these in `vw_dso_monthly`. They take the last visible month, so a card
shows the latest month by default while a line chart shows the correct value
for each month. This view has no customer/segment grain: these measures are
company-wide and must not be presented as segment-specific DSO.

The measure is named `DSO_measure` to distinguish it from the existing SQL
column `vw_dso_monthly[dso]`. Keep that column name unchanged. Use
`[DSO_measure]` wherever another formula or visual needs the measure; the
display label on the report can still be DSO. Update existing measures
instead of creating duplicates.

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

The saved DSO chart uses two calculated columns in `dim_date`:

```dax
Month Label =
FORMAT ( dim_date[date_key], "MMM yyyy", "en-US" )

Month Sort =
YEAR ( dim_date[date_key] ) * 100
    + MONTH ( dim_date[date_key] )
```

Sort `Month Label` by `Month Sort`, set the sort column to **Do not summarize**,
and use `Month Label` itself as the categorical axis. This preserves
chronological order across years. The imported `year_month` column remains
available, but it is not the saved chart's axis.

Values are `DSO_measure` and `Best Possible DSO`. The visual date filter is
**2025-04-01–2026-06-30**; the first three months have no opening AR balance.
Tooltips include `DSO Opportunity Days` and `Collection Effectiveness %`.

## 5. Risk, disputes and cash-application measures

Use `vw_customer_risk` as the home table for the two High Risk measures,
`vw_dispute_analysis` for Open Dispute Value, and `vw_cash_application` for
the remaining four measures in this block. Create each measure separately.

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

Open Dispute Value =
CALCULATE (
    SUM ( vw_dispute_analysis[blocked_amount] ),
    KEEPFILTERS ( vw_dispute_analysis[status] = "OPEN" ),
    REMOVEFILTERS ( dim_date )
)

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
```

`application_route` is mutually exclusive:

| Route | Meaning |
|---|---|
| `STRAIGHT_THROUGH` | clean remittance, one invoice, no residual |
| `AUTO_MATCH_BATCH` | clean remittance, multiple invoices, no residual |
| `ASSISTED_REVIEW` | partial reference that needs a quick review |
| `MANUAL_RESEARCH` | PO-only/no reference or unapplied cash |

These are policy-based classifications in the synthetic scenario, not measured
success rates of a deployed matching engine. Auto-Matchable means potential
under those rules. Preserve that distinction in visual titles and conclusions.

`KEEPFILTERS` intersects a measure's condition with the current selection; it
prevents a route/risk/status selection from being silently overwritten.

`Auto-Matchable %` uses `COALESCE` to display 0% for a populated payment
selection with no eligible payments. It remains blank when the selection has
no payment rows.

### 5.1 Detail and operational measures

Create the measures under the indicated home table. Home table organizes a
measure in the Fields pane; it does not add a relationship.

**Home table: `vw_customer_risk`**

```dax
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

Use `Risk Score` only at customer grain (customer ID in the table). It returns
blank across multiple customers rather than showing a misleading portfolio
score. Turn detail-table totals off.

**Home table: `vw_dispute_analysis`**

```dax
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

Open Dispute Value is the sum of amounts on OPEN disputes. It is not capped to
remaining invoice balances, so label it **Open dispute value**, not guaranteed
cash recoverable or incremental AR.

**Home table: `vw_analyst_performance`**

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

The two rates are for an individual analyst. Turn off table totals; do not
average or sum analyst percentages to invent a team rate. The SQL view lacks
the eligible-promise denominator needed for a weighted team PTP rate. These
measures return blank when more than one analyst is in scope.

**Home table: `vw_cash_application`**

```dax
Payment Count =
COUNTROWS ( vw_cash_application )

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

`Unapplied Cash` by payment month shows the unapplied amounts recorded on
payments received that month; the model cannot reconstruct an outstanding
unapplied-cash balance at each historical date.

### 5.2 Formats

| Measures | Model format |
|---|---|
| AR / exposure / dispute / unapplied amounts | USD currency, 0 decimals |
| DSO, BPDSO, opportunity, MoM change, dispute age | Decimal number, 1 decimal |
| Current % Past Due, all cash %, CEI, PTP Kept Rate, Productive Touch Rate | Percentage, 1 decimal |
| Counts | Whole number with thousands separator |
| Risk Score, Average Invoices Per Payment | Decimal number, 1 decimal |

SQL `cei_pct`, `ptp_kept_pct`, `productive_touch_pct` already use 0–100.
The measures above divide by 100 before Percentage formatting. Do not format
raw 49.1 as Percentage or it will display 4,910%.

## 6. Completed report pages

The saved report has five pages. Currency values use USD, counts use whole
numbers, and rates use one decimal place. The Disputes age card displays a
whole-day value (**197**); the underlying unfiltered average is **197.4 days**.
Static headings and takeaways do not recalculate with selections.

### Page 1 — Executive

- Five cards: `Current Total AR`, `DSO_measure`, `DSO Opportunity Days`, `Current % Past Due` and `High Risk Exposure`.
- DSO line: `dim_date[Month Label]` × `DSO_measure` and `Best Possible DSO`, with the date filter and tooltips specified in section 4.
- Segment bar: `customers[segment]` × `Current Total AR`.
- Chart selections leave the five cards and the other chart unchanged. The page preserves June headline metrics and company-wide DSO.

### Page 2 — Aging & Risk

- Segment and Analyst slicers: `customers[segment]` and `customers[assigned_analyst]`.
- Aging bar: `vw_invoice_status[aging_bucket]` × `Current Total AR`, sorted by `aging_sort`.
- Matrix: `customers[segment]` by `aging_bucket`, with `Current Total AR` as values.
- Both invoice visuals have `is_settled = 0` filters.
- Risk table: customer ID, customer name, segment, assigned analyst, risk band, `risk_score`, `open_ar`, `past_due_ar` and `worst_dpd` from `vw_customer_risk`. Filter customer ID to Top 20 by risk score and sort descending. Keep customer ID visible and totals off.

The saved risk table aggregates numeric columns within each unique customer ID.
At this grain, one row per customer makes its displayed score equal to that
customer's score. The `Risk Score` measure in section 5.1 is available for
measure-based customer displays; it returns blank across multiple customers.

Segment and Analyst filter all three data visuals. Aging and matrix selections
filter each other, leaving customer risk unchanged. Risk-table selections leave
the invoice visuals unchanged. Single-direction relationships do not propagate
an invoice aging bucket back into the customer dimension.

### Page 3 — Disputes

- Segment slicer: `customers[segment]`.
- Three cards: `Open Dispute Value`, `Open Disputes` and `Avg Open Dispute Age`.
- Reason bar: `reason_code` × `Open Dispute Value`; tooltips include `Open Disputes` and `Avg Open Dispute Age`.
- Oldest-case bar: dispute ID × days open, with customer, reason and disputed amount in tooltips.
- Detail table: dispute ID, customer, segment, reason, dispute date, disputed amount and days open. Turn totals off.
- Reason, oldest-case and detail visuals retain `status = OPEN`. The oldest-case bar and detail table use Top 10 dispute IDs by maximum days open, sorted descending.

Segment filters all data visuals. Reason selections filter the cards, oldest
cases and detail. Selecting an oldest case filters only detail; detail
selections leave the other visuals unchanged. Preserve the OPEN and Top 10
filters during those selections.

### Page 4 — Team Performance

- Two cards: `Team Touches` and `Team Promises Obtained`.
- Analyst bar: `analyst` × `Team Touches`; tooltips include `Team Promises Obtained`, `PTP Kept Rate` and `Productive Touch Rate`.
- Table: analyst, touches, customers worked, invoices worked, promises obtained, `PTP Kept Rate` and `Productive Touch Rate`. Turn totals off.
- Analyst selection in the chart or table filters both cards and the other data visual.

All visuals use the disconnected `vw_analyst_performance` aggregate. The period
remains January 2025–June 2026, with no customer/date slicers or dispute filters.
PTP kept is the timing proxy defined in section 5.1; it does not establish
receipt of a specific promised amount.

### Page 5 — Cash Application

- Segment slicer: `customers[segment]`.
- Payment-date slicer: `dim_date[date_key]`, limited to **2025-01-01–2026-06-30**.
- Four cards: `Straight-Through %`, `Auto-Matchable %`, `Manual Research Payments` and `Unapplied Cash`.
- Route bar: `application_route` × `Payment Count`; tooltips include `Payment Route Share %`, `Unapplied Cash` and `Average Invoices Per Payment`.
- Quality bar: `remittance_quality` × `Auto-Matchable %`; tooltips include `Payment Count`, `Human-Review %` and `Unapplied Cash`.

Segment and payment dates filter all data visuals. Route and quality charts
filter the four cards and each other. Slicer-to-slicer and chart-to-slicer
interactions are None. No dispute-field filters apply to this page.

Percentages evaluate the selected payment context. A selected straight-through
route can therefore show 100% auto-matchability. The static **Unfiltered view**
takeaway describes the baseline rather than the filtered selection.

## 7. Historical aging scope

Dynamic as-of-date aging is deferred from v1. The current report
imports an invoice-level final-state view, not a payment-application history by
selected date. A correct version belongs in a later iteration and needs either
the raw payment applications in the model or a dedicated SQL snapshot view.

The v1 aging page is still valid: it is a reproducible snapshot as of the
synthetic data's final invoice date.
