-- =========================================================================
-- Script name:   007_insert_data_prod.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Final ETL step that transfers fully processed data from the 
--                staging table to the production table, making it available 
--                for reporting and analysis.
-- Purpose:       Creates the production dataset used by business reports 
--                and dashboards to track remediation progress.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

BEGIN TRY
    BEGIN TRANSACTION;

    -- Step 1: Truncate Production table for a full reload
    TRUNCATE TABLE [prod].[mssql_findings];
    PRINT 'Production table truncated.';

    -- Step 2: Insert data from Staging into Production
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

    PRINT 'Inserted ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows into production table.';

    COMMIT TRANSACTION;
    PRINT 'Production data load completed successfully.';

END TRY
BEGIN CATCH
    -- If any error occurred, rollback the transaction
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT 'ERROR: ' + ERROR_MESSAGE();

    -- Re-throw the error
    THROW;
END CATCH;
GO