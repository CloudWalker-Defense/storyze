-- =========================================================================
-- Script name:   002_mssql_create_table_map.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates the object mapping table ([prod].[mssql_objects_map]) 
--                used to link standardized object names to findings.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- History:
-- Date         Author          Comments
-- ----------   -------------   --------------------------------------------
-- 2025-04-10   CWD             Initial creation.
-- =========================================================================

PRINT 'Starting Object Map Table Creation for MSSQL...';
GO

-- Drop existing table to ensure a clean create
DROP TABLE IF EXISTS [prod].[mssql_objects_map];
GO

PRINT 'Creating table [prod].[mssql_objects_map]...';
GO

BEGIN TRY
    CREATE TABLE [prod].[mssql_objects_map]
    (
          [mssql_object_map_id]   INT             IDENTITY(1,1) NOT NULL 
        , [object_name]           NVARCHAR(512)   NOT NULL              
        , [object_type]           NVARCHAR(50)    NULL                
        , [description]           NVARCHAR(1024)  NULL                  

    -- Audit columns
    , [created_date]          DATETIME2(0)    NOT NULL CONSTRAINT [DF_mssql_objects_map_created_date] DEFAULT GETUTCDATE()
    , [created_by]            NVARCHAR(128)   NOT NULL CONSTRAINT [DF_mssql_objects_map_created_by] DEFAULT SUSER_SNAME()
    , [modified_date]         DATETIME2(0)    NOT NULL CONSTRAINT [DF_mssql_objects_map_modified_date] DEFAULT GETUTCDATE()
    , [modified_by]           NVARCHAR(128)   NOT NULL CONSTRAINT [DF_mssql_objects_map_modified_by] DEFAULT SUSER_SNAME()

        , CONSTRAINT [PK_prod_mssql_objects_map] PRIMARY KEY CLUSTERED ([mssql_object_map_id] ASC)
        , CONSTRAINT [UQ_prod_mssql_objects_map_name] UNIQUE NONCLUSTERED ([object_name]) -- Ensure object names are unique
    );
    PRINT 'Table [prod].[mssql_objects_map] created successfully.';
END TRY
BEGIN CATCH
    PRINT 'ERROR: Failed to create table [prod].[mssql_objects_map].'
    PRINT 'ErrorNumber: ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
    PRINT 'ErrorSeverity: ' + CAST(ERROR_SEVERITY() AS VARCHAR(10))
    PRINT 'ErrorState: ' + CAST(ERROR_STATE() AS VARCHAR(10))
    PRINT 'ErrorProcedure: ' + ISNULL(ERROR_PROCEDURE(), 'N/A')
    PRINT 'ErrorLine: ' + CAST(ERROR_LINE() AS VARCHAR(10))
    PRINT 'ErrorMessage: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO

-- =========================================================================
-- Insert 'Unknown' Record
-- Provides a default record to map findings when object extraction/mapping fails.
-- =========================================================================
PRINT 'Ensuring default ''Unknown'' record exists in [prod].[mssql_objects_map]...';
GO

-- Insert the row only if it doesn't already exist.
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM [prod].[mssql_objects_map] WHERE [object_name] = 'Unknown')
    BEGIN
        INSERT INTO [prod].[mssql_objects_map] ([object_name], [object_type])
        VALUES ('Unknown', 'Unknown'); -- Note: Audit columns will use defaults

        PRINT '''Unknown'' record inserted.';
    END
    ELSE
    BEGIN
        PRINT '''Unknown'' record already exists.';
    END
END TRY
BEGIN CATCH
    PRINT 'ERROR: Failed to insert/verify ''Unknown'' record.'
    PRINT 'ErrorNumber: ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
    PRINT 'ErrorSeverity: ' + CAST(ERROR_SEVERITY() AS VARCHAR(10))
    PRINT 'ErrorState: ' + CAST(ERROR_STATE() AS VARCHAR(10))
    PRINT 'ErrorProcedure: ' + ISNULL(ERROR_PROCEDURE(), 'N/A')
    PRINT 'ErrorLine: ' + CAST(ERROR_LINE() AS VARCHAR(10))
    PRINT 'ErrorMessage: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO

PRINT 'Object Map Table Creation Script Finished.';
GO