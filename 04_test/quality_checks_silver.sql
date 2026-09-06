/*
===============================================================================
Quality Checks: Silver Layer
===============================================================================
Purpose:
    Validates that the bronze to silver transformation did what it claims.
    Every query below should return ZERO ROWS. A non-empty result is a failure
    that needs investigating before gold is trusted.

Usage:
    Run after EXEC silver.load_silver and the three external source loaders.
    Run section by section, not as one batch, so a failure is easy to locate.

Reading the results:
    Each check prints its own name so you can tell which one produced output
    when running the whole file.
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. silver.crm_cust_info
-- =============================================================================

PRINT '--- 1.1 Duplicate or null customer id (dedup should leave one row each) ---';
SELECT cst_id, COUNT(*) AS row_count
FROM silver.crm_cust_info
GROUP BY cst_id
HAVING COUNT(*) > 1 OR cst_id IS NULL;

PRINT '--- 1.2 Untrimmed name fields ---';
SELECT cst_id, cst_firstname, cst_lastname
FROM silver.crm_cust_info
WHERE cst_firstname != TRIM(cst_firstname)
   OR cst_lastname  != TRIM(cst_lastname);

PRINT '--- 1.3 Unexpected marital status values (expect Single, Married, n/a) ---';
SELECT DISTINCT cst_marital_status
FROM silver.crm_cust_info
WHERE cst_marital_status NOT IN ('Single', 'Married', 'n/a');

PRINT '--- 1.4 Unexpected gender values (expect Male, Female, n/a) ---';
SELECT DISTINCT cst_gndr
FROM silver.crm_cust_info
WHERE cst_gndr NOT IN ('Male', 'Female', 'n/a');


-- =============================================================================
-- 2. silver.crm_prd_info
-- =============================================================================

PRINT '--- 2.1 Duplicate or null product id ---';
SELECT prd_id, COUNT(*) AS row_count
FROM silver.crm_prd_info
GROUP BY prd_id
HAVING COUNT(*) > 1 OR prd_id IS NULL;

PRINT '--- 2.2 Negative or null cost (nulls should have become 0) ---';
SELECT prd_id, prd_key, prd_cost
FROM silver.crm_prd_info
WHERE prd_cost < 0 OR prd_cost IS NULL;

PRINT '--- 2.3 End date earlier than start date ---';
SELECT prd_id, prd_key, prd_start_dt, prd_end_dt
FROM silver.crm_prd_info
WHERE prd_end_dt < prd_start_dt;

PRINT '--- 2.4 Unexpected product line values ---';
SELECT DISTINCT prd_line
FROM silver.crm_prd_info
WHERE prd_line NOT IN ('Mountain', 'Road', 'Touring', 'Other Sales', 'n/a');

PRINT '--- 2.5 Date rebase applied (expect start dates from 2015 onward) ---';
SELECT MIN(prd_start_dt) AS earliest_start, MAX(prd_start_dt) AS latest_start
FROM silver.crm_prd_info;
-- Expect roughly 2015-07-01 to 2025-07-01. Anything in the 2000s means the
-- +12 year shift did not run.


-- =============================================================================
-- 3. silver.crm_sales_details
-- =============================================================================

PRINT '--- 3.1 Order date later than shipping or due date ---';
SELECT sls_ord_num, sls_order_dt, sls_ship_dt, sls_due_dt
FROM silver.crm_sales_details
WHERE sls_order_dt > sls_ship_dt
   OR sls_order_dt > sls_due_dt;

PRINT '--- 3.2 Sales amount does not equal quantity times price ---';
SELECT sls_ord_num, sls_sales, sls_quantity, sls_price
FROM silver.crm_sales_details
WHERE sls_sales != sls_quantity * sls_price
   OR sls_sales IS NULL OR sls_sales <= 0
   OR sls_quantity IS NULL OR sls_quantity <= 0
   OR sls_price IS NULL OR sls_price <= 0;

PRINT '--- 3.3 Null date counts (order date has 19 known nulls, others zero) ---';
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN sls_order_dt IS NULL THEN 1 ELSE 0 END) AS null_order_dt,
    SUM(CASE WHEN sls_ship_dt  IS NULL THEN 1 ELSE 0 END) AS null_ship_dt,
    SUM(CASE WHEN sls_due_dt   IS NULL THEN 1 ELSE 0 END) AS null_due_dt
FROM silver.crm_sales_details;
-- Expect 60398 / 19 / 0 / 0.

PRINT '--- 3.4 Date rebase applied (expect 2022 to 2026) ---';
SELECT MIN(sls_order_dt) AS earliest_order, MAX(sls_order_dt) AS latest_order
FROM silver.crm_sales_details;
-- Expect 2022-12-29 to 2026-01-28.

PRINT '--- 3.5 Sales dates outside the dim_date range ---';
SELECT COUNT(*) AS rows_outside_calendar
FROM silver.crm_sales_details
WHERE sls_order_dt IS NOT NULL
  AND (sls_order_dt < '2015-01-01' OR sls_order_dt > '2035-12-31');


-- =============================================================================
-- 4. silver.erp_cust_az12
-- =============================================================================

PRINT '--- 4.1 Customer id still carrying the NAS prefix ---';
SELECT cid FROM silver.erp_cust_az12 WHERE cid LIKE 'NAS%';

PRINT '--- 4.2 Birthdates in the future or implausibly old ---';
SELECT cid, bdate
FROM silver.erp_cust_az12
WHERE bdate > GETDATE() OR bdate < '1900-01-01';

PRINT '--- 4.3 Unexpected gender values ---';
SELECT DISTINCT gen
FROM silver.erp_cust_az12
WHERE gen NOT IN ('Male', 'Female', 'n/a');


-- =============================================================================
-- 5. silver.erp_loc_a101
-- =============================================================================

PRINT '--- 5.1 Customer id still carrying a hyphen ---';
SELECT cid FROM silver.erp_loc_a101 WHERE cid LIKE '%-%';

PRINT '--- 5.2 Country values (review manually, expect 6 countries plus n/a) ---';
SELECT cntry, COUNT(*) AS row_count
FROM silver.erp_loc_a101
GROUP BY cntry
ORDER BY row_count DESC;
-- Codes such as DE, US or USA appearing here means standardisation did not run.


-- =============================================================================
-- 6. silver.inventory
-- =============================================================================

PRINT '--- 6.1 Null keys ---';
SELECT COUNT(*) AS rows_with_null_keys
FROM silver.inventory
WHERE product_number IS NULL OR date_key IS NULL OR warehouse IS NULL;

PRINT '--- 6.2 Negative stock ---';
SELECT product_number, warehouse, stock_qty
FROM silver.inventory
WHERE stock_qty < 0;

PRINT '--- 6.3 date_key does not match snapshot_date ---';
SELECT product_number, snapshot_date, date_key
FROM silver.inventory
WHERE date_key != CAST(CONVERT(VARCHAR(8), snapshot_date, 112) AS INT);

PRINT '--- 6.4 Grain check: one row per product, warehouse, date ---';
SELECT product_number, warehouse, snapshot_date, COUNT(*) AS row_count
FROM silver.inventory
GROUP BY product_number, warehouse, snapshot_date
HAVING COUNT(*) > 1;


-- =============================================================================
-- 7. silver.fx_rates
-- =============================================================================

PRINT '--- 7.1 Non-positive or null exchange rate ---';
SELECT * FROM silver.fx_rates
WHERE exchange_rate IS NULL OR exchange_rate <= 0;

PRINT '--- 7.2 Currency codes not in dim_currency ---';
SELECT DISTINCT base_currency, target_currency
FROM silver.fx_rates
WHERE base_currency   NOT IN ('GBP','USD','EUR','CAD','AUD')
   OR target_currency NOT IN ('GBP','USD','EUR','CAD','AUD');

PRINT '--- 7.3 Base and target currency identical ---';
SELECT * FROM silver.fx_rates WHERE base_currency = target_currency;

PRINT '--- 7.4 date_key does not match rate_date ---';
SELECT * FROM silver.fx_rates
WHERE date_key != CAST(CONVERT(VARCHAR(8), rate_date, 112) AS INT);


-- =============================================================================
-- 8. silver.web_events
-- =============================================================================

PRINT '--- 8.1 Duplicate event id ---';
SELECT event_id, COUNT(*) AS row_count
FROM silver.web_events
GROUP BY event_id
HAVING COUNT(*) > 1;

PRINT '--- 8.2 Unexpected event types ---';
SELECT DISTINCT event_type
FROM silver.web_events
WHERE event_type NOT IN ('page_view','search','product_view','add_to_cart','purchase_click');

PRINT '--- 8.3 Null session id (never valid) ---';
SELECT COUNT(*) AS rows_with_null_session FROM silver.web_events WHERE session_id IS NULL;

PRINT '--- 8.4 product_key expected on product events but missing ---';
SELECT event_id, event_type, product_number
FROM silver.web_events
WHERE event_type IN ('product_view','add_to_cart','purchase_click')
  AND product_number IS NULL;

PRINT '--- 8.5 Funnel shape (informational, not a pass or fail) ---';
SELECT event_type, COUNT(*) AS event_count
FROM silver.web_events
GROUP BY event_type
ORDER BY event_count DESC;
-- Expect page_view highest, then search, product_view, add_to_cart,
-- purchase_click. A stage outnumbering the one above it means the generator
-- or the load is wrong.


-- =============================================================================
-- 9. Audit columns
-- =============================================================================

PRINT '--- 9.1 Tables missing dwh_create_date values ---';
SELECT 'crm_cust_info'     AS table_name, COUNT(*) AS null_audit FROM silver.crm_cust_info     WHERE dwh_create_date IS NULL
UNION ALL SELECT 'crm_prd_info',      COUNT(*) FROM silver.crm_prd_info      WHERE dwh_create_date IS NULL
UNION ALL SELECT 'crm_sales_details', COUNT(*) FROM silver.crm_sales_details WHERE dwh_create_date IS NULL
UNION ALL SELECT 'erp_cust_az12',     COUNT(*) FROM silver.erp_cust_az12     WHERE dwh_create_date IS NULL
UNION ALL SELECT 'erp_loc_a101',      COUNT(*) FROM silver.erp_loc_a101      WHERE dwh_create_date IS NULL
UNION ALL SELECT 'erp_px_cat_g1v2',   COUNT(*) FROM silver.erp_px_cat_g1v2   WHERE dwh_create_date IS NULL
UNION ALL SELECT 'inventory',         COUNT(*) FROM silver.inventory         WHERE dwh_create_date IS NULL
UNION ALL SELECT 'fx_rates',          COUNT(*) FROM silver.fx_rates          WHERE dwh_create_date IS NULL
UNION ALL SELECT 'web_events',        COUNT(*) FROM silver.web_events        WHERE dwh_create_date IS NULL;
-- Every count should be zero.

