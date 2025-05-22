-- =========================================================================
-- Script name:   004_insert_data_staging.sql
-- Author:        CloudWalker Defense LLC
-- Description:   Transforms raw assessment data by normalizing object names,
--                splitting multi-value fields, and linking to mapped objects.
-- Purpose:       Critical data preparation step that converts raw findings
--                into a structured format suitable for analysis and reporting.
-- License:       MIT License - Copyright (c) 2025 CloudWalker Defense LLC
-- =========================================================================

-- =========================================================================
-- !! IMPORTANT CONFIGURATION !!
-- Update the @DomainSuffixToReplace variable below to match the domain suffix
-- specified in your config.yaml (global_settings.domain_suffix).
-- Include the leading dot (e.g., '.yourdomain.com').
-- =========================================================================
DECLARE @DomainSuffixToReplace NVARCHAR(255) = '.XYZ.DOM.MBC'; -- <<< CHANGE THIS VALUE
-- =========================================================================

DECLARE @UnknownMapId INT;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Step 0: Get the 'Unknown' ID from the map table
    SELECT @UnknownMapId = [mssql_object_map_id] FROM [prod].[mssql_objects_map] WHERE [object_name] = 'Unknown';
    IF @UnknownMapId IS NULL THROW 50001, 'CRITICAL ERROR: ''Unknown'' entry not found in [prod].[mssql_objects_map].', 1;

    -- Step 1: Truncate Staging table for a fresh load
    TRUNCATE TABLE [stg].[mssql_findings];
    PRINT 'Staging table truncated.';

    -- Step 2: Insert data from Raw, splitting multi-value fields correctly
    WITH SplitTargetsCTE AS (
        -- First, split the Affected Targets column
        SELECT raw.[raw_mssql_finding_id], LTRIM(RTRIM(split_target.value)) AS single_target
        FROM [raw].[mssql_findings] AS raw
        CROSS APPLY STRING_SPLIT(ISNULL(raw.[Affected Targets],''), ';') AS split_target
        WHERE LTRIM(RTRIM(split_target.value)) <> '' -- Exclude empty targets after split
    )
    -- Now insert into staging, joining the split targets and splitting categories
    INSERT INTO [stg].[mssql_findings] ( [raw_mssql_finding_id], [normalized_object], [impacted_objects], [finding_category], [risk_level], [finding_name] )
    SELECT
        st.[raw_mssql_finding_id],
        st.single_target, -- Use the already split target for normalization
        st.single_target, -- ALSO use the split target for the impacted_objects column
        LTRIM(RTRIM(split_category.value)), -- Split the category here
        raw.[Severity],
        raw.[Issue Name]
    FROM SplitTargetsCTE AS st
    INNER JOIN [raw].[mssql_findings] AS raw ON st.[raw_mssql_finding_id] = raw.[raw_mssql_finding_id]
    CROSS APPLY STRING_SPLIT(ISNULL(raw.[Category],''), ';') AS split_category
    WHERE LTRIM(RTRIM(split_category.value)) <> ''; -- Exclude empty categories after split
    
    PRINT 'Inserted ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows into staging (after splitting targets and categories).';

    -- Step 3: Normalize [normalized_object] IN PLACE using sequential UPDATEs
    -- NOTE: Multiple sequential UPDATEs can impact performance on very large datasets.
    -- Consider combining steps or performing normalization during the initial INSERT if performance is critical.

    -- 3a: Initial Trim
    UPDATE [stg].[mssql_findings] SET [normalized_object] = LTRIM(RTRIM(ISNULL([normalized_object],'')));

    -- 3b: Handle ':' - Keep part before (Assume Server:Database)
    UPDATE [stg].[mssql_findings] SET [normalized_object] = LTRIM(RTRIM(LEFT([normalized_object], CHARINDEX(':', [normalized_object]) - 1)))
    WHERE [normalized_object] IS NOT NULL AND CHARINDEX(':', [normalized_object]) > 0 AND NOT (LEN([normalized_object]) > 1 AND SUBSTRING([normalized_object], 2, 1) = ':');

    -- 3c: Handle '\' - Keep part before (Assume Server\Path)
    UPDATE [stg].[mssql_findings] SET [normalized_object] = LTRIM(RTRIM(LEFT([normalized_object], CHARINDEX('\', [normalized_object]) - 1)))
    WHERE [normalized_object] IS NOT NULL AND CHARINDEX('\', [normalized_object]) > 0;

    -- 3d: Handle specific Domain Suffix using the @DomainSuffixToReplace variable declared above
    IF @DomainSuffixToReplace <> '' AND @DomainSuffixToReplace IS NOT NULL
    BEGIN
        UPDATE [stg].[mssql_findings]
        SET [normalized_object] = LTRIM(RTRIM(REPLACE([normalized_object], @DomainSuffixToReplace, '')))
        WHERE [normalized_object] LIKE '%' + @DomainSuffixToReplace; -- Apply only if the specific suffix exists at the end
        PRINT 'Domain suffix removal applied to ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows.';
    END

    -- 3e: Final Trim & Uppercase
    UPDATE [stg].[mssql_findings] SET [normalized_object] = UPPER(LTRIM(RTRIM(ISNULL([normalized_object],''))));

    -- 3f: NULLify entries that are NOT valid server names after cleaning
    UPDATE stg SET stg.[normalized_object] = NULL
    FROM [stg].[mssql_findings] AS stg
    WHERE stg.[normalized_object] IS NOT NULL
      AND (
            -- Condition 1: Object does NOT exist in the map table
            NOT EXISTS (
                SELECT 1
                FROM [prod].[mssql_objects_map] map
                WHERE map.[object_name] = stg.[normalized_object] -- Assumes both are UPPERCASE from previous step
            )
            -- Condition 2: OR Object fails other validation checks
            OR PATINDEX('%[^A-Z0-9-]%', stg.[normalized_object]) > 0 -- Invalid Chars (expects UPPERCASE now)
            OR (UPPER(stg.[normalized_object]) LIKE '%DB' AND UPPER(stg.[normalized_object]) NOT LIKE '%DBL') -- Looks like DB name (heuristic)
            OR LEN(stg.[normalized_object]) < 3
            OR stg.[normalized_object] = ''
          );
    PRINT 'Nullified ' + CAST(@@ROWCOUNT AS VARCHAR) + ' invalid objects.';

    -- Step 4: Delete rows where normalized_object IS NULL (non-server items)
    DELETE FROM [stg].[mssql_findings] WHERE [normalized_object] IS NULL;
    PRINT 'Deleted ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows with NULL normalized_object.';

    -- Step 5: Link remaining rows (which should be servers) to Map Table ID
    UPDATE stg SET stg.[mssql_object_map_id] = ISNULL(map.[mssql_object_map_id], @UnknownMapId)
    FROM [stg].[mssql_findings] AS stg
    LEFT JOIN [prod].[mssql_objects_map] AS map ON stg.[normalized_object] = map.[object_name] -- Assumes both UPPER
    WHERE stg.[mssql_object_map_id] IS NULL;
    PRINT 'Linked ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows to map IDs.';

    -- Step 6: Deduplicate based on key combination AFTER linking
    WITH RowNumCTE AS (
        SELECT ROW_NUMBER() OVER( PARTITION BY [raw_mssql_finding_id], [mssql_object_map_id], [finding_name], [finding_category] ORDER BY [stg_mssql_finding_id]) as rn
        FROM [stg].[mssql_findings]
    )
    DELETE FROM RowNumCTE WHERE rn > 1;
    PRINT 'Deduplicated ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows.';

    COMMIT TRANSACTION;
    PRINT 'Staging table processing complete.';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'ERROR: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
GO
