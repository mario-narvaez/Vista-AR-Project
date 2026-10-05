/* ==========================================================================
   VISTA - AR Collections Analytics
   02_load.sql : load the CSVs into VISTA_AR

   Loads through NVARCHAR staging tables rather than straight into the typed
   tables. That is deliberate: the CSVs contain empty strings for optional
   dates (resolved_date, promise_to_pay_date, po_number) and BULK INSERT will
   fail converting '' to DATE. Staging + TRY_CONVERT/NULLIF makes type
   conversion explicit: inspect the staging tables if a malformed required
   value causes the typed insert to fail.

   >>> SET THIS to the folder holding the CSVs, keep the trailing backslash.
   ========================================================================== */

USE VISTA_AR;
GO

/* ---------- staging -------------------------------------------------- */
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO

/* Edit this one value only. Keep the trailing backslash. */
DECLARE @DataPath NVARCHAR(400) = N'C:\VISTA\data\';   -- <<< EDIT ME
DECLARE @sql NVARCHAR(MAX);

IF OBJECT_ID('stg.dim_date','U')             IS NOT NULL DROP TABLE stg.dim_date;
IF OBJECT_ID('stg.customers','U')            IS NOT NULL DROP TABLE stg.customers;
IF OBJECT_ID('stg.invoices','U')             IS NOT NULL DROP TABLE stg.invoices;
IF OBJECT_ID('stg.payments','U')             IS NOT NULL DROP TABLE stg.payments;
IF OBJECT_ID('stg.payment_applications','U') IS NOT NULL DROP TABLE stg.payment_applications;
IF OBJECT_ID('stg.disputes','U')             IS NOT NULL DROP TABLE stg.disputes;
IF OBJECT_ID('stg.collection_activity','U')  IS NOT NULL DROP TABLE stg.collection_activity;

CREATE TABLE stg.dim_date (date_key NVARCHAR(50), [year] NVARCHAR(50), [quarter] NVARCHAR(50),
    month_num NVARCHAR(50), month_name NVARCHAR(50), year_month NVARCHAR(50),
    day_of_month NVARCHAR(50), day_name NVARCHAR(50), is_weekend NVARCHAR(50),
    is_month_end NVARCHAR(50), is_quarter_end NVARCHAR(50));

CREATE TABLE stg.customers (customer_id NVARCHAR(50), customer_name NVARCHAR(200),
    segment NVARCHAR(50), region NVARCHAR(50), payment_terms_days NVARCHAR(50),
    credit_limit NVARCHAR(50), onboard_date NVARCHAR(50), assigned_analyst NVARCHAR(100));

CREATE TABLE stg.invoices (invoice_id NVARCHAR(50), customer_id NVARCHAR(50),
    invoice_date NVARCHAR(50), due_date NVARCHAR(50), invoice_amount NVARCHAR(50),
    po_number NVARCHAR(50), currency NVARCHAR(10));

CREATE TABLE stg.payments (payment_id NVARCHAR(50), customer_id NVARCHAR(50),
    payment_date NVARCHAR(50), payment_amount NVARCHAR(50), payment_method NVARCHAR(50),
    remittance_reference NVARCHAR(400), remittance_quality NVARCHAR(50),
    unapplied_amount NVARCHAR(50));

CREATE TABLE stg.payment_applications (application_id NVARCHAR(50), payment_id NVARCHAR(50),
    invoice_id NVARCHAR(50), applied_amount NVARCHAR(50), applied_date NVARCHAR(50));

CREATE TABLE stg.disputes (dispute_id NVARCHAR(50), invoice_id NVARCHAR(50),
    customer_id NVARCHAR(50), dispute_date NVARCHAR(50), reason_code NVARCHAR(50),
    amount_disputed NVARCHAR(50), resolved_date NVARCHAR(50), status NVARCHAR(50));

CREATE TABLE stg.collection_activity (activity_id NVARCHAR(50), invoice_id NVARCHAR(50),
    customer_id NVARCHAR(50), activity_date NVARCHAR(50), activity_type NVARCHAR(50),
    analyst NVARCHAR(100), outcome NVARCHAR(50), promise_to_pay_date NVARCHAR(50));

/* ---------- bulk insert ------------------------------------------------ */
DECLARE @tbl NVARCHAR(100), @file NVARCHAR(100);
DECLARE c CURSOR FOR
    SELECT 'stg.dim_date','dim_date.csv' UNION ALL
    SELECT 'stg.customers','customers.csv' UNION ALL
    SELECT 'stg.invoices','invoices.csv' UNION ALL
    SELECT 'stg.payments','payments.csv' UNION ALL
    SELECT 'stg.payment_applications','payment_applications.csv' UNION ALL
    SELECT 'stg.disputes','disputes.csv' UNION ALL
    SELECT 'stg.collection_activity','collection_activity.csv';
OPEN c; FETCH NEXT FROM c INTO @tbl, @file;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'BULK INSERT ' + @tbl + N'
                 FROM ''' + @DataPath + @file + N'''
                 WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDTERMINATOR='','',
                       ROWTERMINATOR=''0x0a'', TABLOCK, CODEPAGE=''65001'');';
    PRINT 'loading ' + @file;
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @tbl, @file;
END
CLOSE c; DEALLOCATE c;
GO

/* ---------- typed insert (parent -> child) ----------------------------- */
USE VISTA_AR;
GO
DELETE FROM dbo.collection_activity;
DELETE FROM dbo.disputes;
DELETE FROM dbo.payment_applications;
DELETE FROM dbo.payments;
DELETE FROM dbo.invoices;
DELETE FROM dbo.customers;
DELETE FROM dbo.dim_date;
GO

INSERT INTO dbo.dim_date
SELECT TRY_CONVERT(DATE,date_key), TRY_CONVERT(SMALLINT,[year]), TRY_CONVERT(TINYINT,[quarter]),
       TRY_CONVERT(TINYINT,month_num), month_name, year_month, TRY_CONVERT(TINYINT,day_of_month),
       day_name, TRY_CONVERT(BIT,is_weekend), TRY_CONVERT(BIT,is_month_end),
       TRY_CONVERT(BIT,is_quarter_end)
FROM stg.dim_date;

INSERT INTO dbo.customers
SELECT customer_id, customer_name, segment, region,
       TRY_CONVERT(SMALLINT,payment_terms_days), TRY_CONVERT(DECIMAL(18,2),credit_limit),
       TRY_CONVERT(DATE,onboard_date), assigned_analyst
FROM stg.customers;

INSERT INTO dbo.invoices
SELECT invoice_id, customer_id, TRY_CONVERT(DATE,invoice_date), TRY_CONVERT(DATE,due_date),
       TRY_CONVERT(DECIMAL(18,2),invoice_amount), NULLIF(LTRIM(RTRIM(po_number)),''),
       ISNULL(NULLIF(currency,''),'USD')
FROM stg.invoices;

INSERT INTO dbo.payments
SELECT payment_id, customer_id, TRY_CONVERT(DATE,payment_date),
       TRY_CONVERT(DECIMAL(18,2),payment_amount), payment_method,
       NULLIF(LTRIM(RTRIM(remittance_reference)),''), remittance_quality,
       ISNULL(TRY_CONVERT(DECIMAL(18,2),unapplied_amount),0)
FROM stg.payments;

INSERT INTO dbo.payment_applications
SELECT application_id, payment_id, invoice_id,
       TRY_CONVERT(DECIMAL(18,2),applied_amount), TRY_CONVERT(DATE,applied_date)
FROM stg.payment_applications;

INSERT INTO dbo.disputes
SELECT dispute_id, invoice_id, customer_id, TRY_CONVERT(DATE,dispute_date), reason_code,
       TRY_CONVERT(DECIMAL(18,2),amount_disputed),
       TRY_CONVERT(DATE,NULLIF(LTRIM(RTRIM(resolved_date)),'')), status
FROM stg.disputes;

INSERT INTO dbo.collection_activity
SELECT activity_id, invoice_id, customer_id, TRY_CONVERT(DATE,activity_date), activity_type,
       analyst, outcome, TRY_CONVERT(DATE,NULLIF(LTRIM(RTRIM(promise_to_pay_date)),''))
FROM stg.collection_activity;
GO

/* ---------- validation -------------------------------------------------- */
SELECT 'customers' t, COUNT(*) rows FROM dbo.customers
UNION ALL SELECT 'invoices',             COUNT(*) FROM dbo.invoices
UNION ALL SELECT 'payments',             COUNT(*) FROM dbo.payments
UNION ALL SELECT 'payment_applications', COUNT(*) FROM dbo.payment_applications
UNION ALL SELECT 'disputes',             COUNT(*) FROM dbo.disputes
UNION ALL SELECT 'collection_activity',  COUNT(*) FROM dbo.collection_activity
UNION ALL SELECT 'dim_date',             COUNT(*) FROM dbo.dim_date;

/* over-application check: applied cash should never exceed the invoice by
   more than the modelled overpayment tolerance */
SELECT TOP 10 i.invoice_id, i.invoice_amount,
       SUM(a.applied_amount) AS applied
FROM dbo.invoices i
JOIN dbo.payment_applications a ON a.invoice_id = i.invoice_id
GROUP BY i.invoice_id, i.invoice_amount
HAVING SUM(a.applied_amount) > i.invoice_amount * 1.10
ORDER BY SUM(a.applied_amount) - i.invoice_amount DESC;

PRINT 'VISTA_AR load complete.';
