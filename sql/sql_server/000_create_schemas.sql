-- =========================================================================
-- Script name:   000_create_schemas.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates the necessary database schemas (raw, stg, prod).
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- History:
-- Date         Author          Comments
-- ----------   -------------   --------------------------------------------
-- 2025-04-10   CWD             Initial creation.
-- =========================================================================

PRINT 'Starting Schema Creation...';

-- Create schema [raw] if it does not exist
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'raw')
BEGIN
    PRINT 'Creating schema [raw]...';
    EXEC('CREATE SCHEMA raw');
    PRINT 'Schema [raw] created.';
END
ELSE
BEGIN
    PRINT 'Schema [raw] already exists.';
END
GO

-- Create schema [stg] if it does not exist
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')
BEGIN
    PRINT 'Creating schema [stg]...';
    EXEC('CREATE SCHEMA stg');
    PRINT 'Schema [stg] created.';
END
ELSE
BEGIN
    PRINT 'Schema [stg] already exists.';
END
GO

-- Create schema [prod] if it does not exist
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'prod')
BEGIN
    PRINT 'Creating schema [prod]...';
    EXEC('CREATE SCHEMA prod');
    PRINT 'Schema [prod] created.';
END
ELSE
BEGIN
    PRINT 'Schema [prod] already exists.';
END
GO

PRINT 'Schema creation script finished.';
GO