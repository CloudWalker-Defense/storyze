-- =========================================================================
-- Script name:   003_mssql_create_table_staging.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates the staging table [stg].[mssql_findings] to hold
--                processed and normalized data from the raw table before
--                loading into production. Includes columns for linking,
--                calculated values, and attributes needed for the final load.
-- Purpose:       Intermediate table for ETL processing of MSSQL findings.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

-- Drop the table if it already exists (idempotent for structure)
DROP TABLE IF EXISTS [stg].[mssql_findings];
GO

BEGIN TRY
    CREATE TABLE [stg].[mssql_findings]
    (
          [stg_mssql_finding_id]    INT             IDENTITY(1,1) NOT NULL
        , [raw_mssql_finding_id]    INT             NULL      -- Link to raw source row (populated during staging load)
        , [normalized_object]       NVARCHAR(512)   NULL
        , [mssql_object_map_id]     INT             NULL      -- Foreign key to [prod].[mssql_objects_map]
        , [impacted_objects]        NVARCHAR(MAX)   NULL      -- Original raw multi-value string from source
        , [finding_category]        NVARCHAR(1000)  NULL
        , [risk_level]              NVARCHAR(16)    NULL
        , [finding_name]            NVARCHAR(2048)  NULL
        , [finding_description]     NVARCHAR(MAX)   NULL      -- Multi-line description of the finding
        , [finding_recommendation]  NVARCHAR(MAX)   NULL      -- Multi-line recommendation for remediation

        -- Status & Calculated Values.
        , [fixed]                   NVARCHAR(16)    NULL      
        , [priority_rank]           INT             NULL      
        , [finding_object_id]       INT             NULL      

        -- Other Attributes.
        , [level_of_effort]         NVARCHAR(32)    NULL
        , [assigned_to]             NVARCHAR(64)    NULL
        , [notes]                   NVARCHAR(MAX)   NULL
        , [exception]               NVARCHAR(255)   NULL      
        , [exception_notes]         NVARCHAR(255)   NULL      
        , [exception_proof]         NVARCHAR(255)   NULL      -- Proof supporting exception
        , [start_date]              DATETIME2(0)    NULL      -- Finding start date
        , [end_date]                DATETIME2(0)    NULL      -- Finding end date

        -- Staging audit columns (using UTC for consistency)
        , [stg_load_date]           DATETIME2(0)    NOT NULL CONSTRAINT [DF_stg_mssql_findings_load_date] DEFAULT GETUTCDATE()
        , [stg_created_by]          NVARCHAR(128)   NOT NULL CONSTRAINT [DF_stg_mssql_findings_created_by] DEFAULT SUSER_SNAME()  -- SQL login performing staging load

        , CONSTRAINT [PK_stg_mssql_findings] PRIMARY KEY CLUSTERED ([stg_mssql_finding_id] ASC)
    );

    PRINT 'Table [stg].[mssql_findings] created successfully.';
END TRY
BEGIN CATCH
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO
