<#
.SYNOPSIS
Loads cleaned MSSQL findings data from a CSV file into the raw SQL Server table.

.DESCRIPTION
This script reads cleaned finding data (from 006_clean_findings.ps1) and efficiently loads it 
into the target SQL database using SqlBulkCopy. It handles database connection, optional table 
truncation, and bulk data loading with proper column mapping.

.PARAMETER ConfigPath
Optional. Path to the YAML configuration file. 
Defaults to 'config.yaml' in the project root directory if omitted.

.PARAMETER Source
Mandatory. The source key within the config file (e.g., 'mssql').

.PARAMETER EnvType
Optional. Specifies the target environment type ('onprem' or 'azure'). 
Overrides the ENV_TYPE setting in the .env file for this run.
If omitted, uses the ENV_TYPE value from the .env file.

.PARAMETER AuthMethod
Optional. Specifies the authentication method.
Valid values depend on the effective EnvType:
- For 'onprem': 'windows' (Default).
- For 'azure': 'sql' (Default and Only Option for this script).
Defaults appropriately based on the effective EnvType.

.PARAMETER ServerInstance
Optional. Target server instance name. Overrides server from .env file.
If not specified, uses the corresponding env var based on effective EnvType.

.PARAMETER DatabaseName
Optional. Target database name. Overrides database from .env file.
If not specified, uses the corresponding env var based on effective EnvType.

.PARAMETER SqlLogin
Optional. Login name ONLY for -AuthMethod 'sql'. Overrides env var.

.PARAMETER SqlPassword
Optional. Password ONLY for -AuthMethod 'sql'. Overrides env var.

.EXAMPLE
# Load using default settings (reads ./config.yaml, .env for connection)
.\007_load_findings_to_sql.ps1 -Source mssql

.EXAMPLE
# Load using on-prem SQL Auth, specifying a non-default config file
.\007_load_findings_to_sql.ps1 -ConfigPath ".\config-alt.yaml" -Source mssql -EnvType onprem -AuthMethod sql

.EXAMPLE
# Load using Azure SQL Auth (overrides .env type if needed)
.\007_load_findings_to_sql.ps1 -ConfigPath .\config.yaml -Source mssql -EnvType azure -AuthMethod sql

.EXAMPLE
# Load using Azure SQL Auth, overriding server/db/creds
.\007_load_findings_to_sql.ps1 -ConfigPath .\config.yaml -Source mssql -EnvType azure -AuthMethod sql -ServerInstance "az.server" -DatabaseName "az.db" -SqlLogin "az_user" -SqlPassword "az_pass"

.NOTES
Author:      CloudWalker Defense LLC
Date:        2025-05-01
Dependencies: StoryzeUtils.psm1, SqlServer, powershell-yaml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,

    [Parameter(Mandatory=$true)]
    [string]$Source,

    # Optional: Override ENV_TYPE from .env file ('onprem' or 'azure')
    [Parameter(Mandatory=$false)]
    [ValidateSet('onprem', 'azure')] 
    [string]$EnvType,
    
    # Optional: Specify authentication method ('windows', 'sql')
    [Parameter(Mandatory=$false)]
    [ValidateSet('windows', 'sql')] 
    [string]$AuthMethod,
    
    # Optional: Override ServerInstance from .env file
    [Parameter(Mandatory=$false)]
    [string]$ServerInstance,

    # Optional: Override DatabaseName from .env file
    [Parameter(Mandatory=$false)]
    [string]$DatabaseName,

    # Login name (ONLY used for -AuthMethod 'sql')
    [Parameter(Mandatory=$false)]
    [string]$SqlLogin, 
    
    # Password (ONLY used for -AuthMethod 'sql')
    [Parameter(Mandatory=$false)]
    [string]$SqlPassword
)

# --- Minimal Bootstrapping to find and load StoryzeUtils --- 
$InitialLocation = $PSScriptRoot
$RepoRoot = $null
for ($i = 0; $i -lt 5; $i++) { # Search up to 5 levels up
    $UtilsPath = Join-Path $InitialLocation "StoryzeUtils.psm1"
    if (Test-Path $UtilsPath -PathType Leaf) {
        $RepoRoot = $InitialLocation
        try { Import-Module $UtilsPath -Force -ErrorAction Stop } catch { throw "Failed to import StoryzeUtils: $($_.Exception.Message)" }
        break
    }
    $ParentDir = Split-Path -Parent $InitialLocation; if ($ParentDir -eq $InitialLocation) { break }; $InitialLocation = $ParentDir
}
if (-not $RepoRoot) { throw "Could not find StoryzeUtils.psm1." }
$utilsModule = Get-Module -Name StoryzeUtils ; if (-not $utilsModule) { throw "Get-Module StoryzeUtils failed." }
Write-Verbose "Bootstrapped StoryzeUtils from: $($utilsModule.Path)"
$projectRoot = $utilsModule.ModuleBase
Write-Verbose "Project Root: $projectRoot"
# --- End Bootstrapping --- 

# --- Prepare Modules --- 
$scriptRequiredModules = @('SqlServer', 'powershell-yaml') # StoryzeUtils & yaml loaded by bootstrap/dependency if needed
$localModulesPath = Join-Path $projectRoot "Modules"
Initialize-RequiredModules -RequiredModules $scriptRequiredModules -LocalModulesBaseDir $localModulesPath

# --- Determine Effective Config Path --- 
if (-not $PSBoundParameters.ContainsKey('ConfigPath') -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $projectRoot "config.yaml"
    Write-Host "No -ConfigPath provided, defaulting to '$ConfigPath'" -ForegroundColor Yellow
} else {
    # Resolve provided path if it's relative (relative to current dir, NOT project root typically)
    # This ensures user-provided relative paths work as expected from where they run the script.
    try {
        $resolved = Resolve-Path -Path $ConfigPath -ErrorAction Stop
        $ConfigPath = $resolved.Path
        Write-Host "Using specified ConfigPath: $ConfigPath" -ForegroundColor Yellow
    } catch {
        throw "Failed to resolve provided -ConfigPath '$ConfigPath': $($_.Exception.Message)"
    }
}
# Validate the effective path exists
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Effective configuration file path not found: '$ConfigPath'. Verify the path or ensure config.yaml exists in project root."
}

# --- Load Environment Configuration from .env ---
Write-Host "Loading environment variables from .env file..." -ForegroundColor Cyan
Import-DotEnv

# --- Determine Effective Environment Type ---
$effectiveEnvType = $null
if ($PSBoundParameters.ContainsKey('EnvType')) {
    $effectiveEnvType = $EnvType.ToLower()
    Write-Host "Using Environment Type from -EnvType parameter: $effectiveEnvType" -ForegroundColor Yellow
} else {
    $effectiveEnvType = $env:ENV_TYPE.ToLower()
    if (-not $effectiveEnvType) {
        throw "Environment Type not specified via -EnvType parameter and ENV_TYPE is missing or empty in .env file."
    }
    Write-Host "Using Environment Type from .env file: $effectiveEnvType" -ForegroundColor Cyan
}
if ($effectiveEnvType -ne "onprem" -and $effectiveEnvType -ne "azure") {
    throw "Invalid effective Environment Type determined: '$effectiveEnvType'. Must be 'onprem' or 'azure'."
}

# --- Determine Target Server ---
$targetServer = $ServerInstance 
if (-not $targetServer) {
    if ($effectiveEnvType -eq "onprem") {
        $targetServer = $env:ONPREM_SERVER
        if (-not $targetServer) { throw "ServerInstance parameter not provided, and ONPREM_SERVER environment variable is missing or empty for ENV_TYPE=onprem." }
        Write-Host "Using server instance from ONPREM_SERVER environment variable: $targetServer" -ForegroundColor Green
    } elseif ($effectiveEnvType -eq "azure") {
        $targetServer = $env:AZURE_SERVER
        if (-not $targetServer) { throw "ServerInstance parameter not provided, and AZURE_SERVER environment variable is missing or empty for ENV_TYPE=azure." }
        Write-Host "Using server instance from AZURE_SERVER environment variable: $targetServer" -ForegroundColor Green
    }
} else {
    Write-Host "Using provided server instance parameter: $targetServer" -ForegroundColor Green
}

# --- Determine Target Database ---
$targetDatabase = $DatabaseName 
if (-not $targetDatabase) {
    if ($effectiveEnvType -eq "onprem") {
        $targetDatabase = $env:ONPREM_DATABASE
        if (-not $targetDatabase) { throw "DatabaseName parameter not provided, and ONPREM_DATABASE environment variable is missing or empty for ENV_TYPE=onprem." }
        Write-Host "Using database name from ONPREM_DATABASE environment variable: $targetDatabase" -ForegroundColor Green
    } elseif ($effectiveEnvType -eq "azure") {
        $targetDatabase = $env:AZURE_DATABASE
        if (-not $targetDatabase) { throw "DatabaseName parameter not provided, and AZURE_DATABASE environment variable is missing or empty for ENV_TYPE=azure." }
        Write-Host "Using database name from AZURE_DATABASE environment variable: $targetDatabase" -ForegroundColor Green
    }
} else {
    Write-Host "Using provided database name parameter: $targetDatabase" -ForegroundColor Green
}

# --- Determine Authentication Method and Credentials ---
$authMethodToUse = $AuthMethod
$username = $null
$password = $null

if (-not $authMethodToUse) {
    # Apply defaults based on environment
    if ($effectiveEnvType -eq "onprem") {
        $authMethodToUse = 'windows'
        Write-Host "No -AuthMethod specified for on-prem, defaulting to '$authMethodToUse'." -ForegroundColor Yellow
    } elseif ($effectiveEnvType -eq "azure") {
        $authMethodToUse = 'sql' # *** NEW DEFAULT FOR AZURE ***
        Write-Host "No -AuthMethod specified for Azure, defaulting to '$authMethodToUse'." -ForegroundColor Yellow
    }
} else {
    # Validation (remains the same, already restricts Azure to 'sql')
    if ($effectiveEnvType -eq "onprem" -and ($authMethodToUse -ne 'windows' -and $authMethodToUse -ne 'sql')) { throw "Invalid -AuthMethod '$authMethodToUse' for on-premises. Allowed: 'windows', 'sql'." }
    if ($effectiveEnvType -eq "azure" -and ($authMethodToUse -ne 'sql')) { throw "Invalid -AuthMethod '$authMethodToUse' for Azure environment with this script. Only 'sql' is supported." }
}

# Get credentials ONLY if using SQL Auth
if ($authMethodToUse -eq 'sql') {
    # Capture potential sources
    $paramLogin = $SqlLogin
    $paramPassword = $SqlPassword
    $envVarLogin = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SQL_LOGIN' } else { 'AZURE_SQL_LOGIN' } 
    $envLogin = Get-Content "env:\$envVarLogin" -ErrorAction SilentlyContinue
    $envVarPassword = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SQL_PASSWORD' } else { 'AZURE_SQL_PASSWORD' }
    $envPassword = Get-Content "env:\$envVarPassword" -ErrorAction SilentlyContinue

    # Determine final username (parameter > env var)
    $username = $paramLogin
    if (-not $username) {
        $username = $envLogin
        if (-not $username) { throw "SQL Auth requested but login not found. Provide -SqlLogin or set $envVarLogin in .env." }
        Write-Host "Using SQL login from environment ($envVarLogin): $username" -ForegroundColor Green
    } else {
        Write-Host "Using provided SQL login parameter: $username" -ForegroundColor Green
    }

    # Determine final password (parameter > env var)
    $password = $paramPassword
    if (-not $password) {
        $password = $envPassword
        if (-not $password) { throw "SQL Auth requested but password not found. Provide -SqlPassword or set $envVarPassword in .env." }
        Write-Host "Using SQL password from environment ($envVarPassword)." -ForegroundColor Green
        # Explicitly ensure param password is a clean string
        $password = [string]$password.Trim()
    } else {
        Write-Host "Using provided SQL password parameter." -ForegroundColor Green
        # Explicitly ensure param password is a clean string
        $password = [string]$password.Trim()
    }
}

# --- Build Connection String --- 
$connectionString = $null
switch ("$effectiveEnvType/$authMethodToUse") { 
    "onprem/windows" {
        $connectionString = "Server=$targetServer;Database=$targetDatabase;Integrated Security=True;TrustServerCertificate=True"
        Write-Host "Using Windows Integrated Authentication (On-Premises)" -ForegroundColor Cyan
    }
    "onprem/sql" {
        # Escape single quotes in password for connection string safety
        $safePassword = $password -replace "'", "''"
        # Password value should NOT be enclosed in single quotes for SqlConnection
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;TrustServerCertificate=True"
        Write-Host "Using SQL Server Authentication (On-Premises) for login: $username" -ForegroundColor Cyan
    }
    "azure/sql" {
        # Escape single quotes in password for connection string safety
        $safePassword = $password -replace "'", "''"
        # Password value should NOT be enclosed in single quotes for SqlConnection
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;Encrypt=True;TrustServerCertificate=True;Integrated Security=False"
        Write-Host "Using Azure SQL Authentication for login: $username" -ForegroundColor Cyan
    }
    default {
        # Should only be hit if validation above failed somehow
        throw "Invalid combination of environment type ('$effectiveEnvType') and auth method ('$authMethodToUse') encountered."
    }
}
if (-not $connectionString) { throw "Internal error: Failed to build connection string." }

# --- Main Script Execution (Load CSV to SQL) ---
$scriptStartTime = Get-Date
Write-Host ("=" * 80)
Write-Host "Starting Script: $($MyInvocation.MyCommand.Name) at $scriptStartTime" -ForegroundColor Yellow
Write-Host ("Script to load cleaned findings from CSV to SQL Raw Table using Bulk Copy.")
Write-Host ("=" * 80)

# Initialize variables used in finally block
$conn = $null
$bulkCopy = $null
$dataTable = $null
$transaction = $null
$cmd = $null

try {
    # --- Configuration Loading ---
    Write-Host "Loading configuration from '$ConfigPath' for source '$Source'..." -ForegroundColor Cyan
    $fullConfig = Import-YamlConfiguration -Path $ConfigPath
    # Ensure global settings exist
    if ($null -eq $fullConfig.global_settings) {
        throw "Configuration file '$ConfigPath' is missing the required 'global_settings' section."
    }
    $globalSettings = $fullConfig.global_settings

    $sourceConfig = $null
    if ($fullConfig.sources -is [hashtable] -and $fullConfig.sources.ContainsKey($Source)) {
        $sourceConfig = $fullConfig.sources[$Source]
    } else {
        $availableSources = if ($fullConfig.sources -is [hashtable]) { $fullConfig.sources.Keys -join ', ' } else { 'None found' }
        throw "Source '$Source' not found in configuration file '$ConfigPath'. Available sources: $availableSources"
    }

    # --- Get Input CSV Path ---
    $inputCsvPathStr = $sourceConfig.csv_clean_file
    if ([string]::IsNullOrWhiteSpace($inputCsvPathStr)) {
        throw "Configuration key 'csv_clean_file' is missing or empty for source '$Source'."
    }
    Write-Host "Attempting to use Input Clean CSV: '$inputCsvPathStr'" -ForegroundColor Cyan
    $csvFileInfo = Resolve-Path -Path $inputCsvPathStr -ErrorAction SilentlyContinue
    if (-not $csvFileInfo) { throw "Input CSV file not found at path specified in config ('csv_clean_file'): '$inputCsvPathStr'" }
    Write-Host "Successfully resolved Input Clean CSV: $($csvFileInfo.Path)"

    # --- Get Target Table Info & Truncate Setting ---
    $rawSchema = $sourceConfig.raw_schema
    $rawTable = $sourceConfig.raw_table
    if ([string]::IsNullOrWhiteSpace($rawSchema) -or [string]::IsNullOrWhiteSpace($rawTable)) {
        throw "Configuration keys 'raw_schema' and 'raw_table' are required for source '$Source' but are missing or empty."
    }
    $targetTableFull = "[$rawSchema].[$rawTable]"
    Write-Host "Target Raw Table: $targetTableFull"

    # Check truncate setting from config
    $shouldTruncate = $true # Default to true
    if ($sourceConfig.ContainsKey('truncate_raw')) {
        try {
            $shouldTruncate = [bool]::Parse($sourceConfig.truncate_raw)
        } catch {
            Write-Warning "Invalid value '($($sourceConfig.truncate_raw))' for 'truncate_raw' in config. Expected 'true' or 'false'. Defaulting to true."
            $shouldTruncate = $true
        }
    }
    Write-Host "Truncate Target Table Before Load: $shouldTruncate (from config 'truncate_raw', defaults to true)"

    # --- Read CSV Data (using Import-Csv) ---
    Write-Host "Reading cleaned data from CSV file '$($csvFileInfo.Path)'..."
    $stopwatchReadCsv = [System.Diagnostics.Stopwatch]::StartNew()

    $csvData = Import-Csv -Path $csvFileInfo.Path
    $rowCount = $csvData.Count # Assuming $csvData is an array or countable collection
    Write-Host "Read $rowCount rows using Import-Csv." -ForegroundColor Green

    if ($rowCount -eq 0) {
        Write-Warning "CSV file '$($csvFileInfo.Path)' contained no data rows. No data to load."
        exit 0
    }

    # --- Database Operations (Using determined Connection String) --- 
    $stopwatchDb = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Establishing database connection to [$targetServer]..."
    $connectTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_connect_timeout' -DefaultValue 30
    $effectiveConnectionString = $connectionString + "Connection Timeout=$connectTimeout;"
    Write-Verbose "Effective Connection String (Password Redacted): $(($effectiveConnectionString -replace 'Password=[^;]+;', 'Password=********;') )"
    
    $conn = New-Object System.Data.SqlClient.SqlConnection($effectiveConnectionString)
    $conn.Open()
    Write-Host "Database connection successful." -ForegroundColor Green

    # Begin transaction for atomicity (especially needed if truncating)
    Write-Host "Beginning SQL transaction..."
    $transaction = $conn.BeginTransaction("LoadRawData")
    $cmd = $conn.CreateCommand()
    $cmd.Transaction = $transaction

    # --- Optional Table Truncation --- 
    if ($shouldTruncate) {
        Write-Host "Attempting to truncate target table: $targetTableFull..."
        $stopwatchTruncate = [System.Diagnostics.Stopwatch]::StartNew()
        $cmd.CommandText = "TRUNCATE TABLE $targetTableFull;"
        $cmd.CommandTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_command_timeout' -DefaultValue 300 # Use a generous timeout for truncate
        $cmd.ExecuteNonQuery() | Out-Null # Returns -1 for TRUNCATE
        $stopwatchTruncate.Stop()
        Write-Host "Target table truncated successfully in $($stopwatchTruncate.Elapsed.TotalSeconds.ToString('F2')) seconds." -ForegroundColor Green
    }

    # --- Analyze Target Table Schema (Required for mapping) --- 
    Write-Host "Analyzing schema of target table: $targetTableFull..."
    # Fetch column names exactly as they are in SQL, also get lowercase for comparison
    $schemaSql = @"
SELECT 
    c.name AS column_name,
    LOWER(c.name) AS column_name_lower,
    c.is_identity
FROM sys.columns c 
WHERE c.object_id = OBJECT_ID(@TargetTable)
ORDER BY c.column_id;
"@
    $cmd.CommandText = $schemaSql
    $cmd.Parameters.Clear()
    $cmd.Parameters.AddWithValue("@TargetTable", "$rawSchema.$rawTable") | Out-Null
    $cmd.CommandTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_command_timeout' -DefaultValue 300

    # Store mapping: Lowercase name -> Actual SQL Name
    $tableSchemaColumns = @{}
    $identityColumnsLower = [System.Collections.Generic.List[string]]::new()
    $schemaReader = $null
    try {
        $schemaReader = $cmd.ExecuteReader()
        while ($schemaReader.Read()) {
            $colNameActual = $schemaReader["column_name"]
            $colNameLower = $schemaReader["column_name_lower"]
            $isIdentity = [bool]$schemaReader["is_identity"]
            $tableSchemaColumns[$colNameLower] = $colNameActual
            if ($isIdentity) {
                $identityColumnsLower.Add($colNameLower)
            }
        }
    } finally {
        if ($null -ne $schemaReader) { $schemaReader.Close() }
    }

    if ($tableSchemaColumns.Count -eq 0) {
        throw "Could not retrieve schema for target table '$targetTableFull'. Does the table exist and have columns?"
    }
    Write-Verbose "Target table schema analyzed. $($tableSchemaColumns.Count) columns found."
    if ($identityColumnsLower.Count -gt 0) {
        Write-Verbose "Identity columns detected (will be skipped in mapping, lowercase): $($identityColumnsLower -join ', ')"
    } else {
        Write-Verbose "No identity columns detected in target table."
    }

    # --- Populate DataTable & Prepare Bulk Copy ---
    # Add columns to DataTable based ONLY on CSV Headers whose lowercase version exists 
    # in the target table AND are NOT identity columns
    $dataTable = New-Object System.Data.DataTable
    $csvHeaders = $csvData[0].PSObject.Properties | Select-Object -ExpandProperty Name
    $validCsvHeadersMap = @{} # Map CSV Header (original case) -> Actual SQL Column Name

    # Define DataTable Columns based on valid mappings
    foreach ($header in $csvHeaders) {
        $headerLower = $header.ToLower()
        if ($tableSchemaColumns.ContainsKey($headerLower) -and (-not ($identityColumnsLower.Contains($headerLower)))) { # Check if exists in SQL schema and is NOT identity
            $actualSqlColName = $tableSchemaColumns[$headerLower]
            $dataTable.Columns.Add($header, [string]) | Out-Null # Add column using CSV header's original case
            $validCsvHeadersMap[$header] = $actualSqlColName
        }
    }
    if ($validCsvHeadersMap.Count -eq 0) {
        throw "No matching columns found between CSV headers and non-identity columns in target table '$targetTableFull'. Cannot load data."
    }
    Write-Verbose "DataTable structure created for Bulk Copy with columns: $($dataTable.Columns.ColumnName -join ', ')"

    # Populate DataTable from the imported CSV data ($csvData), only using valid columns
    $stopwatchDataPrep = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($row in $csvData) {
        $dataRow = $dataTable.NewRow()
        # Populate only the columns that exist in the DataTable (which are the valid, mapped columns)
        foreach ($header in $dataTable.Columns.ColumnName) {
            $value = $row.$header # Assumes CSV header matches DataTable column name
            $dataRow[$header] = if ([string]::IsNullOrEmpty($value)) { [System.DBNull]::Value } else { $value }
        }
        $dataTable.Rows.Add($dataRow)
    }
    $stopwatchDataPrep.Stop()
    Write-Host "Prepared $($dataTable.Rows.Count) data rows into DataTable in $($stopwatchDataPrep.Elapsed.TotalSeconds.ToString('F2')) seconds." -ForegroundColor Green

    # SqlBulkCopy Setup
    Write-Host "Performing bulk copy into $targetTableFull..."
    $bulkCopyOptions = [System.Data.SqlClient.SqlBulkCopyOptions]::Default # Use TableLock if load is exclusive
    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($conn, $bulkCopyOptions, $transaction) 
    $bulkCopy.DestinationTableName = $targetTableFull

    $bulkCopy.BatchSize = Get-SafeTimeoutValue -Settings $globalSettings -Key 'batch_size_bulk_load' -DefaultValue 5000
    $bulkCopy.BulkCopyTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_cmd_timeout_bulk_copy' -DefaultValue 600 

    Write-Host "SqlBulkCopy Settings - BatchSize: $($bulkCopy.BatchSize), Timeout: $($bulkCopy.BulkCopyTimeout) seconds"

    # Map columns - Map the DataTable column (which now only contains valid columns) 
    # to the actual SQL column name (preserving SQL casing)
    $bulkCopy.ColumnMappings.Clear() 
    foreach($dtColumnName in $dataTable.Columns.ColumnName) {
        $actualSqlColName = $validCsvHeadersMap[$dtColumnName] # Get the corresponding actual SQL column name
        if (-not [string]::IsNullOrEmpty($actualSqlColName)) {
            $bulkCopy.ColumnMappings.Add($dtColumnName, $actualSqlColName) | Out-Null
        }
    }
    Write-Verbose "SqlBulkCopy Mappings Configured (Source CSV Header -> Destination SQL Column):"
    $bulkCopy.ColumnMappings | ForEach-Object { Write-Verbose "  $($_.SourceColumn) -> $($_.DestinationColumn)" }

    # Execute bulk copy
    $bulkCopy.WriteToServer($dataTable)
    Write-Host "Bulk copy completed successfully. $($dataTable.Rows.Count) rows loaded." -ForegroundColor Green

    # Commit transaction
    Write-Host "Committing transaction..."
    $transaction.Commit()
    Write-Host "Transaction committed." -ForegroundColor Green

    $stopwatchDb.Stop()
    Write-Host "Total database operation time: $($stopwatchDb.Elapsed.TotalSeconds.ToString('F2')) seconds."

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Error "Script execution failed at line $($_.InvocationInfo.ScriptLineNumber)."
    Write-Error ($_.ScriptStackTrace) # Log stack trace for debugging

    # Attempt to rollback transaction
    if ($null -ne $transaction -and $null -ne $conn -and $conn.State -eq [System.Data.ConnectionState]::Open) {
       try {
           Write-Warning "Attempting to roll back transaction..."
           $transaction.Rollback()
           Write-Warning "Transaction rolled back."
       } catch { Write-Error "Failed to roll back transaction: $($_.Exception.Message)" }
    }

    # Ensure script exits with non-zero code on failure
    exit 1
} finally {
    # --- Resource Cleanup ---
    Write-Verbose "Performing resource cleanup..."
    if ($null -ne $cmd) { try { $cmd.Dispose() } catch { Write-Warning "Error disposing command object: $($_.Exception.Message)" } }
    if ($null -ne $bulkCopy) { try { $bulkCopy.Close() } catch { Write-Warning "Error closing bulk copy object: $($_.Exception.Message)" } }
    if ($null -ne $dataTable) { try { $dataTable.Dispose() } catch { Write-Warning "Error disposing data table: $($_.Exception.Message)" } }
    if ($null -ne $transaction) { try { $transaction.Dispose() } catch { Write-Warning "Error disposing transaction object: $($_.Exception.Message)" } }
    if ($null -ne $conn -and $conn.State -ne [System.Data.ConnectionState]::Closed) {
        try {
            $conn.Close()
            Write-Verbose "Database connection closed."
        } catch { Write-Warning "Error closing database connection: $($_.Exception.Message)" }
    }
}

$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime
Write-Host ("=" * 80)
Write-Host "Script Finished: $($MyInvocation.MyCommand.Name) at $scriptEndTime" -ForegroundColor Yellow
Write-Host "Total script duration: $($scriptDuration.TotalSeconds.ToString('F2')) seconds."
Write-Host ("=" * 80) 