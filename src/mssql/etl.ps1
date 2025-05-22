<#
.SYNOPSIS
Runs the full ETL (Extract, Transform, Load) process for Storyze Assessment Tracker.

.DESCRIPTION
Orchestrates the complete ETL pipeline for Microsoft SQL Server assessment findings, 
providing a single entry point for the entire data processing workflow. This script
coordinates all processing steps in the correct sequence to ensure data integrity
throughout the pipeline.

Key features:
- Executes all ETL steps in the proper order with error handling
- Supports both on-premises and Azure SQL environments
- Handles multiple authentication methods securely
- Provides detailed logging and progress reporting

.PARAMETER ConfigPath
Path to the YAML configuration file. Defaults to 'config.yaml' in the repository root.

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
None. This script executes the ETL pipeline as a side effect and writes progress to the console.

.EXAMPLE
# Run the full ETL process using settings from .env
./etl.ps1 -Source mssql

.EXAMPLE
# Run ETL for Azure SQL with explicit authentication
./etl.ps1 -Source mssql -EnvType azure -AuthMethod sql -SqlLogin "user" -SqlPassword "pass"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,

    [Parameter(Mandatory=$true)]
    [string]$Source,

    [Parameter(Mandatory=$false)]
    [ValidateSet('onprem', 'azure')]
    [string]$EnvType,

    [Parameter(Mandatory=$false)]
    [ValidateSet('windows', 'sql')]
    [string]$AuthMethod,

    [Parameter(Mandatory=$false)]
    [string]$ServerInstance,

    [Parameter(Mandatory=$false)]
    [string]$DatabaseName,    [Parameter(Mandatory=$false)]
    [string]$SqlLogin,    [Parameter(Mandatory=$false)]
    [string]$SqlPassword
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = if ($PSBoundParameters.ContainsKey('Verbose')) { 'Continue' } else { 'SilentlyContinue' }

# --- Locate and load StoryzeUtils ---
$repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$utilsPath = Join-Path $repoRoot "StoryzeUtils.psm1"

try {
    Write-Verbose "Importing StoryzeUtils from $utilsPath"
    Import-Module $utilsPath -Force -ErrorAction Stop
} catch {
    Write-Host "ERROR: Failed to import StoryzeUtils from $utilsPath" -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Initialize required modules ---
try {
    Write-Verbose "Initializing required modules..."
    $modulesDir = Join-Path $repoRoot "modules"
    Initialize-RequiredModules -RequiredModules @('SqlServer', 'powershell-yaml') -LocalModulesBaseDir $modulesDir
    Write-Verbose "Required modules initialized successfully."
} catch {
    Write-StoryzeError -Message "Failed to initialize required modules" -ErrorRecord $_ -Fatal
}

# --- Validate parameters ---
$validationResult = $null
$validationResult = Test-StoryzeParameterValidation -BoundParameters $PSBoundParameters
if (-not $validationResult.IsValid) {
    foreach ($errorMsg in $validationResult.ErrorMessages) {
        Write-Host "ERROR: $errorMsg" -ForegroundColor Red
    }
    throw "Parameter validation failed. Please correct the errors above and try again."
}

# Show .env and config.yaml paths
$envPath = Join-Path $repoRoot ".env"
$configPathDefault = Join-Path $repoRoot "config.yaml"
Write-Host "Using .env file: $envPath" -ForegroundColor Cyan
Write-Host "Using config file: $configPathDefault" -ForegroundColor Cyan

# Import environment variables
$null = Import-DotEnv

# Show ENV_TYPE and AUTH_METHOD
$effectiveEnvType = $EnvType
if (-not $effectiveEnvType) { $effectiveEnvType = $env:ENV_TYPE }
if (-not $effectiveEnvType) { $effectiveEnvType = "azure" }
$effectiveAuthMethod = $AuthMethod
if (-not $effectiveAuthMethod) { $effectiveAuthMethod = $env:AUTH_METHOD }
if (-not $effectiveAuthMethod) {
    if ($effectiveEnvType -eq "onprem") { $effectiveAuthMethod = "windows" }
    else { $effectiveAuthMethod = "sql" }
}
Write-Host "Using ENV_TYPE: $effectiveEnvType, AUTH_METHOD: $effectiveAuthMethod" -ForegroundColor Cyan

# Set default config path if not provided
if (-not $PSBoundParameters.ContainsKey('ConfigPath') -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot "config.yaml"
    Write-Verbose "Using default config path: $ConfigPath"
} else {
    try {
        $resolved = Resolve-Path -Path $ConfigPath -ErrorAction Stop
        $ConfigPath = $resolved.Path
        Write-Verbose "Using specified config path: $ConfigPath"
    } catch {
        Write-StoryzeError -Message "Failed to resolve provided ConfigPath '$ConfigPath'" -ErrorRecord $_ -Fatal
    }
}
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Configuration file not found: '$ConfigPath'"
}

# Common parameters for all scripts
$params = @{
    ConfigPath = $ConfigPath
    Source = $Source
}
if ($EnvType) { $params['EnvType'] = $EnvType }
if ($AuthMethod) { $params['AuthMethod'] = $AuthMethod }
if ($ServerInstance) { $params['ServerInstance'] = $ServerInstance }
if ($DatabaseName) { $params['DatabaseName'] = $DatabaseName }
if ($SqlLogin) { $params['SqlLogin'] = $SqlLogin }
if ($SqlPassword) { $params['SqlPassword'] = $SqlPassword }
$params['Verbose'] = $Verbose

# Helper to run SQL scripts
function Invoke-SqlFileStep($stepNum, $desc, $sqlFile, $path) {
    try {
        # Build connection parameters using provided parameters first, falling back to environment variables
        $connParams = @{
            ServerInstance = $ServerInstance
            DatabaseName = $DatabaseName
            FilePath = $path
            StepNumber = $stepNum
            StepDescription = $desc
            CommandTimeout = 300
        }
        
        # If ServerInstance or DatabaseName weren't provided, use environment variables based on env type
        if ([string]::IsNullOrWhiteSpace($connParams.ServerInstance)) {
            $connParams.ServerInstance = if ($effectiveEnvType -eq "onprem") { $env:ONPREM_SERVER } else { $env:AZURE_SERVER }
        }
        
        if ([string]::IsNullOrWhiteSpace($connParams.DatabaseName)) {
            $connParams.DatabaseName = if ($effectiveEnvType -eq "onprem") { $env:ONPREM_DATABASE } else { $env:AZURE_DATABASE }
        }
        
        # Add authentication parameters based on auth method
        if ($effectiveAuthMethod -eq 'sql') {
            $connParams['AuthMethod'] = 'sql'
            $connParams['Username'] = $SqlLogin
            $connParams['Password'] = $SqlPassword
            
            # Only fallback to env vars if parameters aren't provided
            if ([string]::IsNullOrWhiteSpace($connParams.Username)) {
                $connParams.Username = if ($effectiveEnvType -eq "onprem") { $env:ONPREM_SQL_LOGIN } else { $env:AZURE_SQL_LOGIN }
            }
            
            if ([string]::IsNullOrWhiteSpace($connParams.Password)) {
                $connParams.Password = if ($effectiveEnvType -eq "onprem") { $env:ONPREM_SQL_PASSWORD } else { $env:AZURE_SQL_PASSWORD }
            }
        } else {
            $connParams['AuthMethod'] = $effectiveAuthMethod
        }
        
        Write-Verbose "Executing SQL file: $path with connection parameters: ServerInstance=$($connParams.ServerInstance), DatabaseName=$($connParams.DatabaseName), AuthMethod=$($connParams.AuthMethod)"
        
        # Use the appropriate specialized function based on environment type
        # The step information is included in the parameters, so the function will handle output formatting
        if ($effectiveEnvType -eq 'onprem') {
            $null = Invoke-OnPremSqlScript @connParams
        } else {
            $null = Invoke-AzureSqlScript @connParams
        }
    } catch {
        Write-StoryzeError -Message "SQL script execution failed: $sqlFile" -ErrorRecord $_ -Fatal:$false
        throw
    }
}

function Invoke-Ps1ScriptStep($stepNum, $desc, $scriptName, $params) {
    $stepMsg = "Step $stepNum : $desc (Running $scriptName)... "
    Write-Host $stepMsg -NoNewline -ForegroundColor Cyan
    try {
        $null = & (Join-Path $PSScriptRoot "etl/$scriptName") @params
        Write-Host "SUCCESS" -ForegroundColor Green
    } catch {
        Write-Host "FAILED" -ForegroundColor Red
        throw $_
    }
}

# Helper: Build params for each script, checking they exist in the target script
function Get-ParamsForScript($scriptName) {
    # Start with the baseline parameters that are always passed
    $scriptParams = @{
        ConfigPath = $ConfigPath
        Source     = $Source
    }
    
    # Add ALL connection params from the main parameters
    if ($EnvType)        { $scriptParams['EnvType'] = $EnvType }
    if ($AuthMethod)     { $scriptParams['AuthMethod'] = $AuthMethod }
    if ($ServerInstance) { $scriptParams['ServerInstance'] = $ServerInstance }
    if ($DatabaseName)   { $scriptParams['DatabaseName'] = $DatabaseName }
    if ($SqlLogin)       { $scriptParams['SqlLogin'] = $SqlLogin }
    if ($SqlPassword)    { $scriptParams['SqlPassword'] = $SqlPassword }
    
    # Add verbose flag if specified
    if ($PSBoundParameters.ContainsKey('Verbose')) {
        $scriptParams['Verbose'] = $true
    }
    
    # Special handling for 001_clean_findings.ps1 which may have different parameters
    if ($scriptName -eq '001_clean_findings.ps1') {
        # Remove connection parameters that first script might not need
        $keysToRemove = @('EnvType', 'AuthMethod', 'ServerInstance', 'DatabaseName', 'SqlLogin', 'SqlPassword')
        foreach ($key in $keysToRemove) {
            if ($scriptParams.ContainsKey($key)) {
                $scriptParams.Remove($key)
            }
        }
    }
    
    return $scriptParams
}

# Compose SQL Step Message
function Get-SqlStepMessage($stepNum, $desc, $sqlFile) {
    return "Step $stepNum : $desc (Running $sqlFile)"
}

# Build connection-related params only once
$connectionParams = @{ }
if ($PSBoundParameters.ContainsKey('EnvType')) { $connectionParams['EnvType'] = $EnvType }
if ($PSBoundParameters.ContainsKey('AuthMethod')) { $connectionParams['AuthMethod'] = $AuthMethod }
if ($PSBoundParameters.ContainsKey('ServerInstance')) { $connectionParams['ServerInstance'] = $ServerInstance }
if ($PSBoundParameters.ContainsKey('DatabaseName')) { $connectionParams['DatabaseName'] = $DatabaseName }
if ($PSBoundParameters.ContainsKey('SqlLogin')) { $connectionParams['SqlLogin'] = $SqlLogin }
if ($PSBoundParameters.ContainsKey('SqlPassword')) { $connectionParams['SqlPassword'] = $SqlPassword }

Write-Host "=== STORYZE ETL PROCESS ===" -ForegroundColor Cyan

# Run all ETL steps in order
try {
    Invoke-Ps1ScriptStep 1 "Clean Findings" '001_clean_findings.ps1' (Get-ParamsForScript '001_clean_findings.ps1')
    Invoke-Ps1ScriptStep 2 "Load Findings to SQL" '002_load_findings_to_sql.ps1' (Get-ParamsForScript '002_load_findings_to_sql.ps1')
    Invoke-Ps1ScriptStep 3 "Populate MSSQL Map" '003_populate_mssql_map.ps1' (Get-ParamsForScript '003_populate_mssql_map.ps1')
    Invoke-SqlFileStep 4 "Insert Data to Staging" '004_insert_data_staging.sql' (Join-Path $PSScriptRoot "etl/004_insert_data_staging.sql")
    Invoke-SqlFileStep 5 "Update ObjectID and Priority" '005_update_objectid_prio.sql' (Join-Path $PSScriptRoot "etl/005_update_objectid_prio.sql")
    Invoke-Ps1ScriptStep 6 "Load Sample Data" '006_load_sample_data.ps1' (Get-ParamsForScript '006_load_sample_data.ps1')
    Invoke-SqlFileStep 7 "Insert Data to Production" '007_insert_data_prod.sql' (Join-Path $PSScriptRoot "etl/007_insert_data_prod.sql")
    Write-Host "ETL Process Completed Successfully!" -ForegroundColor Green
    exit 0
} catch {
    Write-StoryzeError -Message "ETL process failed" -ErrorRecord $_ -Fatal
}