/* ==========================================================================
   VISTA - AR Collections Analytics
   01_schema.sql : database, tables, keys, indexes
   Target: SQL Server 2017+
   ========================================================================== */

IF DB_ID('VISTA_AR') IS NULL
    CREATE DATABASE VISTA_AR;
GO
USE VISTA_AR;
GO

/* drop in FK-safe order ---------------------------------------------------*/
IF OBJECT_ID('dbo.collection_activity','U')   IS NOT NULL DROP TABLE dbo.collection_activity;
IF OBJECT_ID('dbo.disputes','U')              IS NOT NULL DROP TABLE dbo.disputes;
IF OBJECT_ID('dbo.payment_applications','U')  IS NOT NULL DROP TABLE dbo.payment_applications;
IF OBJECT_ID('dbo.payments','U')              IS NOT NULL DROP TABLE dbo.payments;
IF OBJECT_ID('dbo.invoices','U')              IS NOT NULL DROP TABLE dbo.invoices;
IF OBJECT_ID('dbo.customers','U')             IS NOT NULL DROP TABLE dbo.customers;
IF OBJECT_ID('dbo.dim_date','U')              IS NOT NULL DROP TABLE dbo.dim_date;
GO

/* -------------------------------------------------------------------------
   DATE DIMENSION
   A real date table (not an auto-generated one) so Power BI time
   intelligence has a clean, marked date table to work against.
   ------------------------------------------------------------------------- */
CREATE TABLE dbo.dim_date (
    date_key        DATE         NOT NULL PRIMARY KEY,
    [year]          SMALLINT     NOT NULL,
    [quarter]       TINYINT      NOT NULL,
    month_num       TINYINT      NOT NULL,
    month_name      CHAR(3)      NOT NULL,
    year_month      CHAR(7)      NOT NULL,
    day_of_month    TINYINT      NOT NULL,
    day_name        CHAR(3)      NOT NULL,
    is_weekend      BIT          NOT NULL,
    is_month_end    BIT          NOT NULL,
    is_quarter_end  BIT          NOT NULL
);
GO

/* -------------------------------------------------------------------------
   CUSTOMERS
   segment drives virtually all payment behaviour in this book:
     MANAGED_CARE - vision payers, slow, adjudication write-downs
     RETAIL       - optical chains, high volume, chronic deductions
     KEY_ACCOUNT  - national accounts, few invoices, concentration risk
   ------------------------------------------------------------------------- */
CREATE TABLE dbo.customers (
    customer_id        CHAR(6)        NOT NULL PRIMARY KEY,
    customer_name      NVARCHAR(120)  NOT NULL,
    segment            VARCHAR(20)    NOT NULL,
    region             VARCHAR(20)    NOT NULL,
    payment_terms_days SMALLINT       NOT NULL,
    credit_limit       DECIMAL(18,2)  NOT NULL,
    onboard_date       DATE           NOT NULL,
    assigned_analyst   NVARCHAR(60)   NOT NULL,
    CONSTRAINT ck_customers_segment
        CHECK (segment IN ('MANAGED_CARE','RETAIL','KEY_ACCOUNT')),
    CONSTRAINT ck_customers_terms CHECK (payment_terms_days > 0)
);
GO

CREATE TABLE dbo.invoices (
    invoice_id      VARCHAR(15)   NOT NULL PRIMARY KEY,
    customer_id     CHAR(6)       NOT NULL,
    invoice_date    DATE          NOT NULL,
    due_date        DATE          NOT NULL,
    invoice_amount  DECIMAL(18,2) NOT NULL,
    po_number       VARCHAR(20)   NULL,
    currency        CHAR(3)       NOT NULL DEFAULT 'USD',
    CONSTRAINT fk_inv_cust FOREIGN KEY (customer_id)
        REFERENCES dbo.customers(customer_id),
    CONSTRAINT ck_inv_amount CHECK (invoice_amount > 0),
    CONSTRAINT ck_inv_dates  CHECK (due_date >= invoice_date)
);
GO

CREATE TABLE dbo.payments (
    payment_id           VARCHAR(15)    NOT NULL PRIMARY KEY,
    customer_id          CHAR(6)        NOT NULL,
    payment_date         DATE           NOT NULL,
    payment_amount       DECIMAL(18,2)  NOT NULL,
    payment_method       VARCHAR(15)    NOT NULL,
    remittance_reference NVARCHAR(200)  NULL,
    /* how usable the remittance advice is - the single biggest driver of
       whether cash application can be automated. CLEAN / PARTIAL /
       PO_ONLY / NONE */
    remittance_quality   VARCHAR(10)    NOT NULL,
    unapplied_amount     DECIMAL(18,2)  NOT NULL DEFAULT 0,
    CONSTRAINT fk_pay_cust FOREIGN KEY (customer_id)
        REFERENCES dbo.customers(customer_id)
);
GO

CREATE TABLE dbo.payment_applications (
    application_id VARCHAR(15)   NOT NULL PRIMARY KEY,
    payment_id     VARCHAR(15)   NOT NULL,
    invoice_id     VARCHAR(15)   NOT NULL,
    applied_amount DECIMAL(18,2) NOT NULL,
    applied_date   DATE          NOT NULL,
    CONSTRAINT fk_app_pay FOREIGN KEY (payment_id) REFERENCES dbo.payments(payment_id),
    CONSTRAINT fk_app_inv FOREIGN KEY (invoice_id) REFERENCES dbo.invoices(invoice_id)
);
GO

CREATE TABLE dbo.disputes (
    dispute_id      VARCHAR(15)   NOT NULL PRIMARY KEY,
    invoice_id      VARCHAR(15)   NOT NULL,
    customer_id     CHAR(6)       NOT NULL,
    dispute_date    DATE          NOT NULL,
    reason_code     VARCHAR(30)   NOT NULL,
    amount_disputed DECIMAL(18,2) NOT NULL,
    resolved_date   DATE          NULL,
    status          VARCHAR(10)   NOT NULL,
    CONSTRAINT fk_dsp_inv  FOREIGN KEY (invoice_id)  REFERENCES dbo.invoices(invoice_id),
    CONSTRAINT fk_dsp_cust FOREIGN KEY (customer_id) REFERENCES dbo.customers(customer_id),
    CONSTRAINT ck_dsp_status CHECK (status IN ('OPEN','RESOLVED'))
);
GO

CREATE TABLE dbo.collection_activity (
    activity_id         VARCHAR(15)  NOT NULL PRIMARY KEY,
    invoice_id          VARCHAR(15)  NOT NULL,
    customer_id         CHAR(6)      NOT NULL,
    activity_date       DATE         NOT NULL,
    activity_type       VARCHAR(15)  NOT NULL,
    analyst             NVARCHAR(60) NOT NULL,
    outcome             VARCHAR(20)  NOT NULL,
    promise_to_pay_date DATE         NULL,
    CONSTRAINT fk_act_inv  FOREIGN KEY (invoice_id)  REFERENCES dbo.invoices(invoice_id),
    CONSTRAINT fk_act_cust FOREIGN KEY (customer_id) REFERENCES dbo.customers(customer_id)
);
GO

/* -------------------------------------------------------------------------
   INDEXES
   Chosen for the actual query patterns in 03_views.sql: aging rolls up by
   customer and due_date; cash application joins hard on invoice_id.
   ------------------------------------------------------------------------- */
CREATE INDEX ix_inv_customer      ON dbo.invoices(customer_id) INCLUDE (invoice_amount, due_date);
CREATE INDEX ix_inv_due           ON dbo.invoices(due_date)    INCLUDE (customer_id, invoice_amount);
CREATE INDEX ix_inv_date          ON dbo.invoices(invoice_date) INCLUDE (customer_id, invoice_amount);
CREATE INDEX ix_app_invoice       ON dbo.payment_applications(invoice_id) INCLUDE (applied_amount, applied_date);
CREATE INDEX ix_app_payment       ON dbo.payment_applications(payment_id);
CREATE INDEX ix_pay_customer_date ON dbo.payments(customer_id, payment_date) INCLUDE (payment_amount);
CREATE INDEX ix_dsp_invoice       ON dbo.disputes(invoice_id)  INCLUDE (status, amount_disputed);
CREATE INDEX ix_dsp_status        ON dbo.disputes(status)      INCLUDE (customer_id, amount_disputed);
CREATE INDEX ix_act_invoice       ON dbo.collection_activity(invoice_id);
CREATE INDEX ix_act_analyst       ON dbo.collection_activity(analyst, activity_date);
GO

PRINT 'VISTA_AR schema created.';
