-- =========================================================================
-- Script name:   002_mssql_create_table_map.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates the object mapping table that links standardized 
--                server/instance names to findings and tracks object metadata.
-- Purpose:       Enables consistent reporting across different naming conventions
--                and provides a single source of truth for object information.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

-- Drop existing table to ensure a clean create
DROP TABLE IF EXISTS [prod].[mssql_objects_map];
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
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO

-- =========================================================================
-- Insert 'Unknown' Record
-- Provides a default mapping for findings when object extraction fails.
-- =========================================================================

-- Insert the row only if it doesn't already exist (idempotent operation)
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
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO