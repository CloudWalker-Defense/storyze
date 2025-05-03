-- =========================================================================
-- Script name:   001_mssql_create_table_raw.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates the raw table for storing initial MSSQL findings data.
--                This table acts as a direct import target before cleaning/staging.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- History:
-- Date         Author          Comments
-- ----------   -------------   --------------------------------------------
-- 2025-04-10   CWD             Initial creation.
-- =========================================================================

-- Drop the table if it already exists to ensure a clean creation
DROP TABLE IF EXISTS [raw].[mssql_findings];
GO

PRINT 'Creating table [raw].[mssql_findings]...';
GO

BEGIN TRY
    CREATE TABLE [raw].[mssql_findings]
    (
    -- Finding Identifiers & Details
          [raw_mssql_finding_id]		INT IDENTITY(1,1) PRIMARY KEY -- Auto-incrementing primary key for the raw load
        , [Category]					NVARCHAR(2000) NULL
        , [Severity]					NVARCHAR(16) NULL
        , [Issue Name]					NVARCHAR(256) NULL
        , [Affected Targets]			NVARCHAR(MAX) NULL       -- Potentially multi-value, semi-colon separated source string

        -- Status & Priority Indicators (as strings from source)
        , [Status]						NVARCHAR(64) NULL
        , [Impact]						NVARCHAR(64) NULL
        , [Ease Of Implementation]		NVARCHAR(64) NULL
        , [Urgency]						NVARCHAR(64) NULL
        , [Issue Priority]				NVARCHAR(64) NULL

        -- Additional Information (as strings from source)
        , [Due Date]					NVARCHAR(64) NULL
        , [Owner]						NVARCHAR(64) NULL
        , [Notes]						NVARCHAR(MAX) NULL
        
        -- Load Timestamp (using UTC)
        , [raw_load_time]				DATETIME2(0) DEFAULT GETUTCDATE() -- Timestamp of when the row was loaded into this raw table
    );
    PRINT 'Table [raw].[mssql_findings] created successfully.';
END TRY
BEGIN CATCH
    PRINT 'ERROR: Failed to create table [raw].[mssql_findings].'
    PRINT 'ErrorNumber: ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
    PRINT 'ErrorSeverity: ' + CAST(ERROR_SEVERITY() AS VARCHAR(10))
    PRINT 'ErrorState: ' + CAST(ERROR_STATE() AS VARCHAR(10))
    PRINT 'ErrorProcedure: ' + ISNULL(ERROR_PROCEDURE(), 'N/A')
    PRINT 'ErrorLine: ' + CAST(ERROR_LINE() AS VARCHAR(10))
    PRINT 'ErrorMessage: ' + ERROR_MESSAGE();

    THROW;
END CATCH;
GO

PRINT 'Raw Table Creation Script Finished.';
GO