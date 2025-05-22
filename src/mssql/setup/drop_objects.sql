-- filepath: d:\cwd-projects\storyze\src\mssql\setup\drop_objects.sql
-- =========================================================================
-- Script name:   drop_objects.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Ensures clean installation by dropping all database objects
-- Purpose:       Provides idempotent setup by removing existing objects before creation
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

-- Drop view if exists
IF OBJECT_ID('prod.vw_mssql_findings', 'V') IS NOT NULL
    DROP VIEW prod.vw_mssql_findings;
GO

-- Drop tables if exist
IF OBJECT_ID('prod.mssql_findings', 'U') IS NOT NULL
    DROP TABLE prod.mssql_findings;
GO
IF OBJECT_ID('prod.mssql_objects_map', 'U') IS NOT NULL
    DROP TABLE prod.mssql_objects_map;
GO
IF OBJECT_ID('stg.mssql_findings', 'U') IS NOT NULL
    DROP TABLE stg.mssql_findings;
GO
IF OBJECT_ID('raw.mssql_findings', 'U') IS NOT NULL
    DROP TABLE raw.mssql_findings;
GO

-- Drop schemas if exist (after all objects in them are dropped)
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'prod')
    DROP SCHEMA prod;
GO
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')
    DROP SCHEMA stg;
GO
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'raw')
    DROP SCHEMA raw;
GO
