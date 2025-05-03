-- =========================================================================
-- Script name:   010_mssql_update_objectid_prio.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Calculates and updates finding_object_id and priority_rank
--                in [stg].[mssql_findings] based on grouping by object/finding
--                and ordering by risk level. Also sets [fixed] flag to 'N'.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- History:
-- Date         Author          Comments
-- ----------   -------------   --------------------------------------------
-- 2025-04-10   CWD             Initial creation.
-- =========================================================================

PRINT 'Starting Task 09: Calculate Priority and Finding Object ID for [stg].[mssql_findings]...';

BEGIN TRY
    BEGIN TRANSACTION;

    -- Step 1: Initialize/Reset relevant columns before calculation
    PRINT 'Step 1: Initializing fixed flag to N and clearing previous ranks...';
    UPDATE [stg].[mssql_findings]
    SET
          [fixed] = 'N', -- Set fixed to 'N' for all rows
          [finding_object_id] = NULL,
          [priority_rank] = NULL
    ; -- Terminating semicolon
    PRINT 'Initialization complete. Affected: ' + CAST(@@ROWCOUNT AS VARCHAR(20));

    -- Step 2: Calculate Priority and Finding Object ID using CTEs
    PRINT 'Step 2: Calculating priority and finding_object_id...';

    WITH [IssueGroups] AS (
        -- Identify unique finding groups by object and name, using the minimum staging ID as a representative
        SELECT
              [normalized_object]
            , [finding_name]
            , MIN([stg_mssql_finding_id]) AS [min_stg_id]
        FROM [stg].[mssql_findings]
        WHERE [normalized_object] IS NOT NULL AND [finding_name] IS NOT NULL
        GROUP BY [normalized_object], [finding_name]
    ),
    [RankedIssues] AS (
        -- Rank these unique finding groups within each risk level based on their representative ID
        SELECT
              [ig].[min_stg_id]
            , [stg].[risk_level]
            , ROW_NUMBER() OVER (PARTITION BY [stg].[risk_level] ORDER BY [ig].[min_stg_id]) AS [rn]
        FROM [IssueGroups] AS [ig]
        INNER JOIN [stg].[mssql_findings] AS [stg] ON [ig].[min_stg_id] = [stg].[stg_mssql_finding_id]
        WHERE [stg].[risk_level] IS NOT NULL
    ),
    [PriorityMapping] AS (
        -- Calculate final priority by offsetting the rank within risk level by counts of higher levels
        SELECT
              [min_stg_id]
            , [risk_level]
            , [rn] +
              (CASE [risk_level]
                    WHEN 'Critical'      THEN 0
                    WHEN 'High'          THEN ISNULL((SELECT COUNT(*) FROM [RankedIssues] WHERE [risk_level] = 'Critical'), 0)
                    WHEN 'Medium'        THEN ISNULL((SELECT COUNT(*) FROM [RankedIssues] WHERE [risk_level] IN ('Critical', 'High')), 0)
                    WHEN 'Low'           THEN ISNULL((SELECT COUNT(*) FROM [RankedIssues] WHERE [risk_level] IN ('Critical', 'High', 'Medium')), 0)
                    WHEN 'Informational' THEN ISNULL((SELECT COUNT(*) FROM [RankedIssues] WHERE [risk_level] IN ('Critical', 'High', 'Medium', 'Low')), 0)
                    ELSE ISNULL((SELECT COUNT(*) FROM [RankedIssues] WHERE [risk_level] IN ('Critical', 'High', 'Medium', 'Low', 'Informational')), 0) + 100000 -- Large offset for others
                END) AS [calculated_priority_and_finding_id]
        FROM [RankedIssues]
    )
    -- Step 3: Update the staging table using the CTEs defined above
    UPDATE [stg]
    SET
          [stg].[finding_object_id] = [pm].[calculated_priority_and_finding_id],
          [stg].[priority_rank] = [pm].[calculated_priority_and_finding_id]
    FROM [stg].[mssql_findings] AS [stg]
    INNER JOIN [IssueGroups] AS [ig] ON [stg].[normalized_object] = [ig].[normalized_object] AND [stg].[finding_name] = [ig].[finding_name]
    LEFT JOIN [PriorityMapping] AS [pm] ON [ig].[min_stg_id] = [pm].[min_stg_id];

    PRINT 'Updating [stg].[mssql_findings] with calculated values...';
    PRINT 'Update complete. Affected rows: ' + CAST(@@ROWCOUNT AS VARCHAR(20));

    COMMIT TRANSACTION;
    PRINT 'Task 09: Priority and Finding Object ID Calculation Finished Successfully.';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '--- ERROR OCCURRED DURING PRIORITY CALCULATION ---';
    PRINT 'Error Number: ' + CAST(ERROR_NUMBER() AS VARCHAR(20));
    PRINT 'Error Message: ' + ERROR_MESSAGE();
    PRINT 'Error Line: ' + CAST(ERROR_LINE() AS VARCHAR(20));
    PRINT 'Transaction rolled back.';
    THROW;
END CATCH;
GO