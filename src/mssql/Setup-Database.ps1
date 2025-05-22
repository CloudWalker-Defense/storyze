<#
.SYNOPSIS
Initializes the Storyze database by executing required SQL scripts in order.

.DESCRIPTION
Creates the database structure required for the Storyze Assessment Tracker, including
schemas, tables, views, and base records. This script handles the initial database setup
only and must be run before any ETL or data processing operations.

The script executes SQL files in a specific order to ensure proper dependency handling,
providing a consistent database structure across all deployment environments.

.PARAMETER ServerInstance
SQL Server instance to connect to (e.g., "localhost", "SERVER\SQLEXPRESS"). Uses environment variable if not specified.

.PARAMETER DatabaseName
Target database name. Uses environment variable if not specified.

.PARAMETER EnvType
Target environment: 'onprem' or 'azure'. Overrides .env if provided.

.PARAMETER AuthMethod
Authentication method: 'windows' (on-prem default), 'sql' (azure default).

.PARAMETER SqlLogin
SQL login name (for 'sql' AuthMethod only).

.PARAMETER SqlPassword
SQL password (for 'sql' AuthMethod only).

.OUTPUTS
None. This script creates database objects as a side effect.

.EXAMPLE
# On-premises, Windows Auth (default)
.\Setup-Database.ps1

.EXAMPLE
# On-premises, SQL Auth
.\Setup-Database.ps1 -AuthMethod "sql"

.EXAMPLE
# Azure, SQL Auth
.\Setup-Database.ps1 -EnvType "azure" -AuthMethod "sql" -SqlLogin "user" -SqlPassword "pass"

.EXAMPLE
# Specify server/db explicitly; ENV_TYPE from .env determines default AuthMethod & env var lookups
.\Setup-Database.ps1 -ServerInstance "target_server" -DatabaseName "target_db"
#>
[CmdletBinding()]
param(
    # Server instance (e.g., "localhost", "SERVER\SQLEXPRESS", "yourserver.database.windows.net")
    [Parameter(Mandatory=$false)]
    [string]$ServerInstance,

    # Target database name
    [Parameter(Mandatory=$false)]
    [string]$DatabaseName,

    # Optional: Override ENV_TYPE from .env file ('onprem' or 'azure')
    [Parameter(Mandatory=$false)]
    [ValidateSet('onprem', 'azure')] 
    [string]$EnvType,
    
    # Optional: Specify authentication method ('windows', 'sql')
    # Default depends on EnvType (windows for onprem, sql for azure)
    [Parameter(Mandatory=$false)]
    [ValidateSet('windows', 'sql')] 
    [string]$AuthMethod,
    
    # Login name (ONLY used for -AuthMethod 'sql')
    [Parameter(Mandatory=$false)]
    [string]$SqlLogin, 
    
    # Password (ONLY used for -AuthMethod 'sql')
    [Parameter(Mandatory=$false)]
    [string]$SqlPassword
)

# --- Parameter Validation Block ---
# Validate parameter combinations and environment-specific rules
if ($PSBoundParameters.ContainsKey('EnvType') -and $EnvType -eq 'azure' -and $PSBoundParameters.ContainsKey('AuthMethod') -and $AuthMethod -eq 'windows') {
    throw "Invalid parameter combination: -AuthMethod 'windows' is not permitted when -EnvType is 'azure'. Azure supports only 'sql'."
}

if ($PSBoundParameters.ContainsKey('AuthMethod') -and $AuthMethod -eq 'windows') {
    if ($PSBoundParameters.ContainsKey('SqlLogin') -or $PSBoundParameters.ContainsKey('SqlPassword')) {
        throw "Invalid parameter combination: -SqlLogin and -SqlPassword are not allowed when -AuthMethod is 'windows'."
    }
}

if ($PSBoundParameters.ContainsKey('AuthMethod') -and $AuthMethod -eq 'sql') {
}

# --- Minimal Bootstrapping to find and load StoryzeUtils ---
# Locates and imports StoryzeUtils.psm1 from the repo root (required for all scripts)
$InitialLocation = $PSScriptRoot
$RepoRoot = $null
for ($i = 0; $i -lt 5; $i++) { # Search up to 5 levels up
    $UtilsPath = Join-Path $InitialLocation "StoryzeUtils.psm1"
    if (Test-Path $UtilsPath -PathType Leaf) {
        $RepoRoot = $InitialLocation
        try {
            Import-Module $UtilsPath -Force -ErrorAction Stop
        } catch {
            throw "Found StoryzeUtils.psm1 at '$UtilsPath' but failed to import it: $($_.Exception.Message)"
        }
        break
    }
    $ParentDir = Split-Path -Parent $InitialLocation
    if ($ParentDir -eq $InitialLocation) { break } # Reached drive root
    $InitialLocation = $ParentDir
}
if (-not $RepoRoot) {
    throw "Could not find StoryzeUtils.psm1 in the script directory or parent directories. Cannot proceed."
}
$utilsModule = Get-Module -Name StoryzeUtils # Should now be loaded
if (-not $utilsModule) { throw "StoryzeUtils module loaded but Get-Module failed." } # Sanity check
$projectRoot = $utilsModule.ModuleBase # Use module base as project root

# --- Load Required Modules ---
# Initialize all required modules using the centralized module loader
try {
    Write-Verbose "Initializing required modules..."
    $modulesDir = Join-Path $projectRoot "modules"
    Initialize-RequiredModules -RequiredModules @('SqlServer', 'powershell-yaml') -LocalModulesBaseDir $modulesDir
    Write-Verbose "Required modules initialized successfully."
} catch {
    Write-StoryzeError -Message "Failed to initialize required modules" -ErrorRecord $_ -Fatal
}

# --- Parameter Validation ---
# Use centralized parameter validation for consistent checks
$validationResult = Test-StoryzeParameterValidation -BoundParameters $PSBoundParameters
if (-not $validationResult.IsValid) {
    foreach ($errorMsg in $validationResult.ErrorMessages) {
        Write-Host "ERROR: $errorMsg" -ForegroundColor Red
    }
    throw "Parameter validation failed. Please correct the errors above and try again."
}

# --- Clean, beautiful header ---
$scriptStartTime = Get-Date
Write-Host ("=" * 80)
Write-Host ("STORYZE DATABASE SETUP") -ForegroundColor Cyan
Write-Host ("Script: $($MyInvocation.MyCommand.Name) | Started: $scriptStartTime") -ForegroundColor Yellow
Write-Host ("=" * 80)

# --- Load Environment Configuration ---
Write-Host "Loading environment variables from .env file..." -ForegroundColor DarkGray
$null = Import-DotEnv

# --- Determine Effective Environment Type ---
# Uses -EnvType parameter if provided, otherwise falls back to ENV_TYPE from .env
$effectiveEnvType = $null
if ($PSBoundParameters.ContainsKey('EnvType')) {
    $effectiveEnvType = $EnvType.ToLower()
} else {
    $effectiveEnvType = $env:ENV_TYPE.ToLower()
    if (-not $effectiveEnvType) {
        throw "Environment Type not specified via -EnvType parameter and ENV_TYPE is missing or empty in .env file."
    }
}

# --- Determine Authentication Method First ---
$authMethodToUse = $AuthMethod
if (-not $authMethodToUse) {
    # Apply defaults based on environment
    if ($effectiveEnvType -eq "onprem") {
        $authMethodToUse = 'windows'
    } elseif ($effectiveEnvType -eq "azure") {
        $authMethodToUse = 'sql' # Default for Azure
    }
} else {
    $authMethodToUse = $AuthMethod.ToLower() # Ensure lowercase for consistent comparison
}

# --- Environment-Specific AuthMethod Validation ---
if ($effectiveEnvType -eq 'azure' -and $authMethodToUse -ne 'sql') {
    throw "Invalid -AuthMethod '$authMethodToUse' for Azure. Only 'sql' authentication is allowed."
}

if ($effectiveEnvType -eq "onprem" -and ($authMethodToUse -ne 'windows' -and $authMethodToUse -ne 'sql')) { 
    throw "Invalid -AuthMethod '$authMethodToUse' for on-premises. Allowed: 'windows', 'sql'." 
}

# --- Determine Target Server ---
# Uses -ServerInstance parameter if provided, otherwise uses environment variable
$targetServer = $ServerInstance
if (-not $targetServer) {
    if ($effectiveEnvType -eq "onprem") {
        $targetServer = $env:ONPREM_SERVER
        if (-not $targetServer) { throw "ServerInstance parameter not provided, and ONPREM_SERVER environment variable is missing or empty for ENV_TYPE=onprem." }
    } elseif ($effectiveEnvType -eq "azure") {
        $targetServer = $env:AZURE_SERVER
        if (-not $targetServer) { throw "ServerInstance parameter not provided, and AZURE_SERVER environment variable is missing or empty for ENV_TYPE=azure." }
    }
}

# --- Determine Target Database ---
# Uses -DatabaseName parameter if provided, otherwise uses environment variable
$targetDatabase = $DatabaseName
if (-not $targetDatabase) {
    if ($effectiveEnvType -eq "onprem") {
        $targetDatabase = $env:ONPREM_DATABASE
        if (-not $targetDatabase) { throw "DatabaseName parameter not provided, and ONPREM_DATABASE environment variable is missing or empty for ENV_TYPE=onprem." }
    } elseif ($effectiveEnvType -eq "azure") {
        $targetDatabase = $env:AZURE_DATABASE
        if (-not $targetDatabase) { throw "DatabaseName parameter not provided, and AZURE_DATABASE environment variable is missing or empty for ENV_TYPE=azure." }
    }
}

# --- Determine Authentication Method and Credentials ---
# Selects authentication method and credentials based on environment and parameters
$username = $null; $password = $null

# Get credentials based on effective auth method
$sqlParams = @{ ErrorAction = 'Stop' }
$connectionString = $null

switch ($effectiveEnvType) {
    "onprem" {
        switch ($authMethodToUse) {
            'windows' {
                $connectionString = "Server=$targetServer;Database=$targetDatabase;Integrated Security=True;TrustServerCertificate=True"
                $sqlParams.Clear()
                $sqlParams.Add('ConnectionString', $connectionString)
                $sqlParams.Add('ErrorAction', 'Stop')
            }
            'sql' {
                # Get login/password (parameter > env var)
                $username = $SqlLogin
                if (-not $username) {
                    $username = $env:ONPREM_SQL_LOGIN
                    if (-not $username) { throw "On-prem SQL Authentication requested but login not found. Provide -SqlLogin or set ONPREM_SQL_LOGIN." }
                }
                $password = $SqlPassword
                if (-not $password) {
                    $password = $env:ONPREM_SQL_PASSWORD
                    if (-not $password) { throw "On-prem SQL Authentication requested but password not found. Provide -SqlPassword or set ONPREM_SQL_PASSWORD." }
                }
                
                $safePassword = $password -replace "'", "''" # Escape single quotes in password
                $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;TrustServerCertificate=True"
                $sqlParams.Clear()
                $sqlParams.Add('ConnectionString', $connectionString)
                $sqlParams.Add('ErrorAction', 'Stop')
            }
        }
    }
    "azure" {
        switch ($authMethodToUse) {
            'sql' {
                 $username = $SqlLogin
                 if (-not $username) {
                     $username = $env:AZURE_SQL_LOGIN
                     if (-not $username) { throw "Azure SQL Authentication requested but login not found. Provide -SqlLogin or set AZURE_SQL_LOGIN." }
                 }
                 $password = $SqlPassword
                 if (-not $password) {
                     $password = $env:AZURE_SQL_PASSWORD
                     if (-not $password) { throw "Azure SQL Authentication requested but password not found. Provide -SqlPassword or set AZURE_SQL_PASSWORD." }
                 }
                 
                 $safePassword = $password -replace "'", "''" # Escape single quotes
                 # Use Encrypt=True for potentially better compatibility with Invoke-Sqlcmd -ConnectionString
                 $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;Encrypt=True;TrustServerCertificate=True;Integrated Security=False"
                 $sqlParams.Clear()
                 $sqlParams.Add('ConnectionString', $connectionString)
                 $sqlParams.Add('ErrorAction', 'Stop')
             }
        }
    }
}

# --- Print summary of target and environment ---
Write-Host ("Target Server: $targetServer") -ForegroundColor Green
Write-Host ("Target Database: $targetDatabase") -ForegroundColor Green
Write-Host ("Environment: $effectiveEnvType | Auth: $authMethodToUse") -ForegroundColor Green
Write-Host ("=" * 80)

# --- Define SQL Scripts to Execute ---
# List of setup scripts to run in order
$scriptBasePath = Join-Path $PSScriptRoot "setup" 
$sqlScripts = @(
    "drop_objects.sql",           # Ensure idempotency by dropping all objects first
    "create_schemas.sql",
    "create_table_raw.sql",
    "create_table_map.sql",
    "create_table_staging.sql",
    "create_table_prod.sql",
    "create_view.sql"
)

# --- Main Script Execution ---
Write-Host ("Executing $($sqlScripts.Count) SQL scripts...") -ForegroundColor Cyan
$stepNum = 1

# Build connection string using our new standardized function
try {
    $connectionParams = @{
        ServerInstance = $targetServer
        DatabaseName = $targetDatabase
        EnvType = $effectiveEnvType
        AuthMethod = $authMethodToUse
    }
    
    # Add credentials if needed
    if ($authMethodToUse -eq 'sql') {
        $connectionParams['Username'] = $username
        $connectionParams['Password'] = $password
    }
    
    # Create the connection string
    $connectionString = New-SqlConnectionString @connectionParams
    Write-Verbose "Connection string created successfully"
} catch {
    Write-StoryzeError -Message "Failed to create connection string" -ErrorRecord $_ -Fatal
}

foreach ($scriptName in $sqlScripts) {
    $scriptPath = Join-Path $scriptBasePath $scriptName
    $stepMsg = "Step $stepNum : Running script : '$scriptName'... "
    Write-Host $stepMsg -NoNewline -ForegroundColor Cyan
    
    if (-not (Test-Path $scriptPath)) {
        Write-Host "FAILED (Not Found)" -ForegroundColor Red
        Write-StoryzeError -Message "Script file not found: '$scriptPath'" -Fatal
    }
    
    try {
        # Use our new Invoke-SqlFile function instead of Invoke-Sqlcmd
        $result = Invoke-SqlFile -ConnectionString $connectionString -FilePath $scriptPath -CommandTimeout 300
        Write-Host "SUCCESS" -ForegroundColor Green
    } catch {
        Write-Host "FAILED" -ForegroundColor Red
        Write-StoryzeError -Message "Error executing script '$scriptName'" -ErrorRecord $_ -Fatal
    }
    
    $stepNum++
}

# --- Script Completion Summary ---
$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime
Write-Host ("=" * 80)
Write-Host ("Script: $($MyInvocation.MyCommand.Name) | Finished: $scriptEndTime") -ForegroundColor Yellow
Write-Host "All SQL scripts executed successfully." -ForegroundColor Green
Write-Host "Total script duration: $($scriptDuration.TotalSeconds.ToString('F2')) seconds." -ForegroundColor Cyan
Write-Host ("=" * 80)