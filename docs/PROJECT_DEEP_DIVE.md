# VISTA — Design Deep Dive

VISTA is a completed local receivables analytics project for a synthetic
multi-segment optical distributor. It connects **Python → SQL Server → Power BI**
to explain current exposure, collection trends and potential cash-application
automation.

This document explains the design decisions and their implications. The
[README](../README.md) presents the dashboards, the
[reproduction guide](../BUILD_GUIDE.md) covers execution, and the
[build log](BUILD_LOG.md) records completion and supporting evidence.

## Business context and contribution

The project addresses three collections-management questions: where cash is
concentrated, which customers need attention, and how to prioritize the team's
work. Aging, payment behavior, disputes and remittance quality provide different
parts of that answer.

My business perspective comes from five years in AR operations at
EssilorLuxottica across key accounts, managed care, retail and collections
leadership. As Collections Supervisor, I led 15 analysts against a $215M monthly
target. That experience informed the questions this portfolio project explores;
the transactions and results below belong entirely to the synthetic scenario.

AI assistance supported the initial project design and documentation. My
contribution was executing the Python and SQL pipeline locally, building the
Power BI report, reconciling its outputs with SQL results, and adapting the page
interactions to the model's grain. The saved report and build evidence document
that implementation.

## Synthetic data design

The [generator](../generator/generate_ar_data.py) uses a fixed random seed of 42
and models transactions from January 2025 through June 2026. Segment settings
vary invoice frequency, invoice value, payment terms, delays, short payments,
dispute reasons and payment consolidation.

| Segment | Scenario emphasis |
|---|---|
| KEY_ACCOUNT | Few large invoices, negotiated terms and concentrated exposure |
| MANAGED_CARE | Longer payment delays, adjudication-related disputes and consolidated payments |
| RETAIL | Higher invoice volume, deductions, pricing variances and chargebacks |

These are explicit simulation assumptions. They demonstrate how different
collection patterns affect reporting; they are not estimates calibrated from
employer or customer records. The main remittance-quality probabilities are
shared across segments, while the late-collection sweep has its own quality mix.

The generator includes partial payments, deduction residuals, missing or
incomplete remittance references, unapplied cash and customers whose payment
delays increase over time. A later collection sweep clears some aged balances.
These features create cases that require more than a balance total.

| Dataset | Rows | Role |
|---|---:|---|
| customers | 300 | Segment, credit limit and assigned analyst |
| invoices | 30,965 | Billing and contractual due dates |
| payments | 19,314 | Cash receipts and remittance quality |
| payment_applications | 32,184 | Allocation of payments to invoices |
| disputes | 1,723 | Disputed amounts, reasons and status |
| collection_activity | 6,698 | Contacts, outcomes and promises to pay |
| dim_date | 636 | Shared reporting calendar |

At the **30 June 2026** cutoff, the generated book contains **$3.49B billed**
and **$2.88B cash applied**. Net AR is **$606.9M**; the report's **$607.3M**
gross open AR excludes settled invoices and credit balances.

## Relational storage and loading

The [schema](../sql/01_schema.sql) separates customers, invoices, payments,
applications, disputes and collection activity. Primary and foreign keys
preserve identity and relationships. Checks enforce rules such as positive
invoice amounts and due dates on or after invoice dates. Indexes support the
joins and customer/date access patterns used by the analytical views.

The [loader](../sql/02_load.sql) first imports CSV fields into text staging
tables. `NULLIF` normalizes empty optional fields, and `TRY_CONVERT` makes
conversion to dates and numeric types explicit before insertion into the typed
tables. A malformed required value can still fail the typed insert through a
constraint; staging makes the source value available for inspection.

The [verification script](../sql/04_verify.sql) produces the reference grids for
aging, DSO, risk and payment routes. The saved load evidence confirms all seven
row counts and no invoices exceeding the loader's 110% over-application
tolerance. That tolerance check is distinct from proving that every invoice has
zero over-application.

## Analytical layer

Nine [SQL views](../sql/03_views.sql) separate business calculations from visual
presentation.

| View | Purpose |
|---|---|
| `vw_invoice_status` | Final-date invoice balance, aging and settlement status |
| `vw_ar_aging` | Customer-level aging totals |
| `vw_ar_snapshot_monthly` | Historical balances reconstructed at month end |
| `vw_dso_monthly` | Company-wide DSO, BPDSO, CEI and past-due percentage |
| `vw_cash_application` | Payment routing and unapplied cash |
| `vw_customer_risk` | Customer exposure, score and risk band |
| `vw_dispute_analysis` | Dispute amount, reason, status and age |
| `vw_analyst_performance` | Analyst activity and outcome proxies |
| `vw_exec_kpi` | Latest executive headline metrics |

### Current balances and historical DSO

Current aging uses the final invoice date as its reporting cutoff. Historical
DSO needs a different calculation: an invoice's final open balance cannot show
what was outstanding before later payments arrived.

The monthly snapshot therefore aggregates applications by invoice and month
end in a CTE, joins them to invoices issued by that date, and calculates the
balance remaining at each cutoff. Only balances above $1 enter the monthly
gross AR total. This is the implemented set-based calculation; its structure
explains the historical reconstruction without relying on runtime claims.

The DSO view uses a trailing three-month sales sum through a window function.
It calculates DSO as AR divided by those sales, multiplied by the number of
months in the window times **30.4 days**. A full three-month window therefore
uses **91.2 days**. BPDSO applies the same basis to current AR, and the gap
expresses past-due exposure in days of sales. `LAG` supplies the prior balance
used by CEI.

The first three months have no opening receivables balance. The report uses
**April 2025 onward** for the DSO trend. The monthly DSO view aggregates all
segments, so it supports company-wide rather than customer-level DSO.

### Customer risk

The risk score combines five components, each capped at its maximum points.

| Maximum points | Component | Scaling |
|---:|---|---|
| 35 | Past-due exposure | Past-due AR / open AR |
| 25 | Increasing payment delay | Recent average lateness minus all-period average; zero at or below 0 days, capped at 45 days |
| 20 | Aged exposure | AR aged 61+ days / open AR |
| 10 | Dispute frequency | Dispute count / invoice count, capped at a 25% rate |
| 10 | Credit utilization | Open AR / credit limit, capped at 100% |

Payment-delay averages use settled invoices. The recent cohort is selected by
invoice date from four months before the reporting cutoff. The trend component
adds a deterioration signal alongside the larger past-due exposure component.

Bands use the unrounded score: **HIGH ≥ 38**, **MEDIUM ≥ 26 and < 38**, and
**LOW < 26**. The displayed score is rounded to one decimal place. The current
book has **41 HIGH-risk customers out of 300 (13.7%)**, holding **$49.3M** of open
AR. These are heuristic prioritization rules; the thresholds do not establish a
probability of default or a validated weekly workload for 15 analysts.

### Payment routing and analyst outcomes

Cash routing classifies recorded payment attributes and application counts.

| Route | Rule | Payments | Share |
|---|---|---:|---:|
| STRAIGHT_THROUGH | CLEAN reference, one invoice, no unapplied cash | 8,705 | 45.1% |
| AUTO_MATCH_BATCH | CLEAN reference, multiple invoices, no unapplied cash | 2,897 | 15.0% |
| ASSISTED_REVIEW | PARTIAL reference, no unapplied cash | 2,480 | 12.8% |
| MANUAL_RESEARCH | Remaining cases | 5,232 | 27.1% |

The first two routes together represent **60.1% potential auto-matchability**.
Assisted review and manual research represent **39.9% human review**. These
classifications describe automation candidates; they do not measure a matching
engine's accuracy or processing time.

The analyst view aggregates the full reporting period. Its promise-kept proxy
checks whether any application to the invoice occurred on or after the contact
date and by three days after the promise date. Promises due after the reporting
cutoff are excluded from that rate. Since no promised amount is recorded, the
proxy measures payment timing rather than fulfillment of a monetary commitment.

## Power BI model and report behavior

The model imports two dimensions, `dim_date` and `customers`, and six views:
invoice status, cash application, dispute analysis, analyst performance,
monthly DSO and customer risk. Raw invoices and applications remain in SQL,
where the balance calculations are resolved.

Relationships filter in one direction from dimensions to reporting views.
The invoice-date relationship is active and the due-date relationship inactive.
Current aging measures use `REMOVEFILTERS(dim_date)` to retain the final-date
snapshot while preserving customer and segment selections. They do not use
`USERELATIONSHIP` to activate the due-date relationship.

Historical cards select the latest visible month from the monthly DSO view.
The prior-month measure uses `EOMONTH` and resets date and view filters before
retrieving the previous month. Customer risk is displayed at customer-ID grain;
the top-20 worklist uses a visual Top N filter rather than a DAX `TOPN` measure.

The report's interactions follow the available grain:

| Page | Design decision |
|---|---|
| Executive | Preserve the June headline cards and company-wide DSO when selecting a month or segment in the charts |
| Aging & Risk | Segment and analyst filter both invoice aging and customer risk; bucket selections filter invoice visuals without implying a customer-risk recalculation |
| Disputes | Segment and reason narrow the open cases; selecting an oldest case filters detail without changing the summary cards |
| Team Performance | Analyst selection filters the cards and the other analyst visual within a fixed full-period aggregate |
| Cash Application | Segment, payment dates, route and quality filter the payment context and its percentages |

The analyst aggregate is disconnected because it contains one full-period row
per analyst, without customer or date grain. Dynamic historical aging is
deferred: the report's invoice-level view contains final balances, so a correct
as-of selector would require historical applications or dedicated snapshots.

The [model and DAX specification](../powerbi/04_dax_measures.md) defines the
measures and relationships. The [saved PBIX](../powerbi/VISTA.pbix) contains the
completed five-page report.

## Findings from the completed build

The reconciled results describe the synthetic scenario.

- **Receivables slowed:** DSO increased from **69.8 days in April 2025** to
  **89.2 days in June 2026**. June BPDSO is **57.3 days**, leaving a **31.9-day**
  gap. The gap quantifies exposure on the stated sales basis, rather than a
  forecast of cash recoverable within 31.9 days.
- **Exposure is concentrated:** **35 key accounts** hold **$384.6M**, or
  **63.3%** of gross open AR. Prioritization needs balance size alongside risk
  scores and customer counts.
- **Payment behavior varies:** settled invoices average **65.9 days late** in
  managed care, **53.5** in retail and **35.4** in key accounts. These modeled
  differences support examining segment-specific follow-up.
- **Disputes have a long-open backlog:** **746 open cases** total **$31.3M**,
  with a mean age of **197.4 days**. Pricing variance is the largest reason
  category at **$4.9M**. Disputed amounts are not capped to remaining invoice
  balances, so their sum is not incremental AR or guaranteed recoverable cash.
- **Cash application has distinct work queues:** the **60.1%** potential
  auto-matchability share differs from the **27.1%** manual-research share.
  Recorded unapplied cash totals **$13.9M**.
- **Team activity provides operational context:** **6,698 touches** and
  **2,043 promises obtained** span 15 analysts. The outcome proxies should be
  interpreted alongside customer mix and exposure.

Current-book past due is **36.5%**, versus **35.8%** in the June monthly
snapshot. Current aging places invoices due on the cutoff date in the past-due
buckets; the monthly snapshot treats them as current. This boundary convention
explains the difference.

The [build log](BUILD_LOG.md) links SQL reconciliation grids, model evidence and
all five dashboard captures. Local implementation and report QA are complete;
repository publication is tracked separately.

## Roadmap

VISTA's analytical report is the completed local foundation. The following
extensions are planned work:

1. **Cash-application matcher:** implement exact-reference and batch matching
   first, then evaluate ambiguous references and amount combinations. Compare
   proposed matches with the known synthetic application records. The current
   **60.1%** eligibility estimate is a starting classification, while **39.9%**
   belongs to human-review routes; only **27.1%** is labeled manual research.
   Report matching accuracy, exception handling and measured processing time
   before claiming automation gains.
2. **Historical aging:** expose balances reconstructed for a selected date and
   validate them against SQL snapshots before introducing an as-of slicer.
3. **AR close assistant:** explore remittance extraction, dispute triage and
   draft collection outreach after defining inputs and evaluation criteria.
   This remains a proposed extension beyond the finished report.

---

**Mario Eduardo Narvaez Bernal** · Chihuahua, Mexico  
MBA (Finance), Universidad Tecmilenio · B.S. Finance, UACH  
[linkedin.com/in/marionarvaez](https://www.linkedin.com/in/marionarvaez/)
