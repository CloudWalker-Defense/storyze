<#
.SYNOPSIS
Loads cleaned MSSQL findings data from CSV into the raw SQL Server table.

.DESCRIPTION
Performs the second step in the ETL pipeline by efficiently transferring the cleaned
assessment data from CSV into the raw database table. Uses SqlBulkCopy for high-performance
data loading while maintaining data integrity through proper column mapping and validation.

This step enables the transition from file-based storage to structured database storage,
preparing the data for downstream transformation and normalization operations.

.PARAMETER ConfigPath
Path to the YAML configuration file. Defaults to 'config.yaml' in the project root.

.PARAMETER Source
The source key within the config file (e.g., 'mssql').

.PARAMETER EnvType
Target environment: 'onprem' or 'azure'. Overrides .env if provided.

.PARAMETER AuthMethod
Authentication method: 'windows' (on-prem default), 'sql' (azure default).

.PARAMETER ServerInstance
SQL Server instance to connect to. Uses environment variable if not specified.

.PARAMETER DatabaseName
Target database name. Uses environment variable if not specified.

.PARAMETER SqlLogin
SQL login name (for 'sql' AuthMethod only).

.PARAMETER SqlPassword
SQL password (for 'sql' AuthMethod only).

.OUTPUTS
None. Data is loaded into the database as a side effect.

.EXAMPLE
# Load using default settings
.\002_load_findings_to_sql.ps1 -Source mssql

.EXAMPLE
# Load using Azure SQL Auth
.\002_load_findings_to_sql.ps1 -ConfigPath .\config.yaml -Source mssql -EnvType azure -AuthMethod sql
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

# --- Load StoryzeUtils and required modules ---
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

# --- Prepare Modules --- 
$scriptRequiredModules = @('SqlServer', 'powershell-yaml') # StoryzeUtils & yaml loaded by bootstrap/dependency if needed
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
Write-Verbose "Loading environment variables from .env file..."
Import-DotEnv

# --- Determine Effective Environment Type ---
$effectiveEnvType = $null
if ($PSBoundParameters.ContainsKey('EnvType')) {
    $effectiveEnvType = $EnvType.ToLower()
    Write-Verbose "Using Environment Type from -EnvType parameter: $effectiveEnvType"
} else {
    $effectiveEnvType = $env:ENV_TYPE.ToLower()
    if (-not $effectiveEnvType) {
        throw "Environment Type not specified via -EnvType parameter and ENV_TYPE is missing or empty in .env file."
    }
    Write-Verbose "Using Environment Type from .env file: $effectiveEnvType"
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
        Write-Verbose "Using server instance from ONPREM_SERVER environment variable: $targetServer"
    } elseif ($effectiveEnvType -eq "azure") {
        $targetServer = $env:AZURE_SERVER
        if (-not $targetServer) { throw "ServerInstance parameter not provided, and AZURE_SERVER environment variable is missing or empty for ENV_TYPE=azure." }
        Write-Verbose "Using server instance from AZURE_SERVER environment variable: $targetServer"
    }
} else {
    Write-Verbose "Using provided server instance parameter: $targetServer"
}

# --- Determine Target Database ---
$targetDatabase = $DatabaseName 
if (-not $targetDatabase) {
    if ($effectiveEnvType -eq "onprem") {
        $targetDatabase = $env:ONPREM_DATABASE
        if (-not $targetDatabase) { throw "DatabaseName parameter not provided, and ONPREM_DATABASE environment variable is missing or empty for ENV_TYPE=onprem." }
        Write-Verbose "Using database name from ONPREM_DATABASE environment variable: $targetDatabase"
    } elseif ($effectiveEnvType -eq "azure") {
        $targetDatabase = $env:AZURE_DATABASE
        if (-not $targetDatabase) { throw "DatabaseName parameter not provided, and AZURE_DATABASE environment variable is missing or empty for ENV_TYPE=azure." }
        Write-Verbose "Using database name from AZURE_DATABASE environment variable: $targetDatabase"
    }
} else {
    Write-Verbose "Using provided database name parameter: $targetDatabase"
}

# --- Determine Authentication Method and Credentials ---
$authMethodToUse = $AuthMethod
$username = $null
$password = $null

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
        Write-Verbose "Using SQL login from environment ($envVarLogin): $username"
    } else {
        Write-Verbose "Using provided SQL login parameter: $username"
    }

    # Determine final password (parameter > env var)
    $password = $paramPassword
    if (-not $password) {
        $password = $envPassword
        if (-not $password) { throw "SQL Auth requested but password not found. Provide -SqlPassword or set $envVarPassword in .env." }
        Write-Verbose "Using SQL password from environment ($envVarPassword)."
        # Explicitly ensure param password is a clean string
        $password = [string]$password.Trim()
    } else {
        Write-Verbose "Using provided SQL password parameter."
        # Explicitly ensure param password is a clean string
        $password = [string]$password.Trim()
    }
}

# --- Build Connection String --- 
$connectionString = $null
switch ("$effectiveEnvType/$authMethodToUse") { 
    "onprem/windows" {
        $connectionString = "Server=$targetServer;Database=$targetDatabase;Integrated Security=True;TrustServerCertificate=True;"
        Write-Verbose "Using Windows Integrated Authentication (On-Premises)"
    }
    "onprem/sql" {
        # Escape single quotes in password for connection string safety
        $safePassword = $password -replace "'", "''"
        # Password value should NOT be enclosed in single quotes for SqlConnection
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;TrustServerCertificate=True;"
        Write-Verbose "Using SQL Server Authentication (On-Premises) for login: $username"
    }
    "azure/sql" {
        # Escape single quotes in password for connection string safety
        $safePassword = $password -replace "'", "''"
        # Password value should NOT be enclosed in single quotes for SqlConnection
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;Encrypt=True;TrustServerCertificate=True;MultipleActiveResultSets=True;Integrated Security=False;Connection Timeout=60;"
        Write-Verbose "Using Azure SQL Authentication for login: $username"
        # Add extra debugging for Azure connection
        Write-Verbose "Azure Target Server: [$targetServer]"
        Write-Verbose "Azure Target Database: [$targetDatabase]"
    }
    default {
        # Should only be hit if validation above failed somehow
        throw "Invalid combination of environment type ('$effectiveEnvType') and auth method ('$authMethodToUse') encountered."
    }
}
if (-not $connectionString) { throw "Internal error: Failed to build connection string." }

# --- Main Script Execution (Load CSV to SQL) ---
$scriptStartTime = Get-Date
Write-Verbose "Starting Script: $($MyInvocation.MyCommand.Name) at $scriptStartTime"
Write-Verbose "Script to load cleaned findings from CSV to SQL Raw Table using Bulk Copy."

# Initialize variables used in finally block
$conn = $null
$bulkCopy = $null
$dataTable = $null
$transaction = $null
$cmd = $null

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
        throw "Source '$Source' not found in configuration file '$ConfigPath'. Available sources: $availableSources"
    }

    # --- Get Input CSV Path ---
    $inputCsvPathStr = $sourceConfig.csv_clean_file
    if ([string]::IsNullOrWhiteSpace($inputCsvPathStr)) {
        throw "Configuration key 'csv_clean_file' is missing or empty for source '$Source'."
    }
    Write-Verbose "Attempting to use Input Clean CSV: '$inputCsvPathStr'"
    $csvFileInfo = Resolve-Path -Path $inputCsvPathStr -ErrorAction SilentlyContinue
    if (-not $csvFileInfo) { throw "Input CSV file not found at path specified in config ('csv_clean_file'): '$inputCsvPathStr'" }
    Write-Verbose "Successfully resolved Input Clean CSV: $($csvFileInfo.Path)"

    # --- Get Target Table Info & Truncate Setting ---
    $rawSchema = $sourceConfig.raw_schema
    $rawTable = $sourceConfig.raw_table
    if ([string]::IsNullOrWhiteSpace($rawSchema) -or [string]::IsNullOrWhiteSpace($rawTable)) {
        throw "Configuration keys 'raw_schema' and 'raw_table' are required for source '$Source' but are missing or empty."
    }
    $targetTableFull = "[$rawSchema].[$rawTable]"
    Write-Verbose "Target Raw Table: $targetTableFull"

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
    Write-Verbose "Truncate Target Table Before Load: $shouldTruncate (from config 'truncate_raw', defaults to true)"

    # --- Read CSV Data (using Import-Csv) ---
    Write-Verbose "Reading cleaned data from CSV file '$($csvFileInfo.Path)'..."
    $stopwatchReadCsv = [System.Diagnostics.Stopwatch]::StartNew()

    $csvData = Import-Csv -Path $csvFileInfo.Path
    $rowCount = $csvData.Count # Assuming $csvData is an array or countable collection
    Write-Verbose "Read $rowCount rows using Import-Csv."

    if ($rowCount -eq 0) {
        Write-Warning "CSV file '$($csvFileInfo.Path)' contained no data rows. No data to load."
        exit 0
    }

    # --- Database Operations (Using determined Connection String) --- 
    $stopwatchDb = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "Establishing database connection to [$targetServer]..."
    $connectTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_connect_timeout' -DefaultValue 30
    $effectiveConnectionString = $connectionString + "Connection Timeout=$connectTimeout;"
    Write-Verbose "Effective Connection String (Password Redacted): $(($effectiveConnectionString -replace 'Password=[^;]+;', 'Password=********;') )"
    
    $conn = New-Object System.Data.SqlClient.SqlConnection($effectiveConnectionString)
    $conn.Open()
    Write-Verbose "Database connection successful."

    # Begin transaction for atomicity (especially needed if truncating)
    Write-Verbose "Beginning SQL transaction..."
    $transaction = $conn.BeginTransaction("LoadRawData")
    $cmd = $conn.CreateCommand()
    $cmd.Transaction = $transaction

    # --- Optional Table Truncation --- 
    if ($shouldTruncate) {
        Write-Verbose "Attempting to truncate target table: $targetTableFull..."
        $stopwatchTruncate = [System.Diagnostics.Stopwatch]::StartNew()
        $cmd.CommandText = "TRUNCATE TABLE $targetTableFull;"
        $cmd.CommandTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_command_timeout' -DefaultValue 300 # Use a generous timeout for truncate
        $cmd.ExecuteNonQuery() | Out-Null # Returns -1 for TRUNCATE
        $stopwatchTruncate.Stop()
        Write-Verbose "Target table truncated successfully in $($stopwatchTruncate.Elapsed.TotalSeconds.ToString('F2')) seconds."
    }

    # --- Analyze Target Table Schema (Required for mapping) --- 
    Write-Verbose "Analyzing schema of target table: $targetTableFull..."
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
    Write-Verbose "Prepared $($dataTable.Rows.Count) data rows into DataTable in $($stopwatchDataPrep.Elapsed.TotalSeconds.ToString('F2')) seconds."

    # SqlBulkCopy Setup
    Write-Verbose "Performing bulk copy into $targetTableFull..."
    $bulkCopyOptions = [System.Data.SqlClient.SqlBulkCopyOptions]::Default # Use TableLock if load is exclusive
    $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($conn, $bulkCopyOptions, $transaction) 
    $bulkCopy.DestinationTableName = $targetTableFull

    $bulkCopy.BatchSize = Get-SafeTimeoutValue -Settings $globalSettings -Key 'batch_size_bulk_load' -DefaultValue 5000
    $bulkCopy.BulkCopyTimeout = Get-SafeTimeoutValue -Settings $globalSettings -Key 'sql_cmd_timeout_bulk_copy' -DefaultValue 600 

    Write-Verbose "SqlBulkCopy Settings - BatchSize: $($bulkCopy.BatchSize), Timeout: $($bulkCopy.BulkCopyTimeout) seconds"

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
    Write-Verbose "Bulk copy completed successfully. $($dataTable.Rows.Count) rows loaded."

    # Commit transaction
    Write-Verbose "Committing transaction..."
    $transaction.Commit()
    Write-Verbose "Transaction committed."

    $stopwatchDb.Stop()
    Write-Verbose "Total database operation time: $($stopwatchDb.Elapsed.TotalSeconds.ToString('F2')) seconds."

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
Write-Verbose "Script Finished: $($MyInvocation.MyCommand.Name) at $scriptEndTime"
Write-Verbose "Total script duration: $($scriptDuration.TotalSeconds.ToString('F2')) seconds."