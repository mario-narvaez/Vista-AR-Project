/* ==========================================================================
   VISTA - AR Collections Analytics
   03_views.sql : the analytical layer Power BI reads

   Design note: every view derives its "as of" date from the data itself
   (max invoice date) rather than GETDATE(), so the model stays reproducible
   no matter when it is run.
   ========================================================================== */

USE VISTA_AR;
GO

/* ==========================================================================
   1. INVOICE STATUS - the foundation every other view builds on
   Open balance, days past due, aging bucket, dispute state.
   ========================================================================== */
IF OBJECT_ID('dbo.vw_invoice_status','V') IS NOT NULL DROP VIEW dbo.vw_invoice_status;
GO
CREATE VIEW dbo.vw_invoice_status AS
WITH asof AS (SELECT MAX(invoice_date) AS as_of FROM dbo.invoices),
applied AS (
    SELECT invoice_id,
           SUM(applied_amount) AS applied_amount,
           MAX(applied_date)   AS last_applied_date,
           MIN(applied_date)   AS first_applied_date
    FROM dbo.payment_applications
    GROUP BY invoice_id
),
disp AS (
    SELECT invoice_id,
           SUM(CASE WHEN status='OPEN' THEN amount_disputed ELSE 0 END) AS open_dispute_amt,
           MAX(CASE WHEN status='OPEN' THEN 1 ELSE 0 END)               AS has_open_dispute,
           COUNT(*)                                                      AS dispute_count
    FROM dbo.disputes
    GROUP BY invoice_id
)
SELECT
    i.invoice_id,
    i.customer_id,
    c.customer_name,
    c.segment,
    c.region,
    c.assigned_analyst,
    i.invoice_date,
    i.due_date,
    i.invoice_amount,
    ISNULL(a.applied_amount,0)                                   AS amount_applied,
    CAST(i.invoice_amount - ISNULL(a.applied_amount,0) AS DECIMAL(18,2)) AS open_amount,
    CASE WHEN i.invoice_amount - ISNULL(a.applied_amount,0) <= 1
         THEN 1 ELSE 0 END                                       AS is_settled,
    /* days past due at the as-of date; negative = not yet due */
    DATEDIFF(DAY, i.due_date, x.as_of)                           AS days_past_due,
    /* days it actually took to collect - the input to true DSO analysis */
    CASE WHEN i.invoice_amount - ISNULL(a.applied_amount,0) <= 1
         THEN DATEDIFF(DAY, i.invoice_date, a.last_applied_date)
    END                                                          AS days_to_pay,
    CASE WHEN i.invoice_amount - ISNULL(a.applied_amount,0) <= 1
         THEN DATEDIFF(DAY, i.due_date, a.last_applied_date)
    END                                                          AS days_paid_late,
    CASE
        WHEN i.invoice_amount - ISNULL(a.applied_amount,0) <= 1 THEN 'SETTLED'
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) < 0   THEN 'CURRENT'
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) <= 30 THEN '1-30'
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) <= 60 THEN '31-60'
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) <= 90 THEN '61-90'
        ELSE '90+'
    END                                                          AS aging_bucket,
    CASE
        WHEN i.invoice_amount - ISNULL(a.applied_amount,0) <= 1 THEN 0
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) < 0   THEN 1
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) <= 30 THEN 2
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) <= 60 THEN 3
        WHEN DATEDIFF(DAY, i.due_date, x.as_of) <= 90 THEN 4
        ELSE 5
    END                                                          AS aging_sort,
    /* partially paid but not settled = a deduction/short-pay residual */
    CASE WHEN ISNULL(a.applied_amount,0) > 0
           AND i.invoice_amount - ISNULL(a.applied_amount,0) > 1
         THEN 1 ELSE 0 END                                       AS is_short_paid,
    ISNULL(d.has_open_dispute,0)                                 AS has_open_dispute,
    ISNULL(d.open_dispute_amt,0)                                 AS open_dispute_amount,
    ISNULL(d.dispute_count,0)                                    AS dispute_count,
    x.as_of                                                      AS as_of_date
FROM dbo.invoices i
JOIN dbo.customers c ON c.customer_id = i.customer_id
LEFT JOIN applied a  ON a.invoice_id  = i.invoice_id
LEFT JOIN disp   d   ON d.invoice_id  = i.invoice_id
CROSS JOIN asof x;
GO

/* ==========================================================================
   2. AR AGING SUMMARY - the classic aging report, pivoted
   ========================================================================== */
IF OBJECT_ID('dbo.vw_ar_aging','V') IS NOT NULL DROP VIEW dbo.vw_ar_aging;
GO
CREATE VIEW dbo.vw_ar_aging AS
SELECT
    customer_id, customer_name, segment, region, assigned_analyst,
    SUM(open_amount)                                                   AS total_open,
    SUM(CASE WHEN aging_bucket='CURRENT' THEN open_amount ELSE 0 END)   AS bkt_current,
    SUM(CASE WHEN aging_bucket='1-30'    THEN open_amount ELSE 0 END)   AS bkt_1_30,
    SUM(CASE WHEN aging_bucket='31-60'   THEN open_amount ELSE 0 END)   AS bkt_31_60,
    SUM(CASE WHEN aging_bucket='61-90'   THEN open_amount ELSE 0 END)   AS bkt_61_90,
    SUM(CASE WHEN aging_bucket='90+'     THEN open_amount ELSE 0 END)   AS bkt_90_plus,
    SUM(CASE WHEN aging_bucket IN ('1-30','31-60','61-90','90+')
             THEN open_amount ELSE 0 END)                              AS total_past_due,
    SUM(open_dispute_amount)                                           AS disputed_open,
    COUNT(*)                                                           AS open_invoice_count,
    MAX(days_past_due)                                                 AS worst_days_past_due
FROM dbo.vw_invoice_status
WHERE is_settled = 0
GROUP BY customer_id, customer_name, segment, region, assigned_analyst;
GO

/* ==========================================================================
   3. MONTHLY AR SNAPSHOT - AR as it stood at each month end
   Required for DSO/CEI trending. Rebuilds the balance at every month end by
   comparing invoice date and cash-application date to that month end.
   ========================================================================== */
IF OBJECT_ID('dbo.vw_ar_snapshot_monthly','V') IS NOT NULL DROP VIEW dbo.vw_ar_snapshot_monthly;
GO
CREATE VIEW dbo.vw_ar_snapshot_monthly AS
WITH month_ends AS (
    SELECT DISTINCT EOMONTH(date_key) AS month_end
    FROM dbo.dim_date
    WHERE date_key >= (SELECT MIN(invoice_date) FROM dbo.invoices)
      AND EOMONTH(date_key) <= (SELECT MAX(invoice_date) FROM dbo.invoices)
),
/* Aggregate applications by invoice and month end before joining them
   to the invoices issued by that cutoff. */
app_cum AS (
    SELECT a.invoice_id, m.month_end, SUM(a.applied_amount) AS applied_to_date
    FROM month_ends m
    JOIN dbo.payment_applications a ON a.applied_date <= m.month_end
    GROUP BY a.invoice_id, m.month_end
),
bal AS (
    SELECT m.month_end,
           i.customer_id,
           i.invoice_id,
           i.due_date,
           i.invoice_amount - ISNULL(ac.applied_to_date,0) AS open_amount
    FROM month_ends m
    JOIN dbo.invoices i  ON i.invoice_date <= m.month_end
    LEFT JOIN app_cum ac ON ac.invoice_id = i.invoice_id
                        AND ac.month_end = m.month_end
)
SELECT
    b.month_end,
    c.segment,
    SUM(b.open_amount)                                                    AS ar_balance,
    SUM(CASE WHEN b.due_date >= b.month_end THEN b.open_amount ELSE 0 END) AS ar_current,
    SUM(CASE WHEN b.due_date <  b.month_end THEN b.open_amount ELSE 0 END) AS ar_past_due
FROM bal b
JOIN dbo.customers c ON c.customer_id = b.customer_id
WHERE b.open_amount > 1
GROUP BY b.month_end, c.segment;
GO

/* ==========================================================================
   4. DSO / BPDSO / CEI BY MONTH
   DSO   = (AR / credit sales) * days      [3-month rolling sales basis]
   BPDSO = (current AR / credit sales) * days   - the floor DSO could reach
           if every past-due dollar were collected. The gap between DSO and
           BPDSO is the collectible opportunity.
   CEI   = how much of what was collectible actually got collected.
   ========================================================================== */
IF OBJECT_ID('dbo.vw_dso_monthly','V') IS NOT NULL DROP VIEW dbo.vw_dso_monthly;
GO
CREATE VIEW dbo.vw_dso_monthly AS
WITH sales AS (
    SELECT EOMONTH(invoice_date) AS month_end,
           SUM(invoice_amount)   AS credit_sales
    FROM dbo.invoices
    GROUP BY EOMONTH(invoice_date)
),
snap AS (
    SELECT month_end,
           SUM(ar_balance)  AS ar_balance,
           SUM(ar_current)  AS ar_current,
           SUM(ar_past_due) AS ar_past_due
    FROM dbo.vw_ar_snapshot_monthly
    GROUP BY month_end
),
j AS (
    SELECT s.month_end,
           s.ar_balance, s.ar_current, s.ar_past_due,
           sa.credit_sales,
           /* trailing 3-month sales smooths the quarter-end billing spike */
           SUM(sa.credit_sales) OVER (ORDER BY s.month_end
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)            AS sales_3m,
           COUNT(*) OVER (ORDER BY s.month_end
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)            AS months_3m,
           LAG(s.ar_balance) OVER (ORDER BY s.month_end)             AS ar_balance_prior
    FROM snap s
    JOIN sales sa ON sa.month_end = s.month_end
)
SELECT
    month_end,
    credit_sales,
    ar_balance,
    ar_current,
    ar_past_due,
    CAST(ar_balance / NULLIF(sales_3m,0) * (months_3m * 30.4) AS DECIMAL(10,1)) AS dso,
    CAST(ar_current / NULLIF(sales_3m,0) * (months_3m * 30.4) AS DECIMAL(10,1)) AS bpdso,
    CAST(ar_balance / NULLIF(sales_3m,0) * (months_3m * 30.4)
       - ar_current / NULLIF(sales_3m,0) * (months_3m * 30.4) AS DECIMAL(10,1)) AS dso_opportunity_days,
    CAST(100.0 * (ISNULL(ar_balance_prior,0) + credit_sales - ar_balance)
       / NULLIF(ISNULL(ar_balance_prior,0) + credit_sales - ar_current,0)
         AS DECIMAL(10,1))                                                      AS cei_pct,
    CAST(100.0 * ar_past_due / NULLIF(ar_balance,0) AS DECIMAL(10,1))           AS pct_past_due
FROM j;
GO

/* ==========================================================================
   5. CASH APPLICATION PERFORMANCE
   How much cash lands cleanly vs needs a human. Segmented by remittance
   quality, which is the real driver of automatability.
   This view is the business case for the Python auto-matcher project.
   ========================================================================== */
IF OBJECT_ID('dbo.vw_cash_application','V') IS NOT NULL DROP VIEW dbo.vw_cash_application;
GO
CREATE VIEW dbo.vw_cash_application AS
WITH p AS (
    SELECT p.payment_id, p.customer_id, c.segment, p.payment_date,
           p.payment_amount, p.payment_method, p.remittance_quality,
           p.unapplied_amount,
           COUNT(a.application_id) AS invoices_covered,
           ISNULL(SUM(a.applied_amount),0) AS applied_total
    FROM dbo.payments p
    JOIN dbo.customers c ON c.customer_id = p.customer_id
    LEFT JOIN dbo.payment_applications a ON a.payment_id = p.payment_id
    GROUP BY p.payment_id, p.customer_id, c.segment, p.payment_date,
             p.payment_amount, p.payment_method, p.remittance_quality,
             p.unapplied_amount
)
SELECT
    payment_id, customer_id, segment, payment_date, payment_amount,
    payment_method, remittance_quality, invoices_covered, applied_total,
    unapplied_amount,
    /* A single clean invoice is fully straight-through. A clean consolidated
       remittance can also be matched automatically, but it is kept separate
       from the single-invoice rate so the dashboard tells the fuller story. */
    CASE WHEN remittance_quality = 'CLEAN'
          AND invoices_covered = 1
          AND unapplied_amount = 0 THEN 'STRAIGHT_THROUGH'
         WHEN remittance_quality = 'CLEAN'
          AND invoices_covered > 1
          AND unapplied_amount = 0 THEN 'AUTO_MATCH_BATCH'
         WHEN remittance_quality = 'PARTIAL'
          AND unapplied_amount = 0 THEN 'ASSISTED_REVIEW'
         ELSE 'MANUAL_RESEARCH'
    END                                                          AS application_route,
    CASE WHEN remittance_quality = 'CLEAN'
          AND invoices_covered = 1
          AND unapplied_amount = 0 THEN 1 ELSE 0 END          AS straight_through,
    CASE WHEN remittance_quality = 'CLEAN'
          AND unapplied_amount = 0 THEN 1 ELSE 0 END          AS auto_matchable,
    CASE WHEN remittance_quality <> 'CLEAN'
           OR unapplied_amount > 0 THEN 1 ELSE 0 END          AS requires_human_review,
    CASE WHEN remittance_quality IN ('NONE','PO_ONLY')
           OR unapplied_amount > 0 THEN 1 ELSE 0 END          AS needs_manual_research,
    CASE WHEN invoices_covered > 1 THEN 1 ELSE 0 END          AS is_consolidated
FROM p;
GO

/* ==========================================================================
   6. CUSTOMER RISK SCORE
   Composite 0-100. Weighted so it reflects how a collections manager
   actually triages: recent behaviour and past-due concentration matter more
   than a single stale metric.
     35%  past-due exposure ratio
     25%  payment delay trend (recent vs historical)
     20%  aged concentration (61+ days)
     10%  dispute frequency
     10%  credit utilisation
   ========================================================================== */
IF OBJECT_ID('dbo.vw_customer_risk','V') IS NOT NULL DROP VIEW dbo.vw_customer_risk;
GO
CREATE VIEW dbo.vw_customer_risk AS
WITH risk_asof AS (
    SELECT DATEADD(MONTH,-4,MAX(invoice_date)) AS recent_start
    FROM dbo.invoices
),
pay_hist AS (
    SELECT customer_id,
           AVG(CAST(days_paid_late AS FLOAT))                          AS avg_days_late_all,
           AVG(CASE WHEN invoice_date >= x.recent_start
                    THEN CAST(days_paid_late AS FLOAT) END)            AS avg_days_late_recent,
           STDEV(CAST(days_paid_late AS FLOAT))                        AS stdev_days_late,
           COUNT(*)                                                    AS settled_invoices
    FROM dbo.vw_invoice_status
    CROSS JOIN risk_asof x
    WHERE is_settled = 1
    GROUP BY customer_id
),
exposure AS (
    SELECT customer_id,
           SUM(open_amount)                                            AS open_ar,
           SUM(CASE WHEN aging_sort >= 2 THEN open_amount ELSE 0 END)  AS past_due_ar,
           SUM(CASE WHEN aging_sort >= 4 THEN open_amount ELSE 0 END)  AS aged_61_plus,
           SUM(open_dispute_amount)                                    AS disputed_ar,
           MAX(days_past_due)                                          AS worst_dpd
    FROM dbo.vw_invoice_status
    WHERE is_settled = 0
    GROUP BY customer_id
),
disp AS (
    SELECT i.customer_id,
           COUNT(DISTINCT d.dispute_id) * 1.0
             / NULLIF(COUNT(DISTINCT i.invoice_id),0) AS dispute_rate
    FROM dbo.invoices i
    LEFT JOIN dbo.disputes d ON d.invoice_id = i.invoice_id
    GROUP BY i.customer_id
),
base AS (
    SELECT
        c.customer_id, c.customer_name, c.segment, c.region,
        c.assigned_analyst, c.credit_limit,
        ISNULL(e.open_ar,0)       AS open_ar,
        ISNULL(e.past_due_ar,0)   AS past_due_ar,
        ISNULL(e.aged_61_plus,0)  AS aged_61_plus,
        ISNULL(e.disputed_ar,0)   AS disputed_ar,
        ISNULL(e.worst_dpd,0)     AS worst_dpd,
        ISNULL(h.avg_days_late_all,0)    AS avg_days_late,
        ISNULL(h.avg_days_late_recent,0) AS avg_days_late_recent,
        ISNULL(h.avg_days_late_recent,0) - ISNULL(h.avg_days_late_all,0) AS delay_trend,
        ISNULL(d.dispute_rate,0)  AS dispute_rate,
        CASE WHEN c.credit_limit > 0
             THEN ISNULL(e.open_ar,0)/c.credit_limit ELSE 0 END AS credit_utilisation
    FROM dbo.customers c
    LEFT JOIN exposure e ON e.customer_id = c.customer_id
    LEFT JOIN pay_hist h ON h.customer_id = c.customer_id
    LEFT JOIN disp     d ON d.customer_id = c.customer_id
)
/* CROSS APPLY names the score expression for display and banding.
   Bands use the unrounded score: HIGH >= 38, MEDIUM >= 26, otherwise LOW.
   The reference book has 41 HIGH-risk customers out of 300 (13.7%).
   These heuristic thresholds are not a validated weekly team-capacity estimate
   or a probability of default. */
SELECT
    b.*,
    CAST(s.risk_score AS DECIMAL(5,1)) AS risk_score,
    CASE WHEN s.risk_score >= 38 THEN 'HIGH'
         WHEN s.risk_score >= 26 THEN 'MEDIUM'
         ELSE 'LOW' END               AS risk_band
FROM base b
CROSS APPLY (SELECT
      35.0 * CASE WHEN b.open_ar > 0
                  THEN CASE WHEN b.past_due_ar/b.open_ar > 1 THEN 1
                            ELSE b.past_due_ar/b.open_ar END ELSE 0 END
    + 25.0 * CASE WHEN b.delay_trend <= 0 THEN 0
                  WHEN b.delay_trend >= 45 THEN 1
                  ELSE b.delay_trend/45.0 END
    + 20.0 * CASE WHEN b.open_ar > 0
                  THEN CASE WHEN b.aged_61_plus/b.open_ar > 1 THEN 1
                            ELSE b.aged_61_plus/b.open_ar END ELSE 0 END
    + 10.0 * CASE WHEN b.dispute_rate >= 0.25 THEN 1 ELSE b.dispute_rate/0.25 END
    + 10.0 * CASE WHEN b.credit_utilisation >= 1 THEN 1 ELSE b.credit_utilisation END
    AS risk_score) s;
GO

/* ==========================================================================
   7. DISPUTE ANALYSIS
   ========================================================================== */
IF OBJECT_ID('dbo.vw_dispute_analysis','V') IS NOT NULL DROP VIEW dbo.vw_dispute_analysis;
GO
CREATE VIEW dbo.vw_dispute_analysis AS
SELECT
    d.dispute_id, d.invoice_id, d.customer_id, c.customer_name, c.segment,
    c.region, d.reason_code, d.dispute_date, d.resolved_date, d.status,
    d.amount_disputed,
    i.invoice_amount,
    CAST(100.0 * d.amount_disputed / NULLIF(i.invoice_amount,0) AS DECIMAL(10,1)) AS pct_of_invoice,
    DATEDIFF(DAY, d.dispute_date,
             ISNULL(d.resolved_date,(SELECT MAX(invoice_date) FROM dbo.invoices))) AS days_open,
    CASE WHEN d.status='OPEN' THEN d.amount_disputed ELSE 0 END AS blocked_amount
FROM dbo.disputes d
JOIN dbo.customers c ON c.customer_id = d.customer_id
JOIN dbo.invoices  i ON i.invoice_id  = d.invoice_id;
GO

/* ==========================================================================
   8. ANALYST PERFORMANCE
   Touches and a timing-based promise-to-pay kept proxy by analyst.
   ========================================================================== */
IF OBJECT_ID('dbo.vw_analyst_performance','V') IS NOT NULL DROP VIEW dbo.vw_analyst_performance;
GO
CREATE VIEW dbo.vw_analyst_performance AS
WITH asof AS (
    SELECT MAX(invoice_date) AS as_of_date
    FROM dbo.invoices
),
ptp AS (
    SELECT a.activity_id, a.analyst, a.invoice_id, a.promise_to_pay_date,
           CASE WHEN EXISTS (
                SELECT 1 FROM dbo.payment_applications pa
                WHERE pa.invoice_id = a.invoice_id
                  /* Do not credit a promise with cash that landed before the
                     collection activity that obtained the promise. */
                  AND pa.applied_date >= a.activity_date
                  AND pa.applied_date <= DATEADD(DAY, 3, a.promise_to_pay_date))
                THEN 1 ELSE 0 END AS ptp_kept
    FROM dbo.collection_activity a
    CROSS JOIN asof x
    /* Do not score promises whose due date has not arrived in this data set. */
    WHERE a.outcome = 'PROMISE_TO_PAY'
      AND a.promise_to_pay_date IS NOT NULL
      AND a.promise_to_pay_date <= x.as_of_date
)
SELECT
    ca.analyst,
    COUNT(*)                                                          AS total_touches,
    SUM(CASE WHEN ca.activity_type='CALL'       THEN 1 ELSE 0 END)     AS calls,
    SUM(CASE WHEN ca.activity_type='EMAIL'      THEN 1 ELSE 0 END)     AS emails,
    SUM(CASE WHEN ca.activity_type='ESCALATION' THEN 1 ELSE 0 END)     AS escalations,
    COUNT(DISTINCT ca.customer_id)                                    AS customers_worked,
    COUNT(DISTINCT ca.invoice_id)                                     AS invoices_worked,
    SUM(CASE WHEN ca.outcome='PROMISE_TO_PAY' THEN 1 ELSE 0 END)      AS promises_obtained,
    CAST(100.0 * ISNULL((SELECT AVG(CAST(ptp_kept AS FLOAT)) FROM ptp
                         WHERE ptp.analyst = ca.analyst),0) AS DECIMAL(10,1)) AS ptp_kept_pct,
    CAST(100.0 * SUM(CASE WHEN ca.outcome IN ('PAYMENT_CONFIRMED','PROMISE_TO_PAY')
                          THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0)
         AS DECIMAL(10,1))                                            AS productive_touch_pct
FROM dbo.collection_activity ca
GROUP BY ca.analyst;
GO

/* ==========================================================================
   9. EXECUTIVE KPI - single row for report headline cards
   ========================================================================== */
IF OBJECT_ID('dbo.vw_exec_kpi','V') IS NOT NULL DROP VIEW dbo.vw_exec_kpi;
GO
CREATE VIEW dbo.vw_exec_kpi AS
SELECT
    (SELECT SUM(open_amount) FROM dbo.vw_invoice_status WHERE is_settled=0)      AS total_ar,
    (SELECT SUM(open_amount) FROM dbo.vw_invoice_status
      WHERE is_settled=0 AND aging_sort>=2)                                     AS past_due_ar,
    (SELECT SUM(open_amount) FROM dbo.vw_invoice_status
      WHERE is_settled=0 AND aging_sort>=5)                                     AS ar_90_plus,
    (SELECT COUNT(*) FROM dbo.vw_customer_risk WHERE risk_band='HIGH')           AS high_risk_customers,
    (SELECT SUM(blocked_amount) FROM dbo.vw_dispute_analysis)                    AS disputed_blocked,
    (SELECT TOP 1 dso   FROM dbo.vw_dso_monthly ORDER BY month_end DESC)         AS current_dso,
    (SELECT TOP 1 bpdso FROM dbo.vw_dso_monthly ORDER BY month_end DESC)         AS current_bpdso,
    (SELECT TOP 1 cei_pct FROM dbo.vw_dso_monthly ORDER BY month_end DESC)       AS current_cei,
    (SELECT CAST(100.0*AVG(CAST(straight_through AS FLOAT)) AS DECIMAL(10,1))
       FROM dbo.vw_cash_application)                                            AS straight_through_pct,
    (SELECT MAX(invoice_date) FROM dbo.invoices)                                AS as_of_date;
GO

PRINT 'VISTA_AR analytical views created.';
