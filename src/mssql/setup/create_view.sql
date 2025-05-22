-- =========================================================================
-- Script name:   005_mssql_create_view.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates a reporting view that presents the most important 
--                finding attributes in a simplified format for end users.
-- Purpose:       Provides a business-focused interface for reporting tools
--                while hiding implementation details of the underlying tables.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

-- Drop the view if it already exists
DROP VIEW IF EXISTS [prod].[vw_mssql_findings];
GO

BEGIN TRY
    -- CREATE VIEW must often be the first statement in a batch.
    -- We use dynamic SQL to execute it within the TRY block.
    DECLARE @sql NVARCHAR(MAX) = N'
    CREATE VIEW [prod].[vw_mssql_findings]
    AS
    SELECT
        -- Link to Raw Source
          [finding_object_id]

        -- Core Identifiers & Finding Info
        , [normalized_object]
        , [finding_name]
        , [finding_category]
        , [risk_level]
        , [impacted_objects]      -- Original raw multi-value string

        -- Status & Calculated Rank/ID values
        , [fixed]
        , [priority_rank]
        , [mssql_object_map_id] -- Keeping the link to the object map
        
        -- Other Attributes
        , [level_of_effort]
        , [assigned_to]
        , [notes]
        , [exception]
        , [exception_notes]
        , [exception_proof]
        , CAST([start_date] AS DATE) AS [start_date]
        , CAST([end_date] AS DATE) AS [end_date]

    FROM
        [prod].[mssql_findings];';

    EXEC sp_executesql @sql;

    PRINT 'View [prod].[vw_mssql_findings] created successfully.';

END TRY
BEGIN CATCH
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO