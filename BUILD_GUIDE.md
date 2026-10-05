# VISTA — Reproduction guide

The saved [Power BI report](powerbi/VISTA.pbix) includes the imported data and
five report pages. Open it in Power BI Desktop to explore the completed report.
The workflow below recreates the SQL source and refreshes that report.

## Prerequisites

- Windows with PowerShell and Python 3.12 or later.
- SQL Server 2017 or later and SQL Server Management Studio (SSMS).
- Power BI Desktop.
- Git and a GitHub account for repository publication.

Run the PowerShell commands from the repository root. Use the SQL Server
instance name that works in SSMS when configuring the Power BI connection.

## 1. Prepare Python and the data

Create a virtual environment and install the generator dependencies:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -c "import numpy, pandas; print('Python ready')"
```

Using the virtual environment's executable directly avoids activation-policy
changes. **Checkpoint:** the import check prints `Python ready`.

The generated CSVs are included in `data/`. To regenerate the seeded scenario:

```powershell
.\.venv\Scripts\python.exe .\generator\generate_ar_data.py
Get-ChildItem .\data\*.csv | Select-Object Name, Length
```

**Checkpoint:** seven non-empty CSVs with these reference counts:

| Dataset | Rows |
|---|---:|
| customers | 300 |
| invoices | 30,965 |
| payments | 19,314 |
| payment_applications | 32,184 |
| disputes | 1,723 |
| collection_activity | 6,698 |
| dim_date | 636 |

The reporting cutoff is **30 June 2026**. Reproduction keeps this fixed scenario;
it does not move the data to today's date.

## 2. Load and verify SQL Server

Copy the CSVs to the loader's default directory:

```powershell
New-Item -ItemType Directory -Force -Path 'C:\VISTA\data'
Copy-Item .\data\*.csv 'C:\VISTA\data\' -Force
Get-ChildItem 'C:\VISTA\data\*.csv' | Select-Object Name, Length
```

**Checkpoint:** all seven files are present. The SQL Server service account
needs read access to this directory. For another directory, change the single
`@DataPath` value in [02_load.sql](sql/02_load.sql), keeping its trailing backslash.

Connect to the target instance in SSMS and run:

```sql
SELECT @@VERSION;
```

Confirm SQL Server 2017 or later, then execute each complete script in order:

| Order | Script | Checkpoint |
|---:|---|---|
| 1 | [01_schema.sql](sql/01_schema.sql) | `VISTA_AR` exists; schema creation completes without errors. |
| 2 | [02_load.sql](sql/02_load.sql) | Seven table counts match the CSVs; no invoice exceeds the 110% over-application threshold. |
| 3 | [03_views.sql](sql/03_views.sql) | All nine analytical views are created without errors. |
| 4 | [04_verify.sql](sql/04_verify.sql) | All ten verification blocks return results without errors, including HIGH-risk customers. |

The schema and load scripts reset existing VISTA tables. Run them against the
dedicated synthetic-project database. A final `PRINT` message alone does not
prove that earlier SQL batches succeeded; inspect execution errors and results.

The empty over-application grid confirms that specific tolerance check, not
every possible data-quality condition.

## 3. Refresh the Power BI report

Open [VISTA.pbix](powerbi/VISTA.pbix), configure its SQL Server data-source
connection for the local instance and `VISTA_AR`, then refresh and save.

**Checkpoint:** the report refreshes without errors and retains all five pages:
Executive, Aging & Risk, Disputes, Team Performance and Cash Application.

For a fresh semantic model, use **Import** mode with these eight objects:

```text
dim_date
customers
vw_invoice_status
vw_cash_application
vw_dispute_analysis
vw_analyst_performance
vw_dso_monthly
vw_customer_risk
```

The [model and DAX specification](powerbi/04_dax_measures.md) defines the
relationships and measures. Mark `dim_date[date_key]` as the date column.
Keep relationships single-direction, the invoice due-date relationship
inactive, and `vw_analyst_performance` disconnected. Do not add raw invoice
or payment-application tables to the report model.

## 4. Validate the reproduced report

Compare the unfiltered report with SQL verification and the reference results:

| Page | Baseline | Selection check |
|---|---|---|
| Executive | Open AR $607.3M; DSO 89.2; BPDSO 57.3; gap 31.9 days; past due 36.5%; high-risk exposure $49.3M | Month and segment selections leave the cards and other chart unchanged. |
| Aging & Risk | Aging and matrix sum to $607,344,176.19; HIGH risk is 41 customers / $49.3M | Segment and Analyst filter all three data visuals. Aging chart and matrix filter each other; the risk table stays unchanged by bucket selections. Risk-table selections leave other visuals unchanged. |
| Disputes | Open value $31.3M; 746 cases; average age 197.4 days | Segment filters all data visuals. Reason filters cards, oldest cases and detail; selecting an oldest case filters only detail. Detail selections leave other visuals unchanged. Retain OPEN and Top 10 filters. |
| Team Performance | 6,698 touches; 2,043 promises; 15 analysts | Chart and table selections filter both cards and each other. The period remains Jan 2025–Jun 2026; customer/date filtering is not supported. |
| Cash Application | Straight-through 45.1%; potential auto-matchable 60.1%; manual research 5,232; unapplied cash $13.9M | Segment and dates filter all data visuals. Route and quality charts filter the cards and each other, leaving slicers unchanged. |

Use **Filter**, not Highlight, for the filtering behaviors above; use **None**
for the unchanged destinations. Configure each direction separately. Cards
are not interaction sources, and text boxes remain static.

After each selection check, clear the selection and confirm that the baseline
returns. Cash percentages reflect the selected context; the static
**Unfiltered view** takeaway describes the baseline only. Potential
auto-matchability is a rule-based classification, not matching-engine performance.

The DSO chart covers **April 2025–June 2026**. Current aging uses the final-date
snapshot, while Team uses full-period analyst aggregates. Gross open AR is
$607.3M; the generator's $606.9M is net AR including credit balances. Current-book
past due is 36.5%, compared with 35.8% in the monthly snapshot because invoices
due on the cutoff date are classified differently.

## 5. Save evidence and record completion

Before capturing the report, clear chart/table selections, set categorical
slicers to **All**, and restore Cash payment dates to **2025-01-01–2026-06-30**.
Save the PBIX, use Fit to page, and capture the canvas with headings, units and
scope visible.

| Checkpoint | Evidence path |
|---|---|
| Python generation | `screenshots/build/00-python-generation.png` |
| SQL load and row counts | `screenshots/build/01-sql-load.png` |
| Power BI model | `screenshots/build/03-powerbi-model.png` |
| SQL block 2 — Aging | `screenshots/sql/01-aging-profile.png` |
| SQL block 4 — DSO | `screenshots/sql/02-dso-trend.png` |
| SQL block 6 — Risk | `screenshots/sql/03-risk-bands.png` |
| SQL block 8 — Cash routes | `screenshots/sql/04-cash-application.png` |
| Executive | `screenshots/powerbi/01-executive.png` |
| Aging & Risk | `screenshots/powerbi/02-aging-risk.png` |
| Disputes | `screenshots/powerbi/03-disputes.png` |
| Team Performance | `screenshots/powerbi/04-team-performance.png` |
| Cash Application | `screenshots/powerbi/05-cash-application.png` |

Import evidence at `screenshots/build/02-powerbi-import.png` is optional.
For SQL screenshots, execute the relevant block separately and show its title,
column headers and successful execution status.

Record execution dates, reconciliation results, model/report completion and
interaction-check outcomes in [BUILD_LOG.md](docs/BUILD_LOG.md). Link the saved
PBIX and existing evidence rather than creating duplicate screenshots. Record
a reproduction only after performing its checks.

## 6. Finalize and publish the repository

The [README](README.md) presents the finished report, actual findings, PBIX and
validation evidence. Confirm its numbers and links against the saved artifacts.
Public documents must not link to files excluded from publication.

The project's [.gitignore](.gitignore) excludes private career context,
the private visual construction guide and its layout mockups, temporary PDF
printouts, local environments and report backups. Keep those exclusions in place.
The [.gitattributes](.gitattributes) file preserves LF line endings in the CSVs
so Git checkouts remain compatible with the SQL loader.

For a new repository, stage the public project files:

```powershell
git init
git add README.md BUILD_GUIDE.md requirements.txt .gitignore .gitattributes docs generator sql powerbi data screenshots
git status --short
git diff --cached --stat
git ls-files '*.pdf' 'context of who i am/*' 'powerbi/05_visual_build_guide.md' 'powerbi/layouts/*' '.local-backups/*'
```

**Checkpoint:** the last command returns no files, and the staged list contains
the saved report, data, source scripts, public documents and evidence. Ignore
rules do not remove files already tracked by Git; remove any such private or
temporary files from the index before committing.

Commit the reviewed files:

```powershell
git commit -m "Complete VISTA AR analytics portfolio project"
git branch -M main
```

For a new publication, create an empty GitHub repository and use its remote URL.
The published VISTA repository uses this URL:

```powershell
git remote add origin https://github.com/mario-narvaez/Vista-AR-Project.git
git push -u origin main
```

For an existing repository, use its configured remote and branch. After the
push, check the GitHub README images, evidence links and PBIX download, confirm
the private and temporary files are absent, and record the repository URL and
publication date in the build log.

## Troubleshooting

| Symptom | Check |
|---|---|
| `py` is unavailable | Install Python with the Windows launcher and reopen PowerShell. |
| Generator imports fail | Install `requirements.txt` using the same virtual-environment executable used to run the generator. |
| SQL cannot open a CSV | Check `@DataPath`, file presence and SQL Server service-account read access. |
| SQL rejects CSV `FORMAT` | Confirm SQL Server 2017 or later. |
| A verification block fails | Resolve the SQL error or unexpected result before refreshing Power BI. |
| Power BI cannot connect | Use the exact instance name that works in SSMS and confirm `VISTA_AR` exists. |
| Report totals differ | Clear selections and slicers, then compare each metric with its matching SQL view and reporting scope. |
