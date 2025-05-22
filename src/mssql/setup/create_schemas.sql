-- =========================================================================
-- Script name:   000_create_schemas.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Creates the necessary database schemas (raw, stg, prod).
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

-- Create schema [raw] if it does not exist
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'raw')
BEGIN
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
    EXEC('CREATE SCHEMA prod');
    PRINT 'Schema [prod] created.';
END
ELSE
BEGIN
    PRINT 'Schema [prod] already exists.';
END
GO

PRINT 'Schema creation completed.';
GO