<#
.SYNOPSIS
Updates the staging findings table with sample tracking data from a CSV file.

.DESCRIPTION
Reads sample tracking data (LOE, assigned_to, dates, etc.) from a CSV file.
Connects to the target SQL database using provided parameters or .env variables.
Loads the CSV data into a temporary table and performs a bulk UPDATE on the staging table.
Synchronizes the 'fixed' flag based on the 'end_date' column.
Uses a single transaction for atomicity.

.PARAMETER ConfigPath
Optional. Path to the YAML configuration file. Defaults to 'config.yaml' in the project root.

.PARAMETER Source
Mandatory. The source key within the config file (e.g., 'mssql').

.PARAMETER EnvType
Optional. Specifies the target environment type ('onprem' or 'azure'). Overrides ENV_TYPE from .env.

.PARAMETER AuthMethod
Optional. Specifies the authentication method ('windows' or 'sql'). Defaults based on EnvType.

.PARAMETER ServerInstance
Optional. Target server instance name. Overrides server from .env file.

.PARAMETER DatabaseName
Optional. Target database name. Overrides database from .env file.

.PARAMETER SqlLogin
Optional. Login name (used only for -AuthMethod 'sql'). Overrides env var.

.PARAMETER SqlPassword
Optional. Password (used only for -AuthMethod 'sql'). Overrides env var.

.PARAMETER SampleDataPath
Optional. Explicit path to the sample data CSV file. Overrides 'data_sample_file' from config.yaml.

.EXAMPLE
# Load sample data using default settings (reads ./config.yaml, .env for connection)
.\011_mssql_load_sample_data.ps1 -Source mssql

.EXAMPLE
# Load sample data using Azure SQL Auth and specifying both CSV and Config paths
.\011_mssql_load_sample_data.ps1 -ConfigPath ".\config-alt.yaml" -Source mssql -EnvType azure -AuthMethod sql -SampleDataPath ".\data\mssql_sample_updates.csv"

.EXAMPLE
# Load sample data using explicit on-prem SQL Auth
.\011_mssql_load_sample_data.ps1 -ConfigPath .\config.yaml -Source mssql -EnvType onprem -AuthMethod sql

.EXAMPLE
# Load sample data using Azure SQL Auth (overrides .env type if needed)
.\011_mssql_load_sample_data.ps1 -ConfigPath .\config.yaml -Source mssql -EnvType azure -AuthMethod sql

.EXAMPLE
# Load sample data using Azure SQL Auth and specifying CSV path
.\011_mssql_load_sample_data.ps1 -ConfigPath .\config.yaml -Source mssql -EnvType azure -AuthMethod sql -SampleDataPath ".\data\mssql_sample_updates.csv"

.NOTES
Author:      CloudWalker Defense LLC
Date:        2025-05-01
License:     MIT License
Dependencies: StoryzeUtils.psm1, SqlServer, powershell-yaml
#>

[CmdletBinding()]
param(
    # Optional: Path to the config file (defaults to ./config.yaml)
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,

    # Mandatory: Source key in config.yaml (e.g., 'mssql')
    [Parameter(Mandatory=$true)]
    [string]$Source,

    # Optional: Override ENV_TYPE from .env file ('onprem' or 'azure')
    [Parameter(Mandatory=$false)]
    [ValidateSet('onprem', 'azure')] 
    [string]$EnvType,
    
    # Optional: Specify authentication method ('windows' or 'sql')
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
    [string]$SqlPassword,

    # Optional: Explicit path to sample data CSV (overrides config)
    [Parameter(HelpMessage="Optional path to the sample data CSV file. Overrides 'data_sample_file' from config.")]
    [string]$SampleDataPath 
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
$scriptRequiredModules = @('powershell-yaml', 'SqlServer') 
$localModulesPath = Join-Path $projectRoot "Modules"
Initialize-RequiredModules -RequiredModules $scriptRequiredModules -LocalModulesBaseDir $localModulesPath

# --- Determine Effective Config Path --- 
if (-not $PSBoundParameters.ContainsKey('ConfigPath') -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $projectRoot "config.yaml"
    Write-Host "No -ConfigPath provided, defaulting to '$ConfigPath'" -ForegroundColor Yellow
} else {
    try {
        $resolved = Resolve-Path -Path $ConfigPath -ErrorAction Stop
        $ConfigPath = $resolved.Path
        Write-Host "Using specified ConfigPath: $ConfigPath" -ForegroundColor Yellow
    } catch {
        throw "Failed to resolve provided -ConfigPath '$ConfigPath': $($_.Exception.Message)"
    }
}
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Effective configuration file path not found: '$ConfigPath'. Verify the path or ensure config.yaml exists in project root."
}

# --- Load Environment Configuration from .env ---
Write-Host "Loading environment variables from .env file..." -ForegroundColor Cyan
Import-DotEnv

# --- Determine Effective Environment Type --- 
$effectiveEnvType = $null
if ($PSBoundParameters.ContainsKey('EnvType')) { $effectiveEnvType = $EnvType.ToLower(); Write-Host "Using EnvType from parameter: $effectiveEnvType" -FG Yellow } else { $effectiveEnvType = $env:ENV_TYPE.ToLower(); if (-not $effectiveEnvType) { throw "EnvType missing (-EnvType or ENV_TYPE in .env)." }; Write-Host "Using EnvType from .env: $effectiveEnvType" -FG Cyan }
if ($effectiveEnvType -ne "onprem" -and $effectiveEnvType -ne "azure") { throw "Invalid effective EnvType: '$effectiveEnvType'." }

# --- Determine Target Server ---
$targetServer = $ServerInstance 
if (-not $targetServer) { 
    $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SERVER' } else { 'AZURE_SERVER' } 
    $targetServer = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue # Use Get-Content
    if (-not $targetServer) { throw "Server missing (-ServerInstance or $envVar)." } 
    Write-Host "Using server from $envVar : $targetServer" -FG Green 
} else { Write-Host "Using -ServerInstance: $targetServer" -FG Green }

# --- Determine Target Database ---
$targetDatabase = $DatabaseName 
if (-not $targetDatabase) { 
    $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_DATABASE' } else { 'AZURE_DATABASE' } 
    $targetDatabase = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue # Use Get-Content
    if (-not $targetDatabase) { throw "Database missing (-DatabaseName or $envVar)." } 
    Write-Host "Using database from $envVar : $targetDatabase" -FG Green 
} else { Write-Host "Using -DatabaseName: $targetDatabase" -FG Green }

# --- Determine Authentication Method and Credentials ---
$authMethodToUse = $AuthMethod
$username = $null; $password = $null; # $userEmail = $null REMOVED
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
    # Validation
    if ($effectiveEnvType -eq "onprem" -and ($authMethodToUse -ne 'windows' -and $authMethodToUse -ne 'sql')) { throw "Invalid -AuthMethod '$authMethodToUse' for on-prem." }
    if ($effectiveEnvType -eq "azure" -and ($authMethodToUse -ne 'sql')) { throw "Invalid -AuthMethod '$authMethodToUse' for Azure. Only 'sql' is supported." }
}
# Get credentials ONLY if using SQL Auth
if ($authMethodToUse -eq 'sql') { 
    $username = $SqlLogin
    if (-not $username) { 
        $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SQL_LOGIN' } else { 'AZURE_SQL_LOGIN' } 
        $username = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue # Use Get-Content
        if (-not $username) { throw "SQL Auth: Login missing (-SqlLogin or $envVar)." } 
        Write-Host "Using SQL login from $envVar : $username" -FG Green 
    } else { Write-Host "Using -SqlLogin: $username" -FG Green } 
    $password = $SqlPassword
    if (-not $password) { 
        $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SQL_PASSWORD' } else { 'AZURE_SQL_PASSWORD' } 
        $password = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue # Use Get-Content
        if (-not $password) { throw "SQL Auth: Password missing (-SqlPassword or $envVar)." } 
        Write-Host "Using SQL pwd from $envVar." -FG Green 
    } else { Write-Host "Using -SqlPassword." -FG Green } 
}

# --- Build Connection String --- 
$connectionString = $null
switch ("$effectiveEnvType/$authMethodToUse") { 
    "onprem/windows"   { $connectionString = "Server=$targetServer;Database=$targetDatabase;Integrated Security=True;TrustServerCertificate=True"; Write-Host "Auth: Windows Auth (On-Prem)" -FG Cyan } 
    "onprem/sql"       { 
        # Escape single quotes in password for connection string safety
        $safePassword = $password -replace "'", "''"
        # Password value should NOT be enclosed in single quotes for SqlConnection
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;TrustServerCertificate=True"; 
        Write-Host "Auth: SQL Auth (On-Prem): $username" -FG Cyan 
    }
    "azure/sql"        { 
        # Escape single quotes in password for connection string safety
        $safePassword = $password -replace "'", "''"
        # Password value should NOT be enclosed in single quotes for SqlConnection
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;Encrypt=True;TrustServerCertificate=True;Integrated Security=False"; 
        Write-Host "Auth: SQL Auth (Azure): $username" -FG Cyan 
    }
    default            { throw "Invalid EnvType/AuthMethod combination." }
}
if (-not $connectionString) { throw "Internal error: Failed to build connection string." }

# --- Main Script Execution --- 
$scriptStartTime = Get-Date
Write-Host ("=" * 80)
Write-Host "Starting Script: $($MyInvocation.MyCommand.Name) at $scriptStartTime" -ForegroundColor Yellow
Write-Host ("Script to update staging table with sample tracking data using Temp Table + Bulk Update.")
Write-Host ("=" * 80)

$conn = $null
$transaction = $null
$bulkCopy = $null
$dataTable = $null
$cmd = $null # Reusable command object

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

    # --- Determine Input CSV File Path (Parameter > Config) ---
    $effectiveCsvPathStr = $null
    $pathSource = "<Not Set>"

    # 1. Prioritize config file key 'data_sample_file'
    if ($sourceConfig.ContainsKey('data_sample_file') -and (-not [string]::IsNullOrWhiteSpace($sourceConfig.data_sample_file))) {
        $effectiveCsvPathStr = $sourceConfig.data_sample_file
        $pathSource = "Config ('data_sample_file')"
        Write-Verbose "Using sample CSV path from config key 'data_sample_file'"
    }
    # 2. Fallback to -SampleDataPath parameter ONLY if config key is missing/empty
    elseif ($PSBoundParameters.ContainsKey('SampleDataPath') -and (-not [string]::IsNullOrWhiteSpace($SampleDataPath))) {
        $effectiveCsvPathStr = $SampleDataPath
        $pathSource = "Parameter (-SampleDataPath)"
        Write-Warning "Sample data CSV path not found in config key 'data_sample_file'. Using path from -SampleDataPath parameter instead."
    }
    # 3. Fail if neither is provided
    else {
        throw "Sample data CSV path must be specified. Provide it either in config.yaml (key: 'data_sample_file' for source '$Source') or using the -SampleDataPath parameter."
    }
    
    # Resolve the determined path and ensure the file exists
    Write-Host "Attempting to use Sample Data CSV from $pathSource : '$effectiveCsvPathStr'" -ForegroundColor Cyan
    $csvFileInfo = Resolve-Path -Path $effectiveCsvPathStr -ErrorAction SilentlyContinue
    if (-not $csvFileInfo) { throw "Sample data CSV file not found at the path specified ($pathSource): '$effectiveCsvPathStr'" }
    Write-Host "Successfully resolved Sample Data CSV: $($csvFileInfo.Path)" 

    # --- Read CSV Data ---
    Write-Host "Reading sample data from CSV file..."
    # Note: Import-Csv loads the entire file into memory. Fine for moderate sample files.
    $csvData = Import-Csv -Path $csvFileInfo.Path 
    $rowCount = $csvData.Count
    Write-Host "Read $rowCount rows from CSV." -ForegroundColor Green
    if ($rowCount -eq 0) { 
        Write-Warning "CSV file is empty. No updates to perform."
        exit 0
    }

    # --- Get Key Column Name and Validate Header ---
    $keyColumnName = $sourceConfig.sample_data_key_column | Get-ValueOrDefault -Default 'finding_object_id'
    if ([string]::IsNullOrWhiteSpace($keyColumnName)) {
        Write-Warning "Config key 'sample_data_key_column' is empty. Defaulting to 'finding_object_id'."
        $keyColumnName = 'finding_object_id'
    }
    Write-Verbose "Using Sample Data Key Column: '$keyColumnName'"

    $csvHeaders = $csvData[0].PSObject.Properties | Select-Object -ExpandProperty Name
    if (-not ($csvHeaders -contains $keyColumnName)) {
        throw "Required key column '$keyColumnName' (from config 'sample_data_key_column' or default) not found in the CSV header. Cannot perform updates."
    }
    # Identify columns to update based on CSV headers (case-insensitive check against expected fields)
    $updateColumns = @{
        "level_of_effort" = if($csvHeaders -icontains "level_of_effort") {"level_of_effort"} else {$null} # Store the actual CSV header case
        "assigned_to"     = if($csvHeaders -icontains "assigned_to") {"assigned_to"} else {$null}
        "notes"           = if($csvHeaders -icontains "notes") {"notes"} else {$null}
        "exception"       = if($csvHeaders -icontains "exception") {"exception"} else {$null}
        "exception_notes" = if($csvHeaders -icontains "exception_notes") {"exception_notes"} else {$null}
        "exception_proof" = if($csvHeaders -icontains "exception_proof") {"exception_proof"} else {$null}
        "start_date"      = if($csvHeaders -icontains "start_date") {"start_date"} else {$null}
        "end_date"        = if($csvHeaders -icontains "end_date") {"end_date"} else {$null}
    }.PSBase.Keys | ForEach-Object { if ($updateColumns[$_]) { @{ $_ = $updateColumns[$_] } } } | Group-Object -NoElement | Select-Object -ExpandProperty Group

    if ($updateColumns.Count -eq 0) {
         throw "No updateable columns (e.g., level_of_effort, assigned_to, notes, exception*, start_date, end_date) found in the CSV header besides the key column '$keyColumnName'. Nothing to update."
    }
     Write-Host "Columns found in CSV to potentially update: $($updateColumns.Keys -join ', ')" -ForegroundColor Cyan

    # --- Get Database Connection Info ---
    Write-Host "Retrieving database connection details..."
    $connectionInfo = Get-ConnectionInfo # Assumes StoryzeUtils function handles env vars
    if (-not $connectionInfo) { throw "Failed to retrieve database connection information." }

    # Determine the connection timeout value using the safe helper
    $connectTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_connect_timeout' -DefaultValue 30
    Write-Verbose "Using SQL connection timeout: $connectTimeout seconds."

    # --- Database Operations (Using determined Connection String) ---
    $updatedBy = "Script: $($MyInvocation.MyCommand.Name)"
    $stopwatchDb = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "Establishing database connection to [$targetServer]..."
    $effectiveConnectionString = $connectionString + ";Connection Timeout=$connectTimeout;" # Append timeout
    Write-Verbose "Effective Connection String (Password Redacted): $(($effectiveConnectionString -replace 'Password=[^;]+;', 'Password=********;') )"

    $conn = New-Object System.Data.SqlClient.SqlConnection($effectiveConnectionString)
    $conn.Open()
    Write-Host "Database connection successful." -ForegroundColor Green

    # Begin transaction
    Write-Host "Beginning SQL transaction..."
    $transaction = $conn.BeginTransaction("SampleDataUpdate")

    # Create Reusable Command Object
    $cmd = $conn.CreateCommand()
    $cmd.Transaction = $transaction
    # CommandTimeout will be set specifically before each execution below

    # --- Determine Default Command Timeout --- 
    # This will be used for operations without a specific config key or as a fallback
    $defaultCommandTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_command_timeout' -DefaultValue 300
    Write-Host "Using default command timeout: $defaultCommandTimeout seconds (from 'sql_command_timeout' or hardcoded default)." -ForegroundColor DarkGray

    # 1. Create Temporary Table
    Write-Host "Creating temporary table $tempTableName..."
    # Build CREATE TABLE statement dynamically based on columns present
    $tempTableName = "#SampleUpdates" # Local temporary table, automatically dropped on session end, but we drop explicitly
    $createTempTableSql = "CREATE TABLE $tempTableName ("
    $createTempTableSql += "`n  [$keyColumnName] INT NOT NULL PRIMARY KEY" # Add PK for potential join performance
    if ($updateColumns.ContainsKey("level_of_effort")) { $createTempTableSql += ",`n  [$($updateColumns["level_of_effort"])] NVARCHAR(32) NULL" }
    if ($updateColumns.ContainsKey("assigned_to"))     { $createTempTableSql += ",`n  [$($updateColumns["assigned_to"])] NVARCHAR(64) NULL" }
    if ($updateColumns.ContainsKey("notes"))           { $createTempTableSql += ",`n  [$($updateColumns["notes"])] NVARCHAR(MAX) NULL" }
    if ($updateColumns.ContainsKey("exception"))       { $createTempTableSql += ",`n  [$($updateColumns["exception"])] NVARCHAR(255) NULL" }
    if ($updateColumns.ContainsKey("exception_notes")) { $createTempTableSql += ",`n  [$($updateColumns["exception_notes"])] NVARCHAR(255) NULL" }
    if ($updateColumns.ContainsKey("exception_proof")) { $createTempTableSql += ",`n  [$($updateColumns["exception_proof"])] NVARCHAR(255) NULL" }
    if ($updateColumns.ContainsKey("start_date"))      { $createTempTableSql += ",`n  [$($updateColumns["start_date"])] DATETIME2(0) NULL" }
    if ($updateColumns.ContainsKey("end_date"))        { $createTempTableSql += ",`n  [$($updateColumns["end_date"])] DATETIME2(0) NULL" }
    $createTempTableSql += "`n);"
    Write-Verbose "Generated CREATE TEMP TABLE SQL:`n$createTempTableSql"
    $cmd.CommandText = $createTempTableSql
    $cmd.CommandTimeout = $defaultCommandTimeout # Use default timeout for DDL
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "Temporary table created."

    # --- Prepare DataTable for Bulk Copy ---
    Write-Host "Preparing data for bulk load..."
    $stopwatchDataPrep = [System.Diagnostics.Stopwatch]::StartNew()
    $dataTable = New-Object System.Data.DataTable

    # Add columns to DataTable - MUST match temp table definition and CSV headers being used
    $dataTable.Columns.Add($keyColumnName, [int]) | Out-Null # Assuming key is INT
    if ($updateColumns.ContainsKey("level_of_effort")) { $dataTable.Columns.Add("level_of_effort", [string]) | Out-Null }
    if ($updateColumns.ContainsKey("assigned_to"))     { $dataTable.Columns.Add("assigned_to", [string]) | Out-Null }
    if ($updateColumns.ContainsKey("notes"))           { $dataTable.Columns.Add("notes", [string]) | Out-Null }
    if ($updateColumns.ContainsKey("exception"))       { $dataTable.Columns.Add("exception", [string]) | Out-Null }
    if ($updateColumns.ContainsKey("exception_notes")) { $dataTable.Columns.Add("exception_notes", [string]) | Out-Null }
    if ($updateColumns.ContainsKey("exception_proof")) { $dataTable.Columns.Add("exception_proof", [string]) | Out-Null }
    if ($updateColumns.ContainsKey("start_date"))      { $dataTable.Columns.Add("start_date", [datetime]) | Out-Null }
    if ($updateColumns.ContainsKey("end_date"))        { $dataTable.Columns.Add("end_date", [datetime]) | Out-Null }

    # Populate DataTable from CSV data, performing cleaning/conversion
    $rowsProcessed = 0
    $skippedRows = 0
    foreach ($row in $csvData) {
        $rowsProcessed++
        $dataRow = $dataTable.NewRow()

        # Process Key Column (Mandatory)
        $keyValue = $row.$keyColumnName
        if ($null -eq $keyValue -or -not ($keyValue -match '^\d+$')) { # Basic validation for integer key
             Write-Warning "Skipping CSV row $rowsProcessed : Invalid or missing integer value for key column '$keyColumnName': '$keyValue'"
             $skippedRows++
             continue # Skip this row
        }
        $dataRow[$keyColumnName] = [int]$keyValue

        # Process Update Columns (handle missing columns in CSV gracefully)
        if ($updateColumns.ContainsKey("level_of_effort")) { $dataRow["level_of_effort"] = Get-DbSafeString -Value $row.($updateColumns["level_of_effort"]) }
        if ($updateColumns.ContainsKey("assigned_to"))     { $dataRow["assigned_to"] = Get-DbSafeString -Value $row.($updateColumns["assigned_to"]) }
        if ($updateColumns.ContainsKey("notes"))           { $dataRow["notes"] = Get-DbSafeString -Value $row.($updateColumns["notes"]) }
        if ($updateColumns.ContainsKey("exception"))       { $dataRow["exception"] = Get-DbSafeString -Value $row.($updateColumns["exception"]) }
        if ($updateColumns.ContainsKey("exception_notes")) { $dataRow["exception_notes"] = Get-DbSafeString -Value $row.($updateColumns["exception_notes"]) }
        if ($updateColumns.ContainsKey("exception_proof")) { $dataRow["exception_proof"] = Get-DbSafeString -Value $row.($updateColumns["exception_proof"]) }
        if ($updateColumns.ContainsKey("start_date"))      { $dataRow["start_date"] = Get-DbSafeDate -Value $row.($updateColumns["start_date"]) }
        if ($updateColumns.ContainsKey("end_date"))        { $dataRow["end_date"] = Get-DbSafeDate -Value $row.($updateColumns["end_date"]) }

        $dataTable.Rows.Add($dataRow)
    }
    $stopwatchDataPrep.Stop()
    Write-Host "Prepared $($dataTable.Rows.Count) rows for bulk load in $($stopwatchDataPrep.Elapsed.TotalSeconds.ToString('F2')) seconds. ($skippedRows rows skipped due to invalid key)." -ForegroundColor Green

    if ($dataTable.Rows.Count -eq 0) {
        Write-Warning "No valid data rows prepared after processing CSV. No updates will be performed."
        exit 0
    }

    # 2. Bulk Copy data into Temporary Table
    Write-Host "Bulk loading data into $tempTableName..."
    $bulkCopyOptions = [System.Data.SqlClient.SqlBulkCopyOptions]::Default # Or TableLock if appropriate
    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($conn, $bulkCopyOptions, $transaction)
    $bulkCopy.DestinationTableName = $tempTableName
    # Safely get batch size using the key from config, defaulting to 5000
    $bulkCopy.BatchSize = Get-SafeTimeoutValue -Settings $globalSettings -Key 'batch_size_bulk_load' -DefaultValue 5000 
    $bulkCopy.BulkCopyTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_cmd_timeout_bulk_copy' -DefaultValue 600

    # Add column mappings (important if DataTable column order differs from temp table)
    foreach($column in $dataTable.Columns) {
        $bulkCopy.ColumnMappings.Add($column.ColumnName, $column.ColumnName) | Out-Null
    }
    Write-Verbose "SqlBulkCopy Mappings Configured:"
    $bulkCopy.ColumnMappings | ForEach-Object { Write-Verbose "  Source: $($_.SourceColumn), Destination: $($_.DestinationColumn)" }

    # Write data
    $bulkCopy.WriteToServer($dataTable)
    Write-Host "Bulk load completed. $($dataTable.Rows.Count) rows loaded into temporary table." -ForegroundColor Green

    # 3. Update Main Staging Table from Temporary Table
    Write-Host "Updating main staging table $targetTableFull from temporary table..."
    # Build UPDATE statement dynamically
    $targetTableFull = "[$($sourceConfig.stg_schema)].[$($sourceConfig.stg_table)]"
    $updateSql = "UPDATE main SET "
    $updateSetClauses = @()
    foreach ($key in $updateColumns.Keys) {
        $csvColName = $updateColumns[$key]
        $updateSetClauses += "main.[$key] = tmp.[$csvColName]"
    }

    # Audit columns removed as they don't exist in the target table
    # $updateSetClauses += "main.[_last_updated_date] = GETUTCDATE()"
    # $updateSetClauses += "main.[_last_updated_by] = @UpdatedBy"

    $updateSql += $updateSetClauses -join ",`n    "
    $updateSql += "`nFROM $targetTableFull AS main`nINNER JOIN $tempTableName AS tmp ON main.[$keyColumnName] = tmp.[$keyColumnName];"

    Write-Verbose "Generated UPDATE SQL:`n$updateSql"
    $cmd.CommandText = $updateSql
    $cmd.Parameters.Clear()
    # Removed the parameter as the corresponding SET clause was removed
    # $cmd.Parameters.AddWithValue("@UpdatedBy", $updatedBy) | Out-Null 
    $cmd.CommandTimeout = $defaultCommandTimeout # Use default timeout for the main update join (as per previous logic)
    $rowsAffected = $cmd.ExecuteNonQuery()
    Write-Host "Main staging table update executed. $rowsAffected rows potentially affected." -ForegroundColor Green

    # 4. Synchronize 'fixed' flag
    Write-Host "Synchronizing 'fixed' flag in $targetTableFull based on end_date..."
    $syncFixedSql = @"
UPDATE $targetTableFull
SET [fixed] = CASE WHEN [end_date] IS NOT NULL THEN 'Y' ELSE 'N' END
WHERE ([end_date] IS NOT NULL AND ISNULL([fixed], 'N') <> 'Y') -- Update to Y if end_date exists and fixed is not Y
   OR ([end_date] IS NULL AND ISNULL([fixed], 'Y') <> 'N'); -- Update to N if end_date is null and fixed is not N
"@
    $cmd.CommandText = $syncFixedSql
    $cmd.Parameters.Clear() # No parameters for this one
    # Use specific timeout for sync, fallback to default if key missing
    $syncTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_cmd_timeout_sample_sync' -DefaultValue $defaultCommandTimeout 
    $cmd.CommandTimeout = $syncTimeout
    $syncRowsAffected = $cmd.ExecuteNonQuery()
    Write-Host "'fixed' flag synchronization executed. $syncRowsAffected rows potentially affected." -ForegroundColor Green

    # 5. Drop Temporary Table (cleanup)
    Write-Host "Dropping temporary table $tempTableName..."
    $cmd.CommandText = "DROP TABLE $tempTableName;"
    $cmd.CommandTimeout = $defaultCommandTimeout # Use default timeout for DDL
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "Temporary table dropped."

    # Commit Transaction
    Write-Host "Committing transaction..."
    $transaction.Commit()
    $stopwatchDb.Stop()
    Write-Host "Transaction committed successfully." -ForegroundColor Green
    Write-Host "Total database operation time: $($stopwatchDb.Elapsed.TotalSeconds.ToString('F2')) seconds."

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Error "Script execution failed at line $($_.InvocationInfo.ScriptLineNumber)."
    # Attempt to rollback transaction if it exists and connection is open
    if ($null -ne $transaction -and $null -ne $conn -and $conn.State -eq [System.Data.ConnectionState]::Open) {
        try {
            Write-Warning "Attempting to roll back transaction..."
            $transaction.Rollback()
            Write-Warning "Transaction rolled back."
        } catch {
            Write-Error "Failed to roll back transaction: $($_.Exception.Message)"
        }
    }
    # Re-throw the original exception to halt the script and indicate failure
    throw $_
} finally {
    # --- Resource Cleanup ---
    Write-Verbose "Performing resource cleanup..."
    if ($null -ne $cmd) { try { $cmd.Dispose() } catch { Write-Warning "Error disposing command object: $($_.Exception.Message)" } }
    if ($null -ne $bulkCopy) { try { $bulkCopy.Close() } catch { Write-Warning "Error closing bulk copy object: $($_.Exception.Message)" } } # Close closes internal connection if owned
    if ($null -ne $dataTable) { try { $dataTable.Dispose() } catch { Write-Warning "Error disposing data table: $($_.Exception.Message)" } }
    if ($null -ne $transaction) { try { $transaction.Dispose() } catch { Write-Warning "Error disposing transaction object: $($_.Exception.Message)" } }
    if ($null -ne $conn -and $conn.State -ne [System.Data.ConnectionState]::Closed) {
        try {
            $conn.Close()
            Write-Verbose "Database connection closed."
        } catch {
            Write-Warning "Error closing database connection: $($_.Exception.Message)"
        }
    }
}

$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime
Write-Host ("=" * 80)
Write-Host "Script Finished: $($MyInvocation.MyCommand.Name) at $scriptEndTime" -ForegroundColor Yellow
Write-Host "Total script duration: $($scriptDuration.TotalSeconds.ToString('F2')) seconds."
Write-Host ("=" * 80)