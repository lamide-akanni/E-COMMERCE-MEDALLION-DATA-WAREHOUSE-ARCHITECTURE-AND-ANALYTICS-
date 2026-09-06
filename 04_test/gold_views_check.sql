/*
===============================================================================
Pipeline Tests: Orchestration, Logging and Alerting
===============================================================================
Purpose:
    Verifies that the orchestration layer behaves correctly on both a good run
    and a failed one. The failure test matters more than the success test:
    alerting that reports green on a broken pipeline is worse than no alerting,
    because you stop checking it.

    Sections 1 and 2 are read-only. Section 3 deliberately breaks the pipeline
    and puts it back. Read it before running it.

Usage:
    Run section by section. Section 3 renames a silver table, so do not run it
    while a scheduled pipeline run is due.
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. Confirm the pipeline objects exist
-- =============================================================================

PRINT '--- 1.1 Full object inventory (expect 37 objects) ---';
SELECT s.name AS [schema], t.name AS [object], 'TABLE' AS object_type
FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
UNION ALL
SELECT s.name, v.name, 'VIEW'
FROM sys.views v JOIN sys.schemas s ON v.schema_id = s.schema_id
UNION ALL
SELECT s.name, p.name, 'PROC'
FROM sys.procedures p JOIN sys.schemas s ON p.schema_id = s.schema_id
ORDER BY 1, 3, 2;
-- Expect 11 bronze, 13 silver, 10 gold, 3 dbo.

PRINT '--- 1.2 Every load procedure re-raises its errors ---';
SELECT
    s.name AS [schema],
    p.name AS procedure_name,
    CASE WHEN m.definition LIKE '%THROW%' THEN 'yes' ELSE 'NO - will swallow errors' END AS rethrows
FROM sys.procedures p
JOIN sys.schemas s      ON p.schema_id = s.schema_id
JOIN sys.sql_modules m  ON p.object_id = m.object_id
WHERE p.name LIKE 'load%'
ORDER BY s.name, p.name;
-- Every row must read 'yes'. A procedure without THROW ends its CATCH block
-- normally, which looks like success to dbo.log_and_run.

PRINT '--- 1.3 Gold view definitions (useful when reviewing lineage) ---';
SELECT o.name AS view_name, m.definition
FROM sys.sql_modules m
JOIN sys.objects o  ON m.object_id = o.object_id
JOIN sys.schemas s  ON o.schema_id = s.schema_id
WHERE s.name = 'gold' AND o.type = 'V'
ORDER BY o.name;


-- =============================================================================
-- 2. Successful run
-- =============================================================================

PRINT '--- 2.1 Run the pipeline ---';
EXEC dbo.run_full_pipeline;

PRINT '--- 2.2 Confirm the run (expect 6 rows, all SUCCESS) ---';
SELECT
    pipeline_step,
    status,
    duration_sec,
    error_message
FROM dbo.etl_log
WHERE run_id = (SELECT TOP 1 run_id FROM dbo.etl_log ORDER BY log_id DESC)
ORDER BY log_id;
-- Expected steps, in order:
--   bronze.load_bronze
--   bronze.load_brz_inventory
--   silver.load_silver
--   silver.load_slv_inventory
--   silver.load_slv_fx_rates
--   silver.load_slv_web_events

PRINT '--- 2.3 Run history: last 10 runs, one row each ---';
SELECT TOP 10
    run_id,
    MIN(start_time)                                          AS run_started,
    COUNT(*)                                                 AS steps,
    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END)      AS succeeded,
    SUM(CASE WHEN status = 'FAILED'  THEN 1 ELSE 0 END)      AS failed,
    SUM(duration_sec)                                        AS total_seconds
FROM dbo.etl_log
GROUP BY run_id
ORDER BY MIN(start_time) DESC;

PRINT '--- 2.4 Slowest steps across all runs ---';
SELECT
    pipeline_step,
    COUNT(*)             AS times_run,
    AVG(duration_sec)    AS avg_seconds,
    MAX(duration_sec)    AS max_seconds
FROM dbo.etl_log
WHERE status = 'SUCCESS'
GROUP BY pipeline_step
ORDER BY avg_seconds DESC;


-- =============================================================================
-- 3. Failure path
--
-- This section deliberately breaks the pipeline to prove that a failure
-- travels all four handoffs:
--
--     INSERT fails -> stored procedure -> sqlcmd -> batch file -> Slack
--
-- Each handoff can silently drop the error:
--   * a CATCH block without THROW ends normally, so the caller sees success
--   * sqlcmd exits 0 without -b, even when the T-SQL failed
--   * batch files need "if %errorlevel% neq 0", not "if errorlevel 1"
--
-- Fixing only one changes nothing. All three are required.
-- =============================================================================

PRINT '--- 3.1 Break it: rename the table silver.load_slv_inventory writes to ---';
EXEC sp_rename 'silver.inventory', 'silver_inventory_temp';
GO

-- Now run the pipeline. There are two ways, testing different amounts of the
-- chain:
--
--   (a) From SSMS, tests the SQL half only:
--         EXEC dbo.run_full_pipeline;
--
--   (b) From the command line, tests the whole chain including Slack:
--         cd <pipeline folder>
--         run_pipeline.bat
--
-- Option (b) is the real test. Option (a) cannot tell you whether the batch
-- file and Slack alert behave, because it never reaches them.

PRINT '--- 3.2 Confirm the failure was logged ---';
SELECT
    pipeline_step,
    status,
    error_message
FROM dbo.etl_log
WHERE run_id = (SELECT TOP 1 run_id FROM dbo.etl_log ORDER BY log_id DESC)
ORDER BY log_id;
-- Expect silver.load_slv_inventory to read FAILED, with an error message of
-- 'Cannot find the object "inventory"...'. If it reads SUCCESS, the THROW is
-- missing from that procedure's CATCH block.

PRINT '--- 3.3 Put it back ---';
EXEC sp_rename 'silver.silver_inventory_temp', 'inventory';
GO

PRINT '--- 3.4 Confirm recovery ---';
SELECT COUNT(*) AS silver_inventory_rows FROM silver.inventory;
-- Zero rows is expected here, because the failed run truncated the table
-- before hitting the error. Re-run the pipeline to repopulate it.

EXEC dbo.run_full_pipeline;

SELECT pipeline_step, status
FROM dbo.etl_log
WHERE run_id = (SELECT TOP 1 run_id FROM dbo.etl_log ORDER BY log_id DESC)
ORDER BY log_id;
-- All six back to SUCCESS.


-- =============================================================================
-- 4. What to check outside SQL Server
-- =============================================================================
--
-- Slack, after the failed run:
--   Expect a message reading FAILED at SQL Pipeline.
--   A green SUCCESS message on a failed run means either sqlcmd is missing the
--   -b flag, or the batch file is using the old "if errorlevel 1" form.
--
-- Slack, after the successful run:
--   Expect a message reading SUCCESS.
--
-- Windows Task Scheduler:
--   Task history should show Last Run Result 0x0 on success and a non-zero
--   code on failure. A 0x0 on a failed run means the batch file swallowed the
--   error before returning.
--
-- Verify the batch file carries the -b flag:
--   findstr /C:"-b" run_pipeline.bat
--   No output means the flag is missing and sqlcmd will report success on a
--   failed batch.
