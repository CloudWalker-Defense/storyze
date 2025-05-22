<#
.SYNOPSIS
Loads sample tracking data from CSV and updates the staging table.

.DESCRIPTION
Reads sample tracking data (LOE, assigned_to, dates, etc.) from a CSV file and updates the SQL staging table. Handles connection, bulk load, and update logic. Uses config and environment parameters for connection.

.PARAMETER ConfigPath
Path to the YAML configuration file. Defaults to 'config.yaml' in the project root.

.PARAMETER Source
The source key within the config file (e.g., 'mssql').

.PARAMETER EnvType
Target environment: 'onprem' or 'azure'. Overrides ENV_TYPE from .env.

.PARAMETER AuthMethod
Authentication method: 'windows' (on-prem default), 'sql' (azure default).

.PARAMETER ServerInstance
SQL Server instance to connect to. Uses environment variable if not specified.

.PARAMETER DatabaseName
Target database name. Uses environment variable if not specified.

.PARAMETER SqlLogin
SQL login name (for 'sql' AuthMethod only).

.PARAMETER SqlPassword
SQL password (for 'sql' AuthMethod only). Expected as a SecureString for enhanced security.

.PARAMETER SampleDataPath
Path to the sample data CSV file. Overrides config if provided.

.EXAMPLE
# Load sample data using default settings
.\006_load_sample_data.ps1 -Source mssql

.EXAMPLE
# Load sample data using Azure SQL Auth and a specific CSV
.\006_load_sample_data.ps1 -Source mssql -EnvType azure -AuthMethod sql -SampleDataPath ".\data\mssql_sample_updates.csv"
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
    Write-Verbose "Using default config path: $ConfigPath"
} else {
    try {
        $resolved = Resolve-Path -Path $ConfigPath -ErrorAction Stop
        $ConfigPath = $resolved.Path
        Write-Verbose "Using specified config path: $ConfigPath"
    } catch {
        throw "Failed to resolve provided -ConfigPath '$ConfigPath': $($_.Exception.Message)"
    }
}
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Configuration file not found: '$ConfigPath'"
}

# --- Load Environment Configuration from .env ---
Write-Verbose "Loading environment variables from .env file"
Import-DotEnv

# --- Parameter Validation Block ---
# First, validate EnvType/AuthMethod combinations before checking for credential conflicts
if ($PSBoundParameters.ContainsKey('EnvType') -and $EnvType -eq 'azure' -and $PSBoundParameters.ContainsKey('AuthMethod') -and $AuthMethod -eq 'windows') {
    throw "Invalid parameter combination: -AuthMethod 'windows' is not permitted when -EnvType is 'azure'. Azure supports 'sql'."
}

# Now check for credential conflicts only if the AuthMethod is valid for the EnvType
if ($PSBoundParameters.ContainsKey('AuthMethod') -and $AuthMethod -eq 'windows') {
    if ($PSBoundParameters.ContainsKey('SqlLogin') -or $PSBoundParameters.ContainsKey('SqlPassword')) {
        throw "Invalid parameter combination: -SqlLogin and -SqlPassword are not allowed when -AuthMethod is 'windows'."
    }
}

if ($PSBoundParameters.ContainsKey('AuthMethod') -and $AuthMethod -eq 'sql') {
    # No LoginEmail allowed for sql auth
    if ($PSBoundParameters.ContainsKey('LoginEmail')) {
        throw "Invalid parameter combination: -LoginEmail is not allowed when -AuthMethod is 'sql'."
    }
}
# --- End Parameter Validation Block ---

# --- Determine Effective Environment Type --- 
$effectiveEnvType = $null
if ($PSBoundParameters.ContainsKey('EnvType')) { 
    $effectiveEnvType = $EnvType.ToLower()
    Write-Verbose "Using EnvType from parameter: $effectiveEnvType"
} else { 
    # Get ENV_TYPE safely without calling .ToLower() on potentially null value
    $effectiveEnvType = $env:ENV_TYPE
    if ([string]::IsNullOrWhiteSpace($effectiveEnvType)) {
        # Default to 'azure' if not specified, matching behavior in other scripts
        $effectiveEnvType = "azure"
        Write-Verbose "EnvType not found in environment variables, defaulting to: $effectiveEnvType"
    } else {
        $effectiveEnvType = $effectiveEnvType.ToLower()
        Write-Verbose "Using EnvType from .env: $effectiveEnvType"
    }
}

if ($effectiveEnvType -ne "onprem" -and $effectiveEnvType -ne "azure") { throw "Invalid effective EnvType: '$effectiveEnvType'." }

# --- Determine Target Server ---
$targetServer = $ServerInstance 
if (-not $targetServer) { 
    $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SERVER' } else { 'AZURE_SERVER' } 
    $targetServer = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue # Use Get-Content
    if (-not $targetServer) { throw "Server missing (-ServerInstance or $envVar)." } 
    Write-Verbose "Using server from $envVar : $targetServer"
} else { Write-Verbose "Using -ServerInstance: $targetServer" }

# --- Determine Target Database ---
$targetDatabase = $DatabaseName 
if (-not $targetDatabase) { 
    $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_DATABASE' } else { 'AZURE_DATABASE' } 
    $targetDatabase = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue # Use Get-Content
    if (-not $targetDatabase) { throw "Database missing (-DatabaseName or $envVar)." } 
    Write-Verbose "Using database from $envVar : $targetDatabase"
} else { Write-Verbose "Using -DatabaseName: $targetDatabase" }

# --- Determine Authentication Method and Credentials ---
$authMethodToUse = $AuthMethod
$username = $null; $password = $null;
if (-not $authMethodToUse) {
    # Apply defaults based on environment
    if ($effectiveEnvType -eq "onprem") {
        $authMethodToUse = 'windows'
        Write-Verbose "No -AuthMethod specified for on-prem, defaulting to '$authMethodToUse'."
    } elseif ($effectiveEnvType -eq "azure") {
        $authMethodToUse = 'sql' # *** NEW DEFAULT FOR AZURE ***
        Write-Verbose "No -AuthMethod specified for Azure, defaulting to '$authMethodToUse'."
    }
} else {
    $authMethodToUse = $authMethodToUse.ToLower()
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
        Write-Verbose "Using SQL login from $envVar : $username"
    } else { Write-Verbose "Using -SqlLogin: $username" } 
    $password = $SqlPassword
    if (-not $password) { 
        $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SQL_PASSWORD' } else { 'AZURE_SQL_PASSWORD' } 
        $password = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue # Use Get-Content
        if (-not $password) { throw "SQL Auth: Password missing (-SqlPassword or $envVar)." } 
        Write-Verbose "Using SQL pwd from $envVar."
    } else { Write-Verbose "Using -SqlPassword parameter." } 
}

# --- Build Connection String --- 
$connectionString = $null
$combo = "$effectiveEnvType/$authMethodToUse"
if ($combo -ieq "onprem/windows") {
    $connectionString = "Server=$targetServer;Database=$targetDatabase;Integrated Security=True;TrustServerCertificate=True"
    Write-Verbose "Using On-Prem configuration: Windows Authentication."
} elseif ($combo -ieq "onprem/sql") {
    $safePassword = $password -replace "'", "''"
    $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;TrustServerCertificate=True"
    Write-Verbose "Using On-Prem configuration: SQL Authentication."
} elseif ($combo -ieq "azure/sql") {
    $safePassword = $password -replace "'", "''"
    # Enhanced connection string for Azure SQL Managed Instance
    $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;Encrypt=True;TrustServerCertificate=True;MultipleActiveResultSets=True;Connection Timeout=60;Integrated Security=False"
    Write-Verbose "Using Azure configuration: SQL Authentication with enhanced settings for SQL MI."
} else {
    throw "Invalid EnvType/AuthMethod combination: '$combo'."
}

# --- Main Script Execution --- 
$scriptStartTime = Get-Date
Write-Verbose "Script to update staging table with sample tracking data using Temp Table + Bulk Update."

$conn = $null
$transaction = $null
$bulkCopy = $null
$dataTable = $null
$cmd = $null # Reusable command object

try {
    # --- Configuration Loading ---
    Write-Verbose "Loading configuration from '$ConfigPath' for source '$Source'..."
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
        throw "Source '$Source' not found in configuration file. Available sources: $availableSources"
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
    Write-Verbose "Using Sample Data CSV from ${pathSource}: $effectiveCsvPathStr"
    $csvFileInfo = Resolve-Path -Path $effectiveCsvPathStr -ErrorAction SilentlyContinue
    if (-not $csvFileInfo) { throw "Sample data CSV file not found at the path specified: $effectiveCsvPathStr" }
    Write-Verbose "Found Sample Data CSV: $($csvFileInfo.Path)"

    # --- Read CSV Data ---
    Write-Verbose "Reading sample data from CSV file..."
    # Note: Import-Csv loads the entire file into memory. Fine for moderate sample files.
    $csvData = Import-Csv -Path $csvFileInfo.Path 
    $rowCount = $csvData.Count
    Write-Verbose "Read $rowCount rows from CSV."
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
    $updateColumns = @{}
    if ($csvHeaders -icontains "level_of_effort") { $updateColumns["level_of_effort"] = "level_of_effort" }
    if ($csvHeaders -icontains "assigned_to") { $updateColumns["assigned_to"] = "assigned_to" }
    if ($csvHeaders -icontains "notes") { $updateColumns["notes"] = "notes" }
    if ($csvHeaders -icontains "exception") { $updateColumns["exception"] = "exception" }
    if ($csvHeaders -icontains "exception_notes") { $updateColumns["exception_notes"] = "exception_notes" }
    if ($csvHeaders -icontains "exception_proof") { $updateColumns["exception_proof"] = "exception_proof" }
    if ($csvHeaders -icontains "start_date") { $updateColumns["start_date"] = "start_date" }
    if ($csvHeaders -icontains "end_date") { $updateColumns["end_date"] = "end_date" }

    if ($updateColumns.Count -eq 0) {
         throw "No updateable columns (e.g., level_of_effort, assigned_to, notes, exception*, start_date, end_date) found in the CSV header besides the key column '$keyColumnName'. Nothing to update."
    }
    Write-Verbose "Columns found in CSV to potentially update: $($updateColumns.Keys -join ', ')"

    # --- Get Database Connection Info ---
    Write-Verbose "Getting database connection info from environment..."
    # The Get-ConnectionInfo function doesn't take parameters, it reads from environment variables
    $connectionInfo = Get-ConnectionInfo
    if (-not $connectionInfo) { throw "Failed to retrieve database connection information." }

    # Override connection info with script parameters if provided
    if ($targetServer) { $connectionInfo.ServerInstance = $targetServer }
    if ($targetDatabase) { $connectionInfo.DatabaseName = $targetDatabase }
    if ($effectiveEnvType) { $connectionInfo.EnvType = $effectiveEnvType }
    if ($authMethodToUse) { $connectionInfo.AuthMethod = $authMethodToUse }
    if ($username) { $connectionInfo.Username = $username }
    if ($password) { $connectionInfo.Password = $password }

    # Determine the connection timeout value using the safe helper
    $connectTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_connect_timeout' -DefaultValue 30
    Write-Verbose "Using SQL connection timeout: $connectTimeout seconds."

    # --- Database Operations (Using determined Connection String) ---
    $updatedBy = "Script: $($MyInvocation.MyCommand.Name)"
    $stopwatchDb = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Verbose "Establishing database connection to [$targetServer]..."
    $effectiveConnectionString = $connectionString + ";Connection Timeout=$connectTimeout;" # Append timeout
    Write-Verbose "Effective Connection String (Password Redacted): $(($effectiveConnectionString -replace 'Password=[^;]+;', 'Password=********;') )"

    $conn = New-Object System.Data.SqlClient.SqlConnection($effectiveConnectionString)
        
    $conn.Open()
    Write-Verbose "Database connection successful."

    # Begin transaction
    Write-Verbose "Beginning SQL transaction..."
    $transaction = $conn.BeginTransaction("SampleDataUpdate")

    # Create Reusable Command Object
    $cmd = $conn.CreateCommand()
    $cmd.Transaction = $transaction
    # CommandTimeout will be set specifically before each execution below

    # --- Determine Default Command Timeout --- 
    # This will be used for operations without a specific config key or as a fallback
    $defaultCommandTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_command_timeout' -DefaultValue 300
    Write-Verbose "Using default command timeout: $defaultCommandTimeout seconds (from 'sql_command_timeout' or hardcoded default)."

    # 1. Create Temporary Table
    Write-Verbose "Creating temporary table and loading data..."
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
    Write-Verbose "Generated CREATE TEMP TABLE SQL"
    $cmd.CommandText = $createTempTableSql
    $cmd.CommandTimeout = $defaultCommandTimeout # Use default timeout for DDL
    $null = $cmd.ExecuteNonQuery()
    Write-Verbose "Temporary table created."

    # --- Prepare DataTable for Bulk Copy ---
    Write-Verbose "Preparing data for bulk load..."
    $stopwatchDataPrep = [System.Diagnostics.Stopwatch]::StartNew()
    $dataTable = New-Object System.Data.DataTable

    # Add columns to DataTable - MUST match temp table definition and CSV headers being used
    $null = $dataTable.Columns.Add($keyColumnName, [int]) # Assuming key is INT
    if ($updateColumns.ContainsKey("level_of_effort")) { $null = $dataTable.Columns.Add("level_of_effort", [string]) }
    if ($updateColumns.ContainsKey("assigned_to"))     { $null = $dataTable.Columns.Add("assigned_to", [string]) }
    if ($updateColumns.ContainsKey("notes"))           { $null = $dataTable.Columns.Add("notes", [string]) }
    if ($updateColumns.ContainsKey("exception"))       { $null = $dataTable.Columns.Add("exception", [string]) }
    if ($updateColumns.ContainsKey("exception_notes")) { $null = $dataTable.Columns.Add("exception_notes", [string]) }
    if ($updateColumns.ContainsKey("exception_proof")) { $null = $dataTable.Columns.Add("exception_proof", [string]) }
    if ($updateColumns.ContainsKey("start_date"))      { $null = $dataTable.Columns.Add("start_date", [datetime]) }
    if ($updateColumns.ContainsKey("end_date"))        { $null = $dataTable.Columns.Add("end_date", [datetime]) }

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

        $null = $dataTable.Rows.Add($dataRow)
    }
    $stopwatchDataPrep.Stop()
    Write-Verbose "Prepared $($dataTable.Rows.Count) rows for bulk load in $($stopwatchDataPrep.Elapsed.TotalSeconds.ToString('F2')) seconds. ($skippedRows rows skipped)"

    if ($dataTable.Rows.Count -eq 0) {
        Write-Warning "No valid data rows prepared after processing CSV. No updates will be performed."
        exit 0
    }

    # 2. Bulk Copy data into Temporary Table
    Write-Verbose "Bulk loading data into $tempTableName..."
    $bulkCopyOptions = [System.Data.SqlClient.SqlBulkCopyOptions]::Default # Or TableLock if appropriate
    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($conn, $bulkCopyOptions, $transaction)
    $bulkCopy.DestinationTableName = $tempTableName
    $bulkCopy.BatchSize = Get-SafeTimeoutValue -Settings $globalSettings -Key 'batch_size_bulk_load' -DefaultValue 5000 
    $bulkCopy.BulkCopyTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_cmd_timeout_bulk_copy' -DefaultValue 600

    # Add column mappings (important if DataTable column order differs from temp table)
    foreach($column in $dataTable.Columns) {
        $null = $bulkCopy.ColumnMappings.Add($column.ColumnName, $column.ColumnName)
    }
    Write-Verbose "SqlBulkCopy Mappings Configured"

    # Write data
    $null = $bulkCopy.WriteToServer($dataTable)
    Write-Verbose "Bulk load completed. $($dataTable.Rows.Count) rows loaded into temporary table."

    # 3. Update Main Staging Table from Temporary Table
    Write-Verbose "Updating staging table with sample data..."
    # Build UPDATE statement dynamically
    $targetTableFull = "[$($sourceConfig.stg_schema)].[$($sourceConfig.stg_table)]"
    $updateSql = "UPDATE main SET "
    $updateSetClauses = @()
    foreach ($key in $updateColumns.Keys) {
        $csvColName = $updateColumns[$key]
        $updateSetClauses += "main.[$key] = tmp.[$csvColName]"
    }

    $updateSql += $updateSetClauses -join ",`n    "
    $updateSql += "`nFROM $targetTableFull AS main`nINNER JOIN $tempTableName AS tmp ON main.[$keyColumnName] = tmp.[$keyColumnName];"

    Write-Verbose "Generated UPDATE SQL"
    $cmd.CommandText = $updateSql
    $cmd.Parameters.Clear()
    $cmd.CommandTimeout = $defaultCommandTimeout
    $rowsAffected = $cmd.ExecuteNonQuery()
    Write-Verbose "Updated staging table. $rowsAffected rows affected."

    # 4. Synchronize 'fixed' flag
    Write-Verbose "Synchronizing 'fixed' flag in $targetTableFull based on end_date..."
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
    Write-Verbose "'fixed' flag synchronization executed. $syncRowsAffected rows affected."

    # 5. Drop Temporary Table (cleanup)
    Write-Verbose "Cleaning up temporary table..."
    $cmd.CommandText = "IF OBJECT_ID('tempdb..$tempTableName') IS NOT NULL DROP TABLE $tempTableName;"
    $cmd.CommandTimeout = 30 # Short timeout for simple cleanup operation
    $null = $cmd.ExecuteNonQuery()

    # 6. Commit Transaction
    Write-Verbose "Committing transaction..."
    $transaction.Commit()
    Write-Verbose "Sample data updates committed successfully."
    
    $stopwatchDb.Stop()
    Write-Verbose "Database operations completed in $($stopwatchDb.Elapsed.TotalSeconds.ToString('F2')) seconds."

} catch {
    # Centralized error handling with transaction rollback
    Write-Error "Script failed: $($_.Exception.Message)"
    Write-Error "Script execution failed at line $($_.InvocationInfo.ScriptLineNumber)."
    
    # Attempt to rollback transaction if one exists and is active
    if ($transaction -and $transaction.Connection -ne $null) {
        try {
            Write-Warning "Rolling back transaction due to error..."
            $transaction.Rollback()
            Write-Warning "Transaction rolled back."
        } catch {
            Write-Error "Failed to rollback transaction: $($_.Exception.Message)"
        }
    }

    exit 1
} finally {
    # Clean up resources
    if ($bulkCopy) { $bulkCopy.Close() }
    if ($cmd) { $cmd.Dispose() }
    if ($conn -and $conn.State -eq [System.Data.ConnectionState]::Open) { $conn.Close() }
    if ($dataTable) { $dataTable.Dispose() }
}