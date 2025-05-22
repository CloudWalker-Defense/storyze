-- =========================================================================
-- Script name:   005_update_objectid_prio.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Updates the finding_object_id and priority_rank fields in the 
--                staging table to establish relationships between findings and
--                support consistent prioritization across risk levels.
-- Purpose:       Creates unique identifiers for tracking related findings and
--                establishing a priority order for remediation activities.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

BEGIN TRY
    BEGIN TRANSACTION;

    -- Step 1: Initialize/Reset relevant columns before calculation
    UPDATE [stg].[mssql_findings]
    SET
          [fixed] = 'N', -- Set fixed to 'N' for all rows
          [finding_object_id] = NULL,
          [priority_rank] = NULL
    ; -- Terminating semicolon
    PRINT 'Initialized fixed flag and ranks. Affected rows: ' + CAST(@@ROWCOUNT AS VARCHAR);

    -- Step 2: Calculate Priority and Finding Object ID using CTEs
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

    PRINT 'Updated finding_object_id and priority_rank. Affected rows: ' + CAST(@@ROWCOUNT AS VARCHAR);

    COMMIT TRANSACTION;
    PRINT 'Priority and Finding Object ID calculation completed successfully.';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO