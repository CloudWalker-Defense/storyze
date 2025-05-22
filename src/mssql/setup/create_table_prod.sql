-- =========================================================================
-- Script name:   004_mssql_create_table_prod.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates the production table for MSSQL findings.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

-- Drop the table if it already exists.
DROP TABLE IF EXISTS [prod].[mssql_findings];
GO

BEGIN TRY
    CREATE TABLE [prod].[mssql_findings]
    (
          [prod_mssql_finding_id]      INT             IDENTITY(1,1) NOT NULL

          -- Link to Raw Source (for traceability)
        , [raw_mssql_finding_id]       INT             NULL

          -- Core Identifiers & Finding Info
        , [normalized_object]          NVARCHAR(512)   NULL      -- Final normalized object name (UPPERCASE)
        , [mssql_object_map_id]        INT             NOT NULL  -- FK to map table
        , [finding_name]               NVARCHAR(2048)  NOT NULL
        , [finding_category]           NVARCHAR(1000)  NOT NULL
        , [risk_level]                 NVARCHAR(16)    NOT NULL
            CONSTRAINT [CK_prod_mssql_findings_risk_level] CHECK ([risk_level] IN ('Critical', 'High', 'Medium', 'Low', 'Informational'))
        , [impacted_objects]           NVARCHAR(MAX)   NULL      -- Original raw multi-value string

          -- Status & Calculated Rank/ID values
        , [fixed]                      CHAR(1)         NULL
            CONSTRAINT [CK_prod_mssql_findings_fixed] CHECK ([fixed] IN ('Y', 'N'))
        , [priority_rank]              INT             NULL      -- Calculated rank
        , [finding_object_id]          INT             NULL      -- Calculated finding group ID (groups related findings, e.g., same check on different objects)

          -- Other Attributes
        , [level_of_effort]            NVARCHAR(32)    NULL
            CONSTRAINT [CK_prod_mssql_findings_loe] CHECK ([level_of_effort] IS NULL OR [level_of_effort] IN ('High', 'Medium', 'Low'))
        , [assigned_to]                NVARCHAR(64)    NULL
        , [notes]                      NVARCHAR(MAX)   NULL
        , [exception]                  NVARCHAR(255)   NULL
            CONSTRAINT [CK_prod_mssql_findings_exception] CHECK ([exception] IS NULL OR [exception] IN ('GPO', 'Org Policy', 'Other', 'STIG'))
        , [exception_notes]            NVARCHAR(255)   NULL
        , [exception_proof]            NVARCHAR(255)   NULL
        , [start_date]                 DATETIME2(0)    NULL
        , [end_date]                   DATETIME2(0)    NULL

      -- Production audit columns
    , [prod_created_date]          DATETIME2(0)    NOT NULL CONSTRAINT [DF_prod_mssql_findings_created_date] DEFAULT GETUTCDATE()
    , [prod_created_by]            NVARCHAR(128)   NOT NULL CONSTRAINT [DF_prod_mssql_findings_created_by] DEFAULT SUSER_SNAME()
    , [prod_modified_date]         DATETIME2(0)    NOT NULL CONSTRAINT [DF_prod_mssql_findings_modified_date] DEFAULT GETUTCDATE()
    , [prod_modified_by]           NVARCHAR(128)   NOT NULL CONSTRAINT [DF_prod_mssql_findings_modified_by] DEFAULT SUSER_SNAME()

        , CONSTRAINT [PK_prod_mssql_findings] PRIMARY KEY CLUSTERED ([prod_mssql_finding_id] ASC)
        , CONSTRAINT [FK_prod_mssql_findings_map] FOREIGN KEY ([mssql_object_map_id]) REFERENCES [prod].[mssql_objects_map] ([mssql_object_map_id]) ON DELETE NO ACTION
    );
    PRINT 'Table [prod].[mssql_findings] created successfully with constraints.';

END TRY
BEGIN CATCH
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO


-- Add Indexes
BEGIN TRY
    CREATE NONCLUSTERED INDEX [IX_prod_mssql_findings_map_id] ON [prod].[mssql_findings] ([mssql_object_map_id]);
    CREATE NONCLUSTERED INDEX [IX_prod_mssql_findings_normalized_object] ON [prod].[mssql_findings] ([normalized_object]);
    CREATE NONCLUSTERED INDEX [IX_prod_mssql_findings_finding_name] ON [prod].[mssql_findings] ([finding_name]);
    CREATE NONCLUSTERED INDEX [IX_prod_mssql_findings_risk_priority] ON [prod].[mssql_findings] ([risk_level], [priority_rank]);
    CREATE NONCLUSTERED INDEX [IX_prod_mssql_findings_finding_object_id] ON [prod].[mssql_findings] ([finding_object_id]);
    CREATE NONCLUSTERED INDEX [IX_prod_mssql_findings_raw_id] ON [prod].[mssql_findings] ([raw_mssql_finding_id]);
    PRINT 'Indexes created successfully.';
END TRY
BEGIN CATCH
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO