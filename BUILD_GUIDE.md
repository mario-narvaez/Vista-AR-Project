# VISTA — Reproduction guide

The saved [Power BI report](powerbi/VISTA.pbix) contains imported data and five
report pages. Open it in Power BI Desktop to explore the report. The steps below
recreate its SQL source and refresh the model.

## Prerequisites

- Windows with PowerShell and Python 3.12 or later.
- SQL Server 2017 or later and SQL Server Management Studio (SSMS).
- Power BI Desktop.

Run the PowerShell commands from the repository root. Use the same SQL Server
instance in SSMS and Power BI.

## 1. Prepare the data

The seven generated CSVs are included in `data/`. To regenerate them, create a
virtual environment and install the [dependencies](requirements.txt):

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe .\generator\generate_ar_data.py
```

Using the environment's executable directly avoids activation-policy changes.
The seeded scenario has a fixed reporting cutoff of **30 June 2026**.

**Expected row counts:**

| Dataset | Rows |
|---|---:|
| customers | 300 |
| invoices | 30,965 |
| payments | 19,314 |
| payment_applications | 32,184 |
| disputes | 1,723 |
| collection_activity | 6,698 |
| dim_date | 636 |

## 2. Load and verify SQL Server

Copy the CSVs to the loader's default directory:

```powershell
New-Item -ItemType Directory -Force -Path 'C:\VISTA\data'
Copy-Item .\data\*.csv 'C:\VISTA\data\' -Force
```

The SQL Server service account needs read access to that directory. To use
another location, change `@DataPath` in [02_load.sql](sql/02_load.sql), keeping
its trailing backslash.

Run each complete script in SSMS, in this order:

| Order | Script | Expected result |
|---:|---|---|
| 1 | [01_schema.sql](sql/01_schema.sql) | `VISTA_AR` and its schema are created. |
| 2 | [02_load.sql](sql/02_load.sql) | Seven table counts match the CSVs; no invoice exceeds the 110% over-application threshold. |
| 3 | [03_views.sql](sql/03_views.sql) | Nine analytical views are created. |
| 4 | [04_verify.sql](sql/04_verify.sql) | All ten verification blocks execute without errors and match the reference results below. |

The schema and loader reset existing VISTA tables; use the dedicated synthetic
project database. Inspect SQL errors and result grids, rather than relying on
the final `PRINT` message. The over-application query checks only its stated
tolerance.

## 3. Refresh Power BI

Open [VISTA.pbix](powerbi/VISTA.pbix). In **Data source settings**, change the SQL
Server connection to your local instance and `VISTA_AR`, then refresh and save.

**Checkpoint:** refresh completes without errors and all five pages remain:
Executive, Aging & Risk, Disputes, Team Performance and Cash Application.

For a fresh model, follow the [model and DAX specification](powerbi/04_dax_measures.md)
for the import objects, relationships, measures and report configuration.

## 4. Check the results

Clear chart and table selections, set categorical slicers to **All**, and restore
Cash payment dates to **2025-01-01–2026-06-30**. Compare the refreshed report with
SQL verification:

| Page | Reference results |
|---|---|
| Executive | Open AR $607.3M; DSO 89.2 days; BPDSO 57.3 days; gap 31.9 days; past due 36.5%; high-risk exposure $49.3M |
| Aging & Risk | Aging and matrix total $607,344,176.19; HIGH risk: 41 customers / $49.3M |
| Disputes | 746 open cases totaling $31.3M; mean age 197.4 days, displayed as 197 on the card |
| Team Performance | 6,698 touches; 2,043 promises; 15 analysts |
| Cash Application | Straight-through 45.1%; potential auto-matchable 60.1%; manual research 5,232; unapplied cash $13.9M |

The DSO trend starts in **April 2025**. Aging uses the final-date snapshot; Team
uses full-period aggregates. Gross open AR is **$607.3M**, while the generator's
**$606.9M** net AR includes credit balances. Current-book past due is **36.5%**,
compared with **35.8%** in the June monthly snapshot because invoices due on the
cutoff date are classified differently.

Check selections against the [documented page interactions](powerbi/04_dax_measures.md#6-completed-report-pages),
then clear them to confirm the baseline returns. The [build log](docs/BUILD_LOG.md)
contains the executed validation results and evidence.

## Troubleshooting

| Symptom | Check |
|---|---|
| SQL cannot open a CSV | Confirm `@DataPath`, file presence and SQL Server service-account read access. |
| SQL rejects CSV `FORMAT` | Confirm SQL Server 2017 or later. |
| Power BI cannot connect | Use the instance name that works in SSMS and confirm `VISTA_AR` exists. |
| Report totals differ | Clear selections and slicers, then compare each metric with its matching SQL view and reporting scope. |
