-- ==============================================================================
-- FRAUD MONITOR: PostgreSQL Star Schema, EDA and Reporting Views
-- Source table : paysim (raw PaySim transactions)
-- Output       : star schema + exploratory queries + views for Power BI
-- ------------------------------------------------------------------------------
-- Contents
--   0. Source preview
--   1. Star schema (dimensions and fact table)
--   2. Data quality checks
--   3. Constraints and indexes
--   4. Exploratory data analysis (EDA)
--   5. Reporting views
-- ==============================================================================


-- ------------------------------------------------------------------------------
-- SECTION 0: SOURCE PREVIEW
-- ------------------------------------------------------------------------------

SELECT *
FROM paysim
LIMIT 10;


-- ------------------------------------------------------------------------------
-- SECTION 1: STAR SCHEMA
-- ------------------------------------------------------------------------------

-- 1.1 dim_transaction_types
-- Purpose: one row per transaction type (TRANSFER, CASH_OUT, ...).

-- Step 1: Create the table
CREATE TABLE dim_transaction_types (
    type_id   SERIAL PRIMARY KEY,
    type_name VARCHAR(20) UNIQUE NOT NULL
);

-- Step 2: Load the distinct transaction types
INSERT INTO dim_transaction_types (type_name)
SELECT DISTINCT type
FROM paysim
WHERE type IS NOT NULL;

-- Step 3: Preview the table
SELECT *
FROM dim_transaction_types;


-- 1.2 dim_customers
-- Purpose: one row per account (sender or receiver).
--          customer_type is the account prefix: 'C' = customer, 'M' = merchant.

-- Step 1: Create the table
CREATE TABLE dim_customers (
    customer_id    SERIAL PRIMARY KEY,
    account_number VARCHAR(50) UNIQUE NOT NULL,
    customer_type  CHAR(1)  -- 'C' = customer, 'M' = merchant
);

-- Step 2: Load the distinct accounts from both the sender and receiver columns
INSERT INTO dim_customers (account_number, customer_type)
SELECT
    account_number,
    SUBSTRING(account_number FROM 1 FOR 1)
FROM (
    SELECT nameOrig AS account_number FROM paysim
    UNION
    SELECT nameDest AS account_number FROM paysim
) AS combined_accounts
ON CONFLICT (account_number) DO NOTHING;

-- Step 3: Preview the table
SELECT *
FROM dim_customers;


-- 1.3 fact_transactions
-- Purpose: one row per transaction, linked to the dimension tables by keys.

-- Step 1: Create the fact table
CREATE TABLE IF NOT EXISTS fact_transactions (
    transaction_id   SERIAL PRIMARY KEY,
    step             INT,
    type_id          INT REFERENCES dim_transaction_types (type_id),
    orig_customer_id INT REFERENCES dim_customers (customer_id),
    dest_customer_id INT REFERENCES dim_customers (customer_id),
    amount           NUMERIC(18, 2),
    oldbalance_org   NUMERIC(18, 2),
    newbalance_orig  NUMERIC(18, 2),
    oldbalance_dest  NUMERIC(18, 2),
    newbalance_dest  NUMERIC(18, 2),
    is_fraud         INT,
    is_flagged_fraud INT
);

-- Step 2: Load the transactions, joining to the dimensions to get the keys
INSERT INTO fact_transactions (
    step,
    type_id,
    orig_customer_id,
    dest_customer_id,
    amount,
    oldbalance_org,
    newbalance_orig,
    oldbalance_dest,
    newbalance_dest,
    is_fraud,
    is_flagged_fraud
)
SELECT
    r.step,
    t.type_id,
    c_orig.customer_id,
    c_dest.customer_id,
    r.amount,
    r.oldbalanceOrg,
    r.newbalanceOrig,
    r.oldbalanceDest,
    r.newbalanceDest,
    r.isFraud,
    r.isFlaggedFraud
FROM paysim r
LEFT JOIN dim_transaction_types t ON r.type     = t.type_name
LEFT JOIN dim_customers c_orig    ON r.nameOrig = c_orig.account_number
LEFT JOIN dim_customers c_dest    ON r.nameDest = c_dest.account_number;

-- Step 3: Preview the table
SELECT *
FROM fact_transactions;


-- 1.4 dim_time
-- Purpose: converts the raw "step" (1 step = 1 hour) into day, hour and time of day.

-- Step 1: Create the table
CREATE TABLE dim_time AS
SELECT DISTINCT
    step,
    (step - 1) / 24 + 1 AS day_number,
    (step - 1) % 24     AS hour_of_day,
    CASE
        WHEN (step - 1) % 24 BETWEEN 0  AND 5  THEN 'Night'
        WHEN (step - 1) % 24 BETWEEN 6  AND 11 THEN 'Morning'
        WHEN (step - 1) % 24 BETWEEN 12 AND 17 THEN 'Afternoon'
        ELSE 'Evening'
    END                 AS time_of_day
FROM paysim;

-- Step 2: Set the primary key
ALTER TABLE dim_time
ADD PRIMARY KEY (step);

-- Step 3: Preview the table
SELECT *
FROM dim_time;


-- ------------------------------------------------------------------------------
-- SECTION 2: DATA QUALITY CHECKS
-- ------------------------------------------------------------------------------

-- 2.1 Rows that failed to match a dimension
-- Expected result: 0
SELECT COUNT(*) AS bad_rows
FROM fact_transactions
WHERE type_id          IS NULL
   OR orig_customer_id IS NULL
   OR dest_customer_id IS NULL;

-- 2.2 Row count: source table vs fact table
-- Expected result: src_rows = fact_rows
SELECT
    (SELECT COUNT(*) FROM paysim)            AS src_rows,
    (SELECT COUNT(*) FROM fact_transactions) AS fact_rows;


-- ------------------------------------------------------------------------------
-- SECTION 3: CONSTRAINTS AND INDEXES
-- ------------------------------------------------------------------------------

-- 3.1 Link the fact table to dim_time
ALTER TABLE fact_transactions
ADD CONSTRAINT fk_fact_time
FOREIGN KEY (step) REFERENCES dim_time (step);

-- 3.2 Indexes to speed up joins and fraud filters
CREATE INDEX idx_fact_type  ON fact_transactions (type_id);
CREATE INDEX idx_fact_orig  ON fact_transactions (orig_customer_id);
CREATE INDEX idx_fact_dest  ON fact_transactions (dest_customer_id);
CREATE INDEX idx_fact_step  ON fact_transactions (step);
CREATE INDEX idx_fact_fraud ON fact_transactions (is_fraud);


-- ------------------------------------------------------------------------------
-- SECTION 4: EXPLORATORY DATA ANALYSIS (EDA)
-- ------------------------------------------------------------------------------

-- 4.1 Overview: headline numbers
SELECT
    COUNT(*)                                            AS total_transactions,  -- Total number of transactions
    SUM(amount)                                         AS total_amount,        -- Total transaction value
    ROUND(AVG(amount), 2)                               AS avg_amount,          -- Average transaction value
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount) AS median_amount,       -- Median transaction value
    MAX(amount)                                         AS max_amount,          -- Largest transaction
    SUM(is_fraud)                                       AS fraud_count,         -- Number of fraud cases
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 4)          AS fraud_rate,          -- Fraud rate (%)
    SUM(is_flagged_fraud)                               AS flagged_count        -- Transactions flagged by the alert system
FROM fact_transactions;

-- 4.2 Accounts by type (customers vs merchants)
SELECT
    customer_type,
    COUNT(*) AS accounts
FROM dim_customers
GROUP BY customer_type;

-- 4.3 Volume and value by transaction type
SELECT
    tt.type_name,
    COUNT(*)                                           AS transactions_count,   -- Number of transactions
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_transactions,  -- Share of all transactions (%)
    ROUND(SUM(f.amount), 0)                            AS total_amount,         -- Total value
    ROUND(AVG(f.amount), 2)                            AS avg_amount            -- Average value
FROM fact_transactions f
JOIN dim_transaction_types tt ON f.type_id = tt.type_id
GROUP BY tt.type_name
ORDER BY transactions_count DESC;

-- 4.4 Fraud by transaction type
SELECT
    tt.type_name,
    COUNT(*)                                                         AS transactions_count,
    SUM(f.is_fraud)                                                  AS fraud_count,
    ROUND(100.0 * SUM(f.is_fraud) / COUNT(*), 4)                     AS fraud_pct,
    ROUND(SUM(CASE WHEN f.is_fraud = 1 THEN f.amount ELSE 0 END), 0) AS fraud_amount
FROM fact_transactions f
JOIN dim_transaction_types tt ON f.type_id = tt.type_id
GROUP BY tt.type_name
ORDER BY fraud_count DESC;

-- 4.5 Amounts: fraud vs normal transactions
SELECT
    is_fraud,
    COUNT(*)                                            AS n,
    ROUND(AVG(amount), 2)                               AS avg_amount,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount) AS median_amount,
    MAX(amount)                                         AS max_amount
FROM fact_transactions
GROUP BY is_fraud;

-- 4.6 Fraud by hour of day
SELECT
    t.hour_of_day,
    COUNT(*)                                     AS transactions_count,
    SUM(f.is_fraud)                              AS fraud_count,
    ROUND(100.0 * SUM(f.is_fraud) / COUNT(*), 3) AS fraud_pct
FROM fact_transactions f
JOIN dim_time t ON f.step = t.step
GROUP BY t.hour_of_day
ORDER BY t.hour_of_day;

-- 4.7 Alert system effectiveness (confusion matrix on is_flagged_fraud)
SELECT
    is_fraud,
    is_flagged_fraud,
    COUNT(*) AS n
FROM fact_transactions
GROUP BY is_fraud, is_flagged_fraud
ORDER BY is_fraud, is_flagged_fraud;

-- 4.8 Sender balance mismatch: old balance - amount <> new balance
SELECT
    is_fraud,
    COUNT(*) AS n,
    SUM(CASE WHEN ROUND(oldbalance_org - amount, 2) <> newbalance_orig THEN 1 ELSE 0 END) AS orig_mismatch
FROM fact_transactions
GROUP BY is_fraud;

-- 4.9 Emptied sender accounts: the whole balance was moved out
SELECT
    is_fraud,
    COUNT(*) AS n
FROM fact_transactions
WHERE amount = oldbalance_org
  AND newbalance_orig = 0
  AND oldbalance_org > 0
GROUP BY is_fraud;

-- 4.10 Sender balance mismatch by transaction type
SELECT
    tt.type_name,
    f.is_fraud,
    COUNT(*) AS count_transaction,
    SUM(CASE WHEN ROUND(f.oldbalance_org - f.amount, 2) <> f.newbalance_orig THEN 1 ELSE 0 END) AS orig_mismatch
FROM fact_transactions f
JOIN dim_transaction_types tt ON f.type_id = tt.type_id
WHERE tt.type_name IN ('TRANSFER', 'CASH_OUT', 'PAYMENT', 'DEBIT')
GROUP BY tt.type_name, f.is_fraud
ORDER BY tt.type_name, f.is_fraud;

-- 4.11 Receiver balance mismatch: old balance + amount <> new balance (customer accounts only)
SELECT
    f.is_fraud,
    COUNT(*) AS n,
    SUM(CASE WHEN ROUND(f.oldbalance_dest + f.amount, 2) <> f.newbalance_dest THEN 1 ELSE 0 END) AS dest_mismatch
FROM fact_transactions f
JOIN dim_customers cd ON f.dest_customer_id = cd.customer_id
WHERE cd.customer_type = 'C'
GROUP BY f.is_fraud;

-- 4.12 Receiver with a zero balance before the transaction (customer accounts only)
SELECT
    f.is_fraud,
    COUNT(*) AS n,
    SUM(CASE WHEN f.oldbalance_dest = 0 THEN 1 ELSE 0 END) AS dest_zero_balance,
    ROUND(100.0 * SUM(CASE WHEN f.oldbalance_dest = 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_dest_zero
FROM fact_transactions f
JOIN dim_customers cd ON f.dest_customer_id = cd.customer_id
WHERE cd.customer_type = 'C'
GROUP BY f.is_fraud;

-- 4.13 Amount-to-balance ratio (TRANSFER and CASH_OUT only)
SELECT
    is_fraud,
    ROUND(AVG(amount / oldbalance_org), 4)                          AS avg_ratio,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount / oldbalance_org) AS median_ratio
FROM fact_transactions
WHERE oldbalance_org > 0
  AND type_id IN (
      SELECT type_id
      FROM dim_transaction_types
      WHERE type_name IN ('TRANSFER', 'CASH_OUT')
  )
GROUP BY is_fraud;

-- 4.14 Daily fraud trend
SELECT
    t.day_number,
    COUNT(*)                                     AS transactions_count,
    SUM(f.is_fraud)                              AS fraud_count,
    ROUND(100.0 * SUM(f.is_fraud) / COUNT(*), 4) AS fraud_pct
FROM fact_transactions f
JOIN dim_time t ON f.step = t.step
GROUP BY t.day_number
ORDER BY t.day_number;

-- 4.15 Repeat fraud senders (accounts with more than one fraud transaction)
SELECT
    c.account_number,
    COUNT(*)      AS fraud_txns,
    SUM(f.amount) AS fraud_amount
FROM fact_transactions f
JOIN dim_customers c ON f.orig_customer_id = c.customer_id
WHERE f.is_fraud = 1
GROUP BY c.account_number
HAVING COUNT(*) > 1
ORDER BY fraud_txns DESC
LIMIT 20;

-- 4.16 Repeat fraud receivers (possible mule accounts)
SELECT
    c.account_number,
    COUNT(*)      AS fraud_txns_received,
    SUM(f.amount) AS fraud_amount_received
FROM fact_transactions f
JOIN dim_customers c ON f.dest_customer_id = c.customer_id
WHERE f.is_fraud = 1
GROUP BY c.account_number
HAVING COUNT(*) > 1
ORDER BY fraud_txns_received DESC
LIMIT 20;

-- 4.17 Fraud chain pattern: a fraudulent TRANSFER followed by a fraudulent CASH_OUT
SELECT COUNT(*) AS chain_pairs
FROM fact_transactions t1
JOIN fact_transactions t2
  ON  t1.dest_customer_id = t2.orig_customer_id
  AND t2.step >= t1.step
JOIN dim_transaction_types tt1 ON t1.type_id = tt1.type_id AND tt1.type_name = 'TRANSFER'
JOIN dim_transaction_types tt2 ON t2.type_id = tt2.type_id AND tt2.type_name = 'CASH_OUT'
WHERE t1.is_fraud = 1
  AND t2.is_fraud = 1;

-- 4.18 Time gap (in hours) between consecutive transactions of the same fraud sender
WITH fraud_ids AS (
    SELECT DISTINCT orig_customer_id
    FROM fact_transactions
    WHERE is_fraud = 1
)
SELECT
    ROUND(AVG(gap_hours), 2)                               AS avg_gap_hours,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap_hours) AS median_gap_hours
FROM (
    SELECT
        f.orig_customer_id,
        f.step - LAG(f.step) OVER (PARTITION BY f.orig_customer_id ORDER BY f.step) AS gap_hours
    FROM fact_transactions f
    JOIN fraud_ids x ON f.orig_customer_id = x.orig_customer_id
) g
WHERE gap_hours IS NOT NULL;


-- ------------------------------------------------------------------------------
-- SECTION 5: REPORTING VIEWS (feed the Power BI dashboard)
-- ------------------------------------------------------------------------------

-- 5.1 vw_kpi_overview: headline KPIs (Overview and Detection pages)
CREATE OR REPLACE VIEW vw_kpi_overview AS
SELECT
    COUNT(*)                                                               AS total_transactions,
    SUM(amount)                                                            AS total_amount,
    ROUND(AVG(amount), 2)                                                  AS avg_amount,
    SUM(is_fraud)                                                          AS fraud_count,
    SUM(CASE WHEN is_fraud = 1 THEN amount ELSE 0 END)                     AS fraud_amount,
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 4)                             AS fraud_rate_pct,
    SUM(is_flagged_fraud)                                                  AS flagged_count,
    SUM(CASE WHEN is_fraud = 1 AND is_flagged_fraud = 1 THEN 1 ELSE 0 END) AS fraud_detected_by_system,
    ROUND(100.0 * SUM(CASE WHEN is_fraud = 1 AND is_flagged_fraud = 1 THEN 1 ELSE 0 END)
          / NULLIF(SUM(is_fraud), 0), 2)                                   AS detection_rate_pct
FROM fact_transactions;

-- 5.2 vw_fraud_by_type_time: fraud by day, hour and transaction type
CREATE OR REPLACE VIEW vw_fraud_by_type_time AS
SELECT
    t.day_number,
    t.hour_of_day,
    t.time_of_day,
    tt.type_name,
    COUNT(*)                                               AS transactions_count,
    SUM(f.is_fraud)                                        AS fraud_count,
    SUM(f.amount)                                          AS total_amount,
    SUM(CASE WHEN f.is_fraud = 1 THEN f.amount ELSE 0 END) AS fraud_amount
FROM fact_transactions f
JOIN dim_time t               ON f.step    = t.step
JOIN dim_transaction_types tt ON f.type_id = tt.type_id
GROUP BY t.day_number, t.hour_of_day, t.time_of_day, tt.type_name;

-- 5.3 vw_amount_buckets: amount distribution by size bucket (Amounts page)
CREATE OR REPLACE VIEW vw_amount_buckets AS
SELECT
    CASE
        WHEN amount < 1000    THEN '1) < 1K'
        WHEN amount < 10000   THEN '2) 1K - 10K'
        WHEN amount < 100000  THEN '3) 10K - 100K'
        WHEN amount < 1000000 THEN '4) 100K - 1M'
        ELSE                       '5) > 1M'
    END                                                   AS amount_bucket,
    CASE WHEN is_fraud = 1 THEN 'Fraud' ELSE 'Normal' END AS fraud_label,
    COUNT(*)                                              AS transactions_count,
    SUM(amount)                                           AS total_amount
FROM fact_transactions
GROUP BY 1, 2;

-- 5.4 vw_detection_matrix: actual fraud vs alert system result (Detection page)
CREATE OR REPLACE VIEW vw_detection_matrix AS
SELECT
    CASE WHEN is_fraud = 1 THEN 'Actual Fraud' ELSE 'Actual Normal' END     AS actual_label,
    CASE WHEN is_flagged_fraud = 1 THEN 'Flagged' ELSE 'Not Flagged' END    AS system_label,
    COUNT(*)                                                                AS transactions_count
FROM fact_transactions
GROUP BY is_fraud, is_flagged_fraud;

-- Preview
SELECT *
FROM vw_detection_matrix;

-- 5.5 vw_detection_by_type: fraud vs detected fraud per transaction type
CREATE OR REPLACE VIEW vw_detection_by_type AS
SELECT
    tt.type_name,
    COUNT(*)                                                                   AS transactions_count,
    SUM(f.is_fraud)                                                            AS fraud_count,
    SUM(f.is_flagged_fraud)                                                    AS flagged_count,
    SUM(CASE WHEN f.is_fraud = 1 AND f.is_flagged_fraud = 1 THEN 1 ELSE 0 END) AS detected_count
FROM fact_transactions f
JOIN dim_transaction_types tt ON f.type_id = tt.type_id
GROUP BY tt.type_name;

-- 5.6 vw_fraud_signals: fraud signals for TRANSFER and CASH_OUT (Risk page)
CREATE OR REPLACE VIEW vw_fraud_signals AS
SELECT
    tt.type_name,
    CASE WHEN f.newbalance_orig = 0 AND f.oldbalance_org > 0 THEN 'Yes' ELSE 'No' END             AS emptied_account,
    CASE WHEN f.oldbalance_dest = 0 THEN 'Yes' ELSE 'No' END                                      AS dest_zero_balance,
    CASE WHEN ROUND(f.oldbalance_org - f.amount, 2) <> f.newbalance_orig THEN 'Yes' ELSE 'No' END AS orig_balance_mismatch,
    COUNT(*)        AS transactions_count,
    SUM(f.is_fraud) AS fraud_count
FROM fact_transactions f
JOIN dim_transaction_types tt ON f.type_id = tt.type_id
WHERE tt.type_name IN ('TRANSFER', 'CASH_OUT')
GROUP BY tt.type_name, 2, 3, 4;

-- Preview
SELECT *
FROM vw_fraud_signals;

-- 5.7 vw_risky_accounts: accounts that sent fraud transactions
CREATE OR REPLACE VIEW vw_risky_accounts AS
SELECT
    c.account_number,
    c.customer_type,
    COUNT(*)      AS fraud_txns,
    SUM(f.amount) AS fraud_amount,
    MIN(f.step)   AS first_fraud_step,
    MAX(f.step)   AS last_fraud_step
FROM fact_transactions f
JOIN dim_customers c ON f.orig_customer_id = c.customer_id
WHERE f.is_fraud = 1
GROUP BY c.account_number, c.customer_type;

-- Preview
SELECT *
FROM vw_risky_accounts;

-- 5.8 vw_risky_receivers: accounts that received fraud transactions
CREATE OR REPLACE VIEW vw_risky_receivers AS
SELECT
    c.account_number,
    c.customer_type,
    COUNT(*)      AS fraud_txns_received,
    SUM(f.amount) AS fraud_amount_received
FROM fact_transactions f
JOIN dim_customers c ON f.dest_customer_id = c.customer_id
WHERE f.is_fraud = 1
GROUP BY c.account_number, c.customer_type;

-- Preview
SELECT *
FROM vw_risky_receivers;

-- 5.9 vw_fraud_transactions: detailed list of fraud transactions
CREATE OR REPLACE VIEW vw_fraud_transactions AS
SELECT
    f.transaction_id,
    t.day_number,
    t.hour_of_day,
    tt.type_name,
    co.account_number AS orig_account,
    cd.account_number AS dest_account,
    f.amount,
    f.oldbalance_org,
    f.newbalance_orig,
    f.oldbalance_dest,
    f.newbalance_dest,
    ROUND(f.amount / NULLIF(f.oldbalance_org, 0), 4) AS amount_to_balance_ratio,
    f.is_flagged_fraud
FROM fact_transactions f
JOIN dim_time t               ON f.step             = t.step
JOIN dim_transaction_types tt ON f.type_id          = tt.type_id
JOIN dim_customers co         ON f.orig_customer_id = co.customer_id
JOIN dim_customers cd         ON f.dest_customer_id = cd.customer_id
WHERE f.is_fraud = 1;

-- Preview
SELECT *
FROM vw_fraud_transactions;
