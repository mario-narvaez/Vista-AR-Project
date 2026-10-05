/* ==========================================================================
   VISTA - 04_verify.sql
   Run this after 03_views.sql.

   Two jobs:
     1. Runs ten reference-query blocks covering source row counts and
        analytical outputs after the nine views have been created.
     2. Produces the headline numbers for your README. Screenshot blocks
        2, 4, 6 and 8 - those are the four findings worth writing up.
   ========================================================================== */

USE VISTA_AR;
GO

PRINT '=== 1. ROW COUNTS - all seven should be non-zero ===';
SELECT 'customers' AS table_name, COUNT(*) AS rows FROM dbo.customers
UNION ALL SELECT 'invoices',             COUNT(*) FROM dbo.invoices
UNION ALL SELECT 'payments',             COUNT(*) FROM dbo.payments
UNION ALL SELECT 'payment_applications', COUNT(*) FROM dbo.payment_applications
UNION ALL SELECT 'disputes',             COUNT(*) FROM dbo.disputes
UNION ALL SELECT 'collection_activity',  COUNT(*) FROM dbo.collection_activity
UNION ALL SELECT 'dim_date',             COUNT(*) FROM dbo.dim_date;


PRINT '=== 2. AGING PROFILE - reference 63.5% current, 5.2% at 90+ ===';
SELECT
    aging_bucket,
    COUNT(*)                                              AS invoice_count,
    CAST(SUM(open_amount)/1000000 AS DECIMAL(10,1))       AS open_millions,
    CAST(100.0 * SUM(open_amount)
         / SUM(SUM(open_amount)) OVER () AS DECIMAL(5,1)) AS pct_of_ar
FROM dbo.vw_invoice_status
WHERE is_settled = 0
GROUP BY aging_bucket, aging_sort
ORDER BY aging_sort;


PRINT '=== 3. EXECUTIVE KPI - one row, the headline cards ===';
SELECT * FROM dbo.vw_exec_kpi;


PRINT '=== 4. DSO TREND - the story. Ignore the first 3 months (ramp-up) ===';
SELECT
    month_end,
    CAST(credit_sales/1000000 AS DECIMAL(10,1)) AS sales_millions,
    CAST(ar_balance/1000000   AS DECIMAL(10,1)) AS ar_millions,
    dso,
    bpdso,
    dso_opportunity_days,
    cei_pct,
    pct_past_due
FROM dbo.vw_dso_monthly
ORDER BY month_end;


PRINT '=== 5. SEGMENT BEHAVIOUR - compare exposure and settled-invoice lateness ===';
SELECT
    segment,
    COUNT(DISTINCT customer_id)                             AS customers,
    CAST(SUM(CASE WHEN is_settled=0 THEN open_amount ELSE 0 END)/1000000
         AS DECIMAL(10,1))                                  AS open_ar_millions,
    CAST(AVG(CAST(days_paid_late AS FLOAT)) AS DECIMAL(10,1)) AS avg_days_paid_late,
    CAST(100.0 * SUM(CASE WHEN is_settled=0 THEN open_amount ELSE 0 END)
         / SUM(SUM(CASE WHEN is_settled=0 THEN open_amount ELSE 0 END)) OVER ()
         AS DECIMAL(5,1))                                   AS pct_of_open_ar
FROM dbo.vw_invoice_status
GROUP BY segment
ORDER BY open_ar_millions DESC;


PRINT '=== 6. RISK BANDS - reference HIGH 41 of 300 customers (13.7%) ===';
SELECT
    risk_band,
    COUNT(*)                                        AS customers,
    CAST(SUM(open_ar)/1000000 AS DECIMAL(10,1))     AS exposure_millions,
    CAST(AVG(risk_score) AS DECIMAL(5,1))           AS avg_score
FROM dbo.vw_customer_risk
GROUP BY risk_band
ORDER BY avg_score DESC;


PRINT '=== 7. TOP 15 RISK ACCOUNTS - this is the Monday work list ===';
SELECT TOP 15
    customer_name,
    segment,
    assigned_analyst,
    CAST(open_ar/1000     AS DECIMAL(12,0)) AS open_ar_k,
    CAST(past_due_ar/1000 AS DECIMAL(12,0)) AS past_due_k,
    worst_dpd,
    CAST(avg_days_late    AS DECIMAL(6,1))  AS avg_days_late,
    CAST(delay_trend      AS DECIMAL(6,1))  AS delay_trend,
    risk_score,
    risk_band
FROM dbo.vw_customer_risk
ORDER BY risk_score DESC;


PRINT '=== 8. CASH APPLICATION ROUTES - potential automation and review queues ===';
SELECT
    application_route,
    COUNT(*)                                                          AS payments,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))  AS pct_of_payments,
    CAST(AVG(CAST(invoices_covered AS FLOAT)) AS DECIMAL(5,2))       AS avg_invoices_per_payment,
    CAST(SUM(unapplied_amount)/1000 AS DECIMAL(12,0))                AS unapplied_k
FROM dbo.vw_cash_application
GROUP BY application_route
ORDER BY CASE application_route
    WHEN 'STRAIGHT_THROUGH' THEN 1
    WHEN 'AUTO_MATCH_BATCH' THEN 2
    WHEN 'ASSISTED_REVIEW' THEN 3
    ELSE 4
END;


PRINT '=== 9. DISPUTES BY REASON ===';
SELECT
    segment,
    reason_code,
    COUNT(*)                                                AS disputes,
    SUM(CASE WHEN status='OPEN' THEN 1 ELSE 0 END)          AS still_open,
    CAST(SUM(blocked_amount)/1000 AS DECIMAL(12,0))         AS blocked_k,
    CAST(AVG(CAST(days_open AS FLOAT)) AS DECIMAL(6,0))     AS avg_days_open
FROM dbo.vw_dispute_analysis
GROUP BY segment, reason_code
ORDER BY blocked_k DESC;


PRINT '=== 10. ANALYST PERFORMANCE ===';
SELECT * FROM dbo.vw_analyst_performance ORDER BY total_touches DESC;

PRINT '';
PRINT '>>> Confirm all ten blocks executed without errors and reconcile results with the reference book.';
PRINT '>>> Screenshot blocks 2, 4, 6 and 8 for the README.';
PRINT '>>> Model and measure definitions: powerbi/04_dax_measures.md';
