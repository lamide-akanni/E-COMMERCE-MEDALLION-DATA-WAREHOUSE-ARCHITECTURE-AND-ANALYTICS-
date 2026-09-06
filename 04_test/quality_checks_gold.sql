/*
===============================================================================
Quality Checks: Gold Layer
===============================================================================
Purpose:
    Validates the star schema before it is loaded into the reporting model.
    Checks surrogate key uniqueness, referential integrity between facts and
    dimensions, and the row counts each object should return.

    Every query below should return ZERO ROWS unless marked informational.

Usage:
    Run after the gold views and gold.dim_date exist, and after a full pipeline
    run has populated silver.
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. Surrogate key uniqueness
-- Every dimension primary key must be unique and non-null.
-- =============================================================================

PRINT '--- 1.1 dim_customers.customer_key ---';
SELECT customer_key, COUNT(*) AS row_count
FROM gold.dim_customers
GROUP BY customer_key HAVING COUNT(*) > 1 OR customer_key IS NULL;

PRINT '--- 1.2 dim_products.product_key ---';
SELECT product_key, COUNT(*) AS row_count
FROM gold.dim_products
GROUP BY product_key HAVING COUNT(*) > 1 OR product_key IS NULL;

PRINT '--- 1.3 dim_currency.currency_key ---';
SELECT currency_key, COUNT(*) AS row_count
FROM gold.dim_currency
GROUP BY currency_key HAVING COUNT(*) > 1 OR currency_key IS NULL;

PRINT '--- 1.4 dim_date.date_key ---';
SELECT date_key, COUNT(*) AS row_count
FROM gold.dim_date
GROUP BY date_key HAVING COUNT(*) > 1 OR date_key IS NULL;

PRINT '--- 1.5 dim_date.full_date (alternate key, must also be unique) ---';
SELECT full_date, COUNT(*) AS row_count
FROM gold.dim_date
GROUP BY full_date HAVING COUNT(*) > 1 OR full_date IS NULL;

PRINT '--- 1.6 fact_web_events.event_id (the one fact with a real PK) ---';
SELECT event_id, COUNT(*) AS row_count
FROM gold.fact_web_events
GROUP BY event_id HAVING COUNT(*) > 1 OR event_id IS NULL;


-- =============================================================================
-- 2. Referential integrity
-- Every foreign key in a fact must resolve to a row in its dimension.
-- A null surrogate key means the join in the gold view failed to match.
-- =============================================================================

PRINT '--- 2.1 fact_sales with unresolved keys ---';
SELECT
    SUM(CASE WHEN product_key  IS NULL THEN 1 ELSE 0 END) AS unresolved_product,
    SUM(CASE WHEN customer_key IS NULL THEN 1 ELSE 0 END) AS unresolved_customer
FROM gold.fact_sales;
-- Both should be zero.

PRINT '--- 2.2 fact_inventory with unresolved product key ---';
SELECT COUNT(*) AS unresolved_product
FROM gold.fact_inventory WHERE product_key IS NULL;

PRINT '--- 2.3 fact_fx_rates with unresolved currency keys ---';
SELECT
    SUM(CASE WHEN base_currency_key   IS NULL THEN 1 ELSE 0 END) AS unresolved_base,
    SUM(CASE WHEN target_currency_key IS NULL THEN 1 ELSE 0 END) AS unresolved_target
FROM gold.fact_fx_rates;

PRINT '--- 2.4 fact_web_events unresolved keys (nulls here are EXPECTED) ---';
SELECT
    COUNT(*) AS total_events,
    SUM(CASE WHEN customer_key IS NULL THEN 1 ELSE 0 END) AS anonymous_events,
    SUM(CASE WHEN product_key  IS NULL THEN 1 ELSE 0 END) AS non_product_events
FROM gold.fact_web_events;
-- Informational. Anonymous sessions and non-product events legitimately carry
-- null keys by design. Roughly 70 percent anonymous is expected.

PRINT '--- 2.5 Date keys not present in dim_date ---';
SELECT 'fact_inventory' AS fact_table, COUNT(*) AS orphan_dates
FROM gold.fact_inventory f
LEFT JOIN gold.dim_date d ON f.date_key = d.date_key
WHERE d.date_key IS NULL
UNION ALL
SELECT 'fact_fx_rates', COUNT(*)
FROM gold.fact_fx_rates f
LEFT JOIN gold.dim_date d ON f.date_key = d.date_key
WHERE d.date_key IS NULL
UNION ALL
SELECT 'fact_web_events', COUNT(*)
FROM gold.fact_web_events f
LEFT JOIN gold.dim_date d ON f.date_key = d.date_key
WHERE d.date_key IS NULL;
-- All three should be zero.

PRINT '--- 2.6 fact_sales dates not present in dim_date ---';
SELECT COUNT(*) AS orphan_order_dates
FROM gold.fact_sales f
LEFT JOIN gold.dim_date d ON f.order_date = d.full_date
WHERE d.full_date IS NULL AND f.order_date IS NOT NULL;
-- fact_sales joins on full_date rather than date_key. Should be zero.


-- =============================================================================
-- 3. Expected row counts
-- Informational. Compare against the figures documented in the data catalog.
-- =============================================================================

PRINT '--- 3.1 Row counts across the gold layer ---';
SELECT 'dim_date'        AS object_name, COUNT(*) AS row_count, '7,670 expected'  AS expected FROM gold.dim_date
UNION ALL SELECT 'dim_customers',   COUNT(*), '18,484 expected' FROM gold.dim_customers
UNION ALL SELECT 'dim_products',    COUNT(*), '295 expected'    FROM gold.dim_products
UNION ALL SELECT 'dim_currency',    COUNT(*), '5 expected'      FROM gold.dim_currency
UNION ALL SELECT 'dim_security',    COUNT(*), '12 expected'     FROM gold.dim_security
UNION ALL SELECT 'fact_sales',      COUNT(*), '60,398 expected' FROM gold.fact_sales
UNION ALL SELECT 'fact_inventory',  COUNT(*), '8,850 expected'  FROM gold.fact_inventory
UNION ALL SELECT 'fact_fx_rates',   COUNT(*), 'varies by run'   FROM gold.fact_fx_rates
UNION ALL SELECT 'fact_web_events', COUNT(*), 'varies by run'   FROM gold.fact_web_events;


-- =============================================================================
-- 4. Grain integrity
-- Each fact must hold exactly one row per its declared grain.
-- =============================================================================

PRINT '--- 4.1 fact_sales grain: one row per order line ---';
SELECT order_number, product_key, COUNT(*) AS row_count
FROM gold.fact_sales
GROUP BY order_number, product_key
HAVING COUNT(*) > 1;

PRINT '--- 4.2 fact_inventory grain: one row per product, warehouse, date ---';
SELECT product_key, warehouse, date_key, COUNT(*) AS row_count
FROM gold.fact_inventory
GROUP BY product_key, warehouse, date_key
HAVING COUNT(*) > 1;

PRINT '--- 4.3 fact_fx_rates grain: one row per currency pair, date ---';
SELECT date_key, base_currency_key, target_currency_key, COUNT(*) AS row_count
FROM gold.fact_fx_rates
GROUP BY date_key, base_currency_key, target_currency_key
HAVING COUNT(*) > 1;


-- =============================================================================
-- 5. dim_date integrity
-- =============================================================================

PRINT '--- 5.1 Gaps in the calendar ---';
SELECT COUNT(*) AS expected_days, DATEDIFF(DAY, '2015-01-01', '2035-12-31') + 1 AS calendar_days
FROM gold.dim_date;
-- The two numbers must match. A difference means the recursive CTE lost days.

PRINT '--- 5.2 Weekend flag correctness ---';
SELECT COUNT(*) AS mismatched_weekend_flags
FROM gold.dim_date
WHERE (weekday_name IN ('Saturday','Sunday') AND is_weekend != 1)
   OR (weekday_name NOT IN ('Saturday','Sunday') AND is_weekend != 0);

PRINT '--- 5.3 date_key does not match full_date ---';
SELECT COUNT(*) AS mismatched_keys
FROM gold.dim_date
WHERE date_key != CAST(CONVERT(VARCHAR(8), full_date, 112) AS INT);


-- =============================================================================
-- 6. Business rule checks
-- =============================================================================

PRINT '--- 6.1 Negative or zero sales values ---';
SELECT COUNT(*) AS invalid_sales
FROM gold.fact_sales
WHERE sales_amount <= 0 OR quantity <= 0 OR price <= 0;

PRINT '--- 6.2 sales_amount does not equal quantity times price ---';
SELECT COUNT(*) AS inconsistent_lines
FROM gold.fact_sales
WHERE sales_amount != quantity * price;

PRINT '--- 6.3 Stock below reorder level (informational, a real business signal) ---';
SELECT warehouse, COUNT(*) AS products_below_reorder
FROM gold.fact_inventory
WHERE stock_quantity < reorder_level
GROUP BY warehouse
ORDER BY products_below_reorder DESC;

PRINT '--- 6.4 dim_security countries not present in dim_customers ---';
SELECT DISTINCT s.country
FROM gold.dim_security s
LEFT JOIN gold.dim_customers c ON s.country = c.country
WHERE c.country IS NULL;
-- A row here means a security grant points at a country with no customers,
-- so that user would see nothing.

PRINT '--- 6.5 Funnel stage counts (informational) ---';
SELECT event_type, COUNT(*) AS event_count
FROM gold.fact_web_events
GROUP BY event_type
ORDER BY event_count DESC;


