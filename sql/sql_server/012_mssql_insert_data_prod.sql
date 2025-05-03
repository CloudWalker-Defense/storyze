-- =========================================================================
-- Script name:   012_mssql_insert_data_prod.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Loads data from the fully processed staging table
--                [stg].[mssql_findings] into the production table
--                [prod].[mssql_findings].
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- History:
-- Date         Author          Comments
-- ----------   -------------   --------------------------------------------
-- 2025-04-10   CWD             Initial creation.
-- =========================================================================

PRINT 'Starting Load from [stg].[mssql_findings] to [prod].[mssql_findings]...';

BEGIN TRY
    BEGIN TRANSACTION;

    -- Step 1: Truncate Production table for a full reload
    PRINT 'Truncating existing data from [prod].[mssql_findings]...';
    TRUNCATE TABLE [prod].[mssql_findings];

    PRINT 'Production table truncated.';

    -- Step 2: Insert data from Staging into Production
    PRINT 'Inserting data from Staging into Production...';

    INSERT INTO [prod].[mssql_findings] (
        
          [raw_mssql_finding_id]
        , [normalized_object]
        , [mssql_object_map_id]
        , [finding_name]
        , [finding_category]
        , [risk_level]
        , [impacted_objects]
        , [fixed]
        , [priority_rank]
        , [finding_object_id]
        , [level_of_effort]
        , [assigned_to]
        , [notes]
        , [exception]
        , [exception_notes]
        , [exception_proof]
        , [start_date]
        , [end_date]
    )
    SELECT
          stg.[raw_mssql_finding_id]
        , stg.[normalized_object]
        , stg.[mssql_object_map_id]
        , stg.[finding_name]
        , stg.[finding_category]
        , stg.[risk_level]
        , stg.[impacted_objects]
        , stg.[fixed]
        , stg.[priority_rank]
        , stg.[finding_object_id]
        , stg.[level_of_effort]
        , stg.[assigned_to]
        , stg.[notes]
        , stg.[exception]
        , stg.[exception_notes]
        , stg.[exception_proof]
        , stg.[start_date]
        , stg.[end_date]
    FROM
        [stg].[mssql_findings] AS stg; -- Source staging table

    PRINT 'INSERT completed. Rows inserted: ' + CAST(@@ROWCOUNT AS VARCHAR(20));

    COMMIT TRANSACTION;
    PRINT 'Transaction committed successfully.';

END TRY
BEGIN CATCH
    -- If any error occurred, rollback the transaction
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT '--- ERROR OCCURRED DURING PROD LOAD ---';
    PRINT 'Error Number: ' + CAST(ERROR_NUMBER() AS VARCHAR(20));
    PRINT 'Error Message: ' + ERROR_MESSAGE();
    PRINT 'Error Line: ' + CAST(ERROR_LINE() AS VARCHAR(20));
    PRINT 'Transaction rolled back.';

    -- Re-throw the error
    THROW;
END CATCH;
GO