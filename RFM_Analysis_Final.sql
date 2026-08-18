-- RFM CUSTOMER SEGMENTATION ANALYSIS
-- Dataset: UCI E-Commerce Dataset (Kaggle)
-- Period:  December 2010 - December 2011
-- Tool:    MySQL 8.0
-- Author:  Marina Kovacevic

-- Architecture: Bronze → Silver → Gold → BI → Strategic Layer


		-- SECTION 1: DATABASE SETUP & DATA INGESTION
        
CREATE DATABASE IF NOT EXISTS rfm_analysis;
USE rfm_analysis;

-- Table Definition 
-- NOTE: Uncomment only on fresh database setup (first run only)
-- After first run, table already exists — leave commented out

/*
CREATE TABLE transactions (
    id_transactions INT NOT NULL AUTO_INCREMENT,
    InvoiceNo VARCHAR(45) NULL,
    StockCode VARCHAR(45) NULL,
    Description VARCHAR(255) NULL,
    Quantity INT NULL,
    InvoiceDate VARCHAR(50) NULL,
    UnitPrice DECIMAL(10,2) NULL,
    CustomerID INT NULL,
    Country VARCHAR(100) NULL,
    PRIMARY KEY (id_transactions)
);
*/


/*
-- DATA IMPORT NOTE:
-- Dataset: UCI E-Commerce Dataset (Kaggle) — 541,909 rows
-- Download: https://www.kaggle.com/datasets/carrie1/ecommerce-data

-- Import method: LOAD DATA INFILE (fastest for large datasets)
-- NOTE: Uncomment only on fresh database import (first run only)
--
-- OPTION 1 (Recommended): Custom folder — requires secure_file_priv="" in my.ini
-- Steps:
--   1. Open my.ini as Administrator (C:\ProgramData\MySQL\MySQL Server 8.0\my.ini)
--   2. Find secure_file_priv and set it to: secure_file_priv=""
--   3. Restart MySQL service (run as Admin: net stop MySQL80 && net start MySQL80)
--   4. Place data.csv in any folder, e.g. C:/MySQLData/
--   5. Uncomment and run the query below

LOAD DATA INFILE 'C:/MySQLData/data.csv'
INTO TABLE transactions
CHARACTER SET latin1
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(InvoiceNo, StockCode, Description, Quantity, InvoiceDate, 
@UnitPrice, @CustomerID, Country)
SET 
    UnitPrice = NULLIF(@UnitPrice, ''),
    CustomerID = NULLIF(@CustomerID, '');
*/
-- OPTION 2: Default MySQL Uploads folder — no my.ini changes required
-- Steps:
--   1. Copy data.csv to: C:\ProgramData\MySQL\MySQL Server 8.0\Uploads\
--      Note: ProgramData is a hidden folder — enable hidden items in File Explorer
--   2. Uncomment and run the query below
/*
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/data.csv'
INTO TABLE transactions
CHARACTER SET latin1
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(InvoiceNo, StockCode, Description, Quantity, InvoiceDate,
@UnitPrice, @CustomerID, Country)
SET
    UnitPrice  = NULLIF(@UnitPrice, ''),
    CustomerID = NULLIF(@CustomerID, '');
*/


-- Validation
SELECT COUNT(*) AS total_rows_imported FROM transactions;
-- Note: Data imported using LOAD DATA INFILE
-- Source: UCI E-Commerce Dataset (Kaggle)
-- Total rows imported: 541,909


-- ============================================================
-- SECTION 2: DATA PREPARATION & CLEANING (Bronze Layer)
-- Purpose: Converts raw VARCHAR fields to proper data types
--          and removes formatting artifacts from source data
-- ============================================================

SET SQL_SAFE_UPDATES = 0;

-- 2.0 Add clean datetime column
-- Original InvoiceDate was stored as VARCHAR — needs DATETIME conversion
-- NOTE: Uncomment ALTER TABLE only on fresh database import (first run only)
-- After first run, column already exists — leave commented out
-- ALTER TABLE transactions ADD COLUMN InvoiceDate_clean DATETIME NULL;

-- 2.1 Convert VARCHAR date to DATETIME
-- Skips NULL and empty InvoiceDate values
UPDATE transactions 
SET InvoiceDate_clean = STR_TO_DATE(InvoiceDate, '%m/%d/%Y %H:%i')
WHERE InvoiceDate IS NOT NULL 
  AND InvoiceDate != '';

-- 2.2 Remove Windows line endings (\r) from Country column
-- Only updates rows where \r actually exists (performance optimization)
UPDATE transactions 
SET Country = TRIM(REPLACE(Country, '\r', ''))
WHERE Country LIKE '%\r%';

SET SQL_SAFE_UPDATES = 1;

-- Validation
SELECT 
    COUNT(*)                            AS total_rows,
    COUNT(InvoiceDate_clean)            AS clean_dates_populated,
    COUNT(*) - COUNT(InvoiceDate_clean) AS null_dates_remaining,
    COUNT(DISTINCT Country)             AS distinct_countries
FROM transactions;
-- Expected: clean_dates_populated close to 541,909
--           null_dates_remaining minimal
--           distinct_countries around 38

-- SECTION 3: FACT TRANSACTIONS (Silver Layer)
-- VIEW: fact_transactions
-- Layer: Silver (Clean Layer)
-- Purpose: Filters raw transactions to valid, analyzable records
-- Excludes: NULL customers, returns, zero-price test entries
-- Depends on: transactions

CREATE OR REPLACE VIEW fact_transactions AS
SELECT 
    InvoiceNo,
    StockCode,
    Description,
    Quantity,
    InvoiceDate_clean AS InvoiceDate,
    UnitPrice,
    CustomerID,
    Country,
    ROUND(Quantity * UnitPrice, 2) AS total_amount
FROM transactions
WHERE CustomerID IS NOT NULL
  AND Quantity > 0
  AND UnitPrice > 0
  AND InvoiceDate_clean IS NOT NULL;

-- Validation
-- Expected: ~397,880 rows | 0 NULL customers | 0 negative qty
SELECT COUNT(*) AS total_valid_rows FROM fact_transactions;

SELECT COUNT(*) AS null_customer_check 
FROM fact_transactions WHERE CustomerID IS NULL;
-- Expected: 0
SELECT
    MIN(InvoiceDate) AS first_transaction_date,
    MAX(InvoiceDate) AS last_transaction_date
FROM fact_transactions;
-- Expected: 2010-12-01 → 2011-12-09


-- SECTION 4: RFM BASE METRICS (Core Metrics)
-- VIEW: rfm_base
-- Layer: Core Metrics
-- Purpose: Calculates raw RFM values per customer
-- Reference date: Dynamic (MAX invoice date in dataset)
-- Depends on: fact_transactions

CREATE OR REPLACE VIEW rfm_base AS
WITH reference_context AS (
    SELECT MAX(InvoiceDate) AS max_invoice_date 
    FROM fact_transactions
),
customer_metrics AS (
    SELECT 
        CustomerID,
        MAX(InvoiceDate) AS last_purchase_date,
        DATEDIFF(
            (SELECT max_invoice_date FROM reference_context), 
            MAX(InvoiceDate)
        ) AS Recency,
        COUNT(DISTINCT InvoiceNo)  AS Frequency,
        ROUND(SUM(total_amount), 2) AS Monetary
    FROM fact_transactions
    GROUP BY CustomerID
)
SELECT * FROM customer_metrics;

-- Validation 
SELECT 
    COUNT(*)                        AS total_customers,
    MIN(Recency)                    AS min_recency,
    MAX(Recency)                    AS max_recency,
    ROUND(AVG(Monetary), 2)         AS avg_monetary,
    MIN(Monetary)                   AS min_monetary
FROM rfm_base;
-- Sanity check: min_recency should be 0, no negative values


-- SECTION 5: CUSTOM RFM SCORING (Business Rule Layer)
-- VIEW: rfm_scores
-- Layer: Business Rule Layer
-- Purpose: Applies fixed threshold scoring to RFM metrics
-- Scoring logic:
--   Recency  : lower days = higher score (4 = best)
--   Frequency: higher purchases = higher score (4 = best)
--   Monetary : higher spend = higher score (4 = best)
-- Note: Fixed thresholds ensure stable segmentation
--       independent of dataset distribution changes
-- Depends on: rfm_base

CREATE OR REPLACE VIEW rfm_scores AS 
SELECT 
    *,

    -- RECENCY SCORE (days since last purchase)
    CASE
        WHEN Recency <= 30  THEN 4  -- Active this month
        WHEN Recency <= 90  THEN 3  -- Active last quarter
        WHEN Recency <= 180 THEN 2  -- Active last 6 months
        ELSE 1                      -- Inactive 6+ months
    END AS r_score,

    -- FREQUENCY SCORE (unique transactions)
    CASE 
        WHEN Frequency >= 10 THEN 4  -- Power buyer
        WHEN Frequency >= 5  THEN 3  -- Regular buyer
        WHEN Frequency >= 2  THEN 2  -- Occasional buyer
        ELSE 1                       -- One-time buyer
    END AS f_score,

    -- MONETARY SCORE (total spend in £)
    CASE 
        WHEN Monetary >= 5000 THEN 4  -- Top spender
        WHEN Monetary >= 2000 THEN 3  -- High spender
        WHEN Monetary >= 500  THEN 2  -- Mid spender
        ELSE 1                        -- Low spender
    END AS m_score

FROM rfm_base;


-- Derived Composite Score
-- Added as separate view to keep scoring logic clean
-- VIEW: rfm_scores_with_composite
-- Purpose: Adds composite RFM score and score label
--          for dashboard KPIs and sorting
-- Weighting: R=30%, F=35%, M=35%
-- Depends on: rfm_scores

CREATE OR REPLACE VIEW rfm_scores_with_composite AS
SELECT
    *,

    -- Composite score: weighted average (R=30%, F=35%, M=35%)
    ROUND(
        (r_score * 0.30) + 
        (f_score * 0.35) + 
        (m_score * 0.35), 
    2) AS rfm_composite_score,

    -- Human-readable score label for dashboards
    CASE
        WHEN ROUND((r_score * 0.30) + (f_score * 0.35) + (m_score * 0.35), 2) >= 3.5 THEN 'Excellent'
        WHEN ROUND((r_score * 0.30) + (f_score * 0.35) + (m_score * 0.35), 2) >= 2.5 THEN 'Good'
        WHEN ROUND((r_score * 0.30) + (f_score * 0.35) + (m_score * 0.35), 2) >= 1.5 THEN 'Fair'
        ELSE 'Poor'
    END AS rfm_score_label

FROM rfm_scores;

-- Validation 
SELECT 
    rfm_score_label,
    COUNT(*)                        AS customer_count,
    ROUND(AVG(rfm_composite_score), 2) AS avg_composite,
    ROUND(AVG(Monetary), 2)         AS avg_monetary
FROM rfm_scores_with_composite
GROUP BY rfm_score_label
ORDER BY avg_composite DESC;



		-- SECTION 6: ACTIONABLE SEGMENTATION (Gold Layer)
-- VIEW: gold_customer_insights
-- Layer: Gold (Actionable Business Layer)
-- Purpose: Assigns segments, value tiers, risk profiles
--          and marketing actions to each customer
-- Segments designed to support retention & marketing strategy
-- Depends on: rfm_scores_with_composite

CREATE OR REPLACE VIEW gold_customer_insights AS
SELECT 
    CustomerID,
    last_purchase_date,
    Recency,
    Frequency,
    Monetary,
    r_score,
    f_score,
    m_score,
    rfm_composite_score,
    rfm_score_label,

    -- 1. Customer Segment 
    CASE 
        WHEN r_score = 4 AND f_score >= 3 AND m_score >= 3 THEN 'Champions'
        WHEN f_score >= 3 AND m_score >= 3                 THEN 'Loyal Customers'
        WHEN r_score = 4 AND f_score <= 2                  THEN 'New Customers'
        WHEN r_score >= 3 AND f_score = 2                  THEN 'Potential Loyalists'
        WHEN r_score <= 2 AND f_score >= 3                 THEN 'At Risk'
        WHEN r_score = 1 AND m_score >= 3                  THEN 'Lost High Value'
        WHEN r_score = 1                                   THEN 'Lost'
        ELSE 'Needs Attention'
    END AS segment,

    -- 2. Value Tier
    CASE 
        WHEN Monetary >= 5000 THEN 'High Value'
        WHEN Monetary >= 2000 THEN 'Mid Value'
        ELSE                       'Low Value'
    END AS value_tier,

    -- 3. Risk Profile
    CASE 
        WHEN r_score <= 2 THEN 'High Risk'
        WHEN r_score =  3 THEN 'Medium Risk'
        ELSE                   'Low Risk'
    END AS risk_group,

    --  4. Marketing Action
    CASE 
        WHEN r_score = 4 AND f_score >= 3 THEN 'Retain & Upsell'
        WHEN r_score = 4 AND f_score <  3 THEN 'Welcome & Nurture'
        WHEN r_score <= 2 AND f_score >= 3 THEN 'Re-engagement Campaign'
        WHEN r_score = 1                   THEN 'Win-back Offer'
        ELSE                                    'Monitor'
    END AS marketing_action,

    --  5. Churn Risk Score
    -- Combines recency and frequency into 1-10 churn risk scale
    -- Higher score = higher churn risk
    ROUND( ((5 - r_score) * 1.5) + ((5 - f_score) * 1.0),1) AS churn_risk_score
FROM rfm_scores_with_composite;

--  Validation 
-- 1. Segment distribution — no NULLs expected
SELECT 
    segment,
    COUNT(*)                           AS customer_count,
    ROUND(COUNT(*) * 100.0 
        / SUM(COUNT(*)) OVER(), 2)     AS pct_of_total,
    ROUND(AVG(rfm_composite_score), 2) AS avg_rfm_score,
    ROUND(AVG(churn_risk_score), 2)    AS avg_churn_risk,
    ROUND(SUM(Monetary), 2)            AS total_revenue
FROM gold_customer_insights
GROUP BY segment
ORDER BY total_revenue DESC;

-- 2. Null check
SELECT COUNT(*) AS null_segments
FROM gold_customer_insights
WHERE segment IS NULL;
-- Expected: 0



		-- SECTION 7: EXECUTIVE SUMMARIES (BI Layer)
-- VIEW: segment_summary
-- Layer: BI / Reporting Layer
-- Purpose: Aggregated segment-level metrics for dashboard
--          reporting and executive presentations
-- Depends on: gold_customer_insights

CREATE OR REPLACE VIEW segment_summary AS
SELECT
    segment,
    COUNT(*) AS customer_count,

    -- Revenue metrics
    ROUND(SUM(Monetary), 2) AS total_revenue,
    ROUND(AVG(Monetary), 2) AS avg_customer_value,
    ROUND(MIN(Monetary), 2) AS min_customer_value,
    ROUND(MAX(Monetary), 2) AS max_customer_value,

    -- Revenue share
    ROUND(
        SUM(Monetary) / SUM(SUM(Monetary)) OVER() * 100
    , 2) AS revenue_share_pct,

    -- Cumulative revenue share (for Pareto analysis)
    ROUND(
        SUM(SUM(Monetary)) OVER(
            ORDER BY SUM(Monetary) DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) / SUM(SUM(Monetary)) OVER() * 100
    , 2)  AS cumulative_revenue_pct,

    -- Behavior metrics
    ROUND(AVG(Recency), 0)                                      AS avg_recency_days,
    ROUND(AVG(Frequency), 1)                                    AS avg_frequency,
    ROUND(AVG(rfm_composite_score), 2)                          AS avg_rfm_score,
    ROUND(AVG(churn_risk_score), 2)                             AS avg_churn_risk,

    -- Segment health flag
    CASE
        WHEN AVG(churn_risk_score) >= 7   THEN 'Critical'
        WHEN AVG(churn_risk_score) >= 4.5 THEN 'Warning'
        ELSE                                   'Healthy'
    END                                                         AS segment_health

FROM gold_customer_insights
GROUP BY segment
ORDER BY total_revenue DESC;

-- Validation 
SELECT 
    segment,
    customer_count,
    total_revenue,
    revenue_share_pct,
    cumulative_revenue_pct,
    avg_churn_risk,
    segment_health
FROM segment_summary;
-- Sanity check: cumulative_revenue_pct of last row should = 100


-- VIEW: business_kpis
-- Layer: BI / Executive Layer
-- Purpose: Single-row KPI summary for executive dashboard
--          cards and high-level reporting
-- Depends on: gold_customer_insights

CREATE OR REPLACE VIEW business_kpis AS
SELECT

    -- Customer Counts 
    COUNT(DISTINCT CustomerID) AS total_customers,

    COUNT(DISTINCT CASE 
        WHEN segment = 'Champions' 
        THEN CustomerID END) AS champion_customers,

    COUNT(DISTINCT CASE 
        WHEN risk_group = 'High Risk' 
        THEN CustomerID END) AS high_risk_customers,

    COUNT(DISTINCT CASE 
        WHEN value_tier = 'High Value' 
        THEN CustomerID END) AS high_value_customers,

    -- Revenue Metrics 
    ROUND(SUM(Monetary), 2)  AS total_revenue,
    ROUND(AVG(Monetary), 2)  AS avg_customer_value,

    -- Champion Metrics 
    ROUND(SUM(CASE 
        WHEN segment = 'Champions' 
        THEN Monetary ELSE 0 END), 2) AS champions_revenue,

    ROUND(SUM(CASE 
        WHEN segment = 'Champions' 
        THEN Monetary ELSE 0 END) 
        / SUM(Monetary) * 100, 2)  AS champions_revenue_pct,

    --  Risk Metrics 
    ROUND(SUM(CASE 
        WHEN risk_group = 'High Risk'
        THEN Monetary ELSE 0 END), 2)  AS revenue_at_risk,

    ROUND(SUM(CASE 
        WHEN risk_group = 'High Risk'
        THEN Monetary ELSE 0 END) 
        / SUM(Monetary) * 100, 2)  AS revenue_at_risk_pct,

    --  Health Metrics 
    ROUND(AVG(rfm_composite_score), 2)                           AS portfolio_rfm_score,
    ROUND(AVG(churn_risk_score), 2)                              AS portfolio_churn_risk,

    --  Portfolio Health Label 
    CASE
        WHEN AVG(churn_risk_score) >= 7   THEN 'Critical'
        WHEN AVG(churn_risk_score) >= 4.5 THEN 'Warning'
        ELSE                                   'Healthy'
    END  AS portfolio_health

FROM gold_customer_insights;

-- Validation
SELECT * FROM business_kpis;
-- Sanity checks:
-- champions_revenue_pct + revenue_at_risk_pct should not exceed 100
-- portfolio_rfm_score should be between 1.0 and 4.0
-- high_risk_customers < total_customers
 



		-- SECTION 8: STRATEGIC INVESTMENT SIMULATION LAYER
-- VIEW: strategic_customer_actions
-- Layer: Strategic / Simulation Layer
-- Purpose: Models estimated marketing investment allocation
--          and expected customer value retention per segment
-- 
-- Investment Logic:
--   Rates reflect retention priority and recovery probability
--   High-risk segments receive higher investment rates
--   Lost segment receives minimal investment (low ROI probability)
--
-- Depends on: gold_customer_insights

CREATE OR REPLACE VIEW strategic_customer_actions AS

WITH investment_logic AS (
    SELECT
        CustomerID,
        last_purchase_date,
        segment,
        value_tier,
        risk_group,
        marketing_action,
        Recency,
        Frequency,
        Monetary,
        rfm_composite_score,
        churn_risk_score,

        -- Investment Rate by Segment 
        -- Rates based on retention priority and recovery potential
        CASE
            WHEN segment = 'Champions'           THEN 0.05  -- Low invest, high return
            WHEN segment = 'Loyal Customers'     THEN 0.07  -- Maintain loyalty
            WHEN segment = 'Potential Loyalists' THEN 0.10  -- Growth opportunity
            WHEN segment = 'New Customers'       THEN 0.12  -- Onboarding investment
            WHEN segment = 'Needs Attention'     THEN 0.08  -- Re-engage moderately
            WHEN segment = 'At Risk'             THEN 0.18  -- Urgent retention
            WHEN segment = 'Lost High Value'     THEN 0.20  -- High value win-back
            WHEN segment = 'Lost'                THEN 0.03  -- Minimal, low ROI
            ELSE 0.08
        END AS investment_rate

    FROM gold_customer_insights
),

investment_calculations AS (
    SELECT
        *,
        -- Core Investment Metrics 
        ROUND(Monetary * investment_rate, 2)             AS estimated_marketing_investment,
        ROUND(Monetary * (1 - investment_rate), 2)       AS estimated_customer_value,

        -- ROI Ratio 
        -- How much value retained per £1 invested
        ROUND((1 - investment_rate) / investment_rate, 2) AS roi_ratio,

        -- Recovery Priority Score 
        -- Combines churn risk and monetary value for prioritization
        -- Higher score = should be actioned first
        ROUND(
            (churn_risk_score * 0.4) + 
            (investment_rate * 10 * 0.6)
        , 2) AS recovery_priority_score,

        -- Action Urgency Label 
        CASE
            WHEN churn_risk_score >= 8                    THEN 'Immediate Action'
            WHEN churn_risk_score >= 6                    THEN 'Action This Month'
            WHEN churn_risk_score >= 4                    THEN 'Monitor Closely'
            ELSE                                               'Maintain'
        END AS action_urgency

    FROM investment_logic
)

SELECT
    CustomerID,
    last_purchase_date,
    segment,
    value_tier,
    risk_group,
    marketing_action,
    action_urgency,
    Recency,
    Frequency,
    ROUND(Monetary, 2) AS Monetary,
    rfm_composite_score,
    churn_risk_score,
    investment_rate,
    estimated_marketing_investment,
    estimated_customer_value,
    roi_ratio,
    recovery_priority_score

FROM investment_calculations
ORDER BY recovery_priority_score DESC;

-- Validation 
-- 1. Summary by action urgency
SELECT
    action_urgency,
    COUNT(*)                                    AS customer_count,
    ROUND(SUM(Monetary), 2)                     AS total_monetary,
    ROUND(SUM(estimated_marketing_investment),2) AS total_investment,
    ROUND(SUM(estimated_customer_value), 2)     AS total_retained_value,
    ROUND(AVG(roi_ratio), 2)                    AS avg_roi_ratio
FROM strategic_customer_actions
GROUP BY action_urgency
ORDER BY avg_roi_ratio DESC;

-- 2. Summary by segment
SELECT
    segment,
    COUNT(*)                                        AS customer_count,
    ROUND(AVG(churn_risk_score), 2)                 AS avg_churn_risk,
    ROUND(SUM(estimated_marketing_investment), 2)   AS total_investment,
    ROUND(SUM(estimated_customer_value), 2)         AS total_retained_value,
    ROUND(AVG(roi_ratio), 2)                        AS avg_roi,
    action_urgency
FROM strategic_customer_actions
GROUP BY segment, action_urgency
ORDER BY avg_churn_risk DESC;



