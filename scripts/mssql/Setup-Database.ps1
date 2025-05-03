<#
.SYNOPSIS
Executes a series of SQL scripts sequentially against a specified SQL Server database.

.DESCRIPTION
This script runs the initialization SQL scripts (000 through 005) sequentially to set up 
the database schema, tables, and views required by the Storyze Assessment Tracker. The script 
executes only the initial database setup scripts, not the ETL data processing scripts.

.PARAMETER ServerInstance
The name of the SQL Server instance to connect to (e.g., "localhost", "SERVER\SQLEXPRESS").
If not specified, uses the corresponding env var based on effective EnvType (ONPREM_SERVER or AZURE_SERVER).

.PARAMETER DatabaseName
The name of the database to target.
If not specified, uses the corresponding env var based on effective EnvType (ONPREM_DATABASE or AZURE_DATABASE).

.PARAMETER EnvType
Optional. Specifies the target environment type ('onprem' or 'azure'). 
Overrides the ENV_TYPE setting in the .env file for this run.
If omitted, uses the ENV_TYPE value from the .env file.

.PARAMETER AuthMethod
Specifies the authentication method.
Valid values depend on the effective EnvType:
- For 'onprem': 'windows' (Default), 'sql'.
- For 'azure': 'sql' (Default), 'entraidmfa'.
Defaults appropriately based on the effective EnvType.

.PARAMETER SqlLogin
Optional. The login name used ONLY when -AuthMethod is 'sql'.
Required for 'sql' method if not set in corresponding env vars (ONPREM_SQL_LOGIN / AZURE_SQL_LOGIN).

.PARAMETER SqlPassword
Optional. The password used ONLY when -AuthMethod is 'sql'.
Required for 'sql' method if not set in corresponding env vars (ONPREM_SQL_PASSWORD / AZURE_SQL_PASSWORD).

.PARAMETER LoginEmail
Optional. The email address used ONLY when -AuthMethod is 'entraidmfa' (Azure Entra ID MFA).
Required for 'entraidmfa' method if not set in the AZURE_ENTRA_LOGIN environment variable.

.EXAMPLE
# Run against on-premises using default Windows Auth (reads ENV_TYPE=onprem from .env)
.\Setup-Database.ps1

.EXAMPLE
# Explicitly target on-premises using default Windows Auth (overrides .env)
.\Setup-Database.ps1 -EnvType "onprem"

.EXAMPLE
# Run against on-premises using SQL Auth (reads ENV_TYPE=onprem from .env)
.\Setup-Database.ps1 -AuthMethod "sql"

.EXAMPLE
# Explicitly target on-premises using SQL Auth with explicit credentials (overrides .env)
.\Setup-Database.ps1 -EnvType "onprem" -AuthMethod "sql" -SqlLogin "sa" -SqlPassword "YourPassword"

.EXAMPLE
# Run against Azure using default SQL Auth (reads ENV_TYPE=azure from .env)
# Requires AZURE_SQL_LOGIN/PASSWORD to be set.
.\Setup-Database.ps1 

.EXAMPLE
# Explicitly target Azure using default SQL Auth (overrides .env)
.\Setup-Database.ps1 -EnvType "azure"

.EXAMPLE
# Run against Azure using explicit Entra ID MFA (NOT the default anymore)
.\Setup-Database.ps1 -AuthMethod "entraidmfa" -LoginEmail "user@yourdomain.com"

.EXAMPLE
# Run against Azure using SQL Auth with environment variables
# Assumes ENV_TYPE=azure and AZURE_SQL_LOGIN/AZURE_SQL_PASSWORD are set
.\Setup-Database.ps1 -AuthMethod "sql"

.EXAMPLE
# Run against Azure using SQL Auth with explicit credentials
.\Setup-Database.ps1 -AuthMethod "sql" -SqlLogin "azure_sql_user" -SqlPassword "YourAzureSqlPassword"

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
    
    # Optional: Specify authentication method ('windows', 'sql', 'entraidmfa')
    # Default depends on EnvType (windows for onprem, sql for azure)
    [Parameter(Mandatory=$false)]
    [ValidateSet('windows', 'sql', 'entraidmfa')] 
    [string]$AuthMethod,
    
    # Login name (ONLY used for -AuthMethod 'sql')
    [Parameter(Mandatory=$false)]
    [string]$SqlLogin, 
    
    # Password (ONLY used for -AuthMethod 'sql')
    [Parameter(Mandatory=$false)]
    [string]$SqlPassword,

    # Email address (ONLY used for -AuthMethod 'entraidmfa')
    [Parameter(Mandatory=$false)]
    [string]$LoginEmail
)

# --- Minimal Bootstrapping to find and load StoryzeUtils --- 
# Find the repository root by searching upwards for the utility module.
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
Write-Verbose "Successfully Bootstrapped and Imported StoryzeUtils from: $($utilsModule.Path)"
$projectRoot = $utilsModule.ModuleBase # Use module base as project root
Write-Verbose "Project Root determined as: $projectRoot"
# --- End Bootstrapping --- 

Write-Host "SCRIPT STARTING..." -ForegroundColor Cyan

# --- Prepare Modules ---
# StoryzeUtils already imported by bootstrap
# Remove Az.Accounts dependency
$scriptRequiredModules = @('SqlServer') # Only require SqlServer now
$localModulesPath = Join-Path $projectRoot "Modules"
Initialize-RequiredModules -RequiredModules $scriptRequiredModules -LocalModulesBaseDir $localModulesPath

# --- Load Environment Configuration ---
Write-Host "Loading environment variables from .env file..." -ForegroundColor Cyan
Import-DotEnv

# --- Determine Effective Environment Type ---
# Prioritize -EnvType parameter, then fall back to ENV_TYPE from .env file.
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

# Validate the final effective type
if ($effectiveEnvType -ne "onprem" -and $effectiveEnvType -ne "azure") {
    throw "Invalid effective Environment Type determined: '$effectiveEnvType'. Must be 'onprem' or 'azure'."
}

# --- Determine Target Server ---
# Prioritize -ServerInstance parameter, then use appropriate env var based on $effectiveEnvType.
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
# Prioritize -DatabaseName parameter, then use appropriate env var based on $effectiveEnvType.
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

# --- Main Script Execution ---
$scriptStartTime = Get-Date
Write-Host ("=" * 80)
Write-Host "Starting Script: $($MyInvocation.MyCommand.Name) at $scriptStartTime" -ForegroundColor Yellow
Write-Host ("Executing SQL setup scripts against Server: '$targetServer', Database: '$targetDatabase' (Environment: $effectiveEnvType)")
Write-Host ("=" * 80)

# --- Determine Authentication Method and Credentials ---
$authMethodToUse = $AuthMethod
$username = $null; $password = $null; $userEmail = $null

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
    # Validation logic remains the same (all methods still valid for this script)
    if ($effectiveEnvType -eq "onprem" -and ($authMethodToUse -ne 'windows' -and $authMethodToUse -ne 'sql')) { throw "Invalid -AuthMethod '$authMethodToUse' for on-premises. Allowed: 'windows', 'sql'." }
    if ($effectiveEnvType -eq "azure" -and ($authMethodToUse -ne 'sql' -and $authMethodToUse -ne 'entraidmfa')) { throw "Invalid -AuthMethod '$authMethodToUse' for Azure. Allowed: 'sql', 'entraidmfa'." }
}

# Get credentials based on effective auth method
$sqlParams = @{ ErrorAction = 'Stop' }
$connectionString = $null

switch ($effectiveEnvType) {
    "onprem" {
        switch ($authMethodToUse) {
            'windows' {
                Write-Host "Using Windows Integrated Authentication (On-Premises)" -ForegroundColor Cyan
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
                    Write-Host "Using SQL login from environment (ONPREM_SQL_LOGIN): $username" -FG Green
                } else { Write-Host "Using provided SQL login parameter: $username" -FG Green }
                $password = $SqlPassword
                if (-not $password) {
                    $password = $env:ONPREM_SQL_PASSWORD
                    if (-not $password) { throw "On-prem SQL Authentication requested but password not found. Provide -SqlPassword or set ONPREM_SQL_PASSWORD." }
                    Write-Host "Using SQL password from environment (ONPREM_SQL_PASSWORD)." -FG Green
                } else { Write-Host "Using provided SQL password parameter." -FG Green }
                
                Write-Host "Using SQL Server Authentication (On-Premises) for login: $username" -ForegroundColor Cyan
                # Construct connection string including credentials
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
            'entraidmfa' {
                 # Check for conflicting parameters
                 if ($PSBoundParameters.ContainsKey('SqlLogin') -or $PSBoundParameters.ContainsKey('SqlPassword')) {
                     throw "Invalid parameters: -SqlLogin and -SqlPassword cannot be used when -AuthMethod is 'entraidmfa'. Use -LoginEmail or set AZURE_ENTRA_LOGIN instead."
                 }

                 $userEmail = $LoginEmail
                 if (-not $userEmail) {
                    $userEmail = $env:AZURE_ENTRA_LOGIN
                    # Prompt if still missing
                    if (-not $userEmail) {
                        Write-Warning "Azure Entra ID MFA user email not found in parameter or AZURE_ENTRA_LOGIN."
                        $userEmail = Read-Host "Please enter your Azure AD / Entra ID username (email address)"
                        if (-not $userEmail) { throw "User email is required for Entra ID MFA authentication." }
                    }
                 }
                 
                 # Revert to using ConnectionString for Entra ID MFA, trying Encrypt=True
                 Write-Host "Using Azure Entra ID MFA (Interactive) Auth via Connection String for user: $userEmail" -ForegroundColor Cyan
                 $connectionString = "Server=$targetServer;Database=$targetDatabase;Authentication=ActiveDirectoryInteractive;User ID=$userEmail;Encrypt=True;TrustServerCertificate=True"
                 $sqlParams.Clear() # Ensure clean slate
                 $sqlParams.Add('ConnectionString', $connectionString)
                 $sqlParams.Add('ErrorAction', 'Stop')
            }
            'sql' {
                 $username = $SqlLogin
                 if (-not $username) {
                     $username = $env:AZURE_SQL_LOGIN
                     if (-not $username) { throw "Azure SQL Authentication requested but login not found. Provide -SqlLogin or set AZURE_SQL_LOGIN." }
                     Write-Host "Using SQL login from environment (AZURE_SQL_LOGIN): $username" -FG Green
                 } else { Write-Host "Using provided SQL login parameter: $username" -FG Green }
                 $password = $SqlPassword
                 if (-not $password) {
                     $password = $env:AZURE_SQL_PASSWORD
                     if (-not $password) { throw "Azure SQL Authentication requested but password not found. Provide -SqlPassword or set AZURE_SQL_PASSWORD." }
                     Write-Host "Using SQL password from environment (AZURE_SQL_PASSWORD)." -FG Green
                 } else { Write-Host "Using provided SQL password parameter." -FG Green }
                 
                 Write-Host "Using Azure SQL Authentication for login: $username" -ForegroundColor Cyan
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

# --- Explicitly Import SqlServer Module ---
# Required step: Ensure Invoke-Sqlcmd is available in the current scope.
# Initialize-RequiredModules handles download/discovery, but explicit import is safer here.
try {
    Import-Module SqlServer -ErrorAction Stop
} catch {
    Write-Error "Failed to explicitly import SqlServer module: $($_.Exception.Message)"
    exit 1
}

# --- Define SQL Scripts to Execute ---
# Base path for the SQL setup scripts.
$scriptBasePath = Join-Path $PSScriptRoot "..\..\sql\sql_server" 
# List of setup script filenames in execution order.
$sqlScripts = @(
    "000_create_schemas.sql",
    "001_mssql_create_table_raw.sql",
    "002_mssql_create_table_map.sql",
    "003_mssql_create_table_staging.sql",
    "004_mssql_create_table_prod.sql",
    "005_mssql_create_view.sql"
)

# --- Execute SQL Scripts ---
Write-Host ("Executing $($sqlScripts.Count) SQL scripts...") -ForegroundColor Cyan
foreach ($scriptName in $sqlScripts) {
    $scriptPath = Join-Path $scriptBasePath $scriptName
    Write-Host "Running script: '$scriptName'..." -NoNewline

    if (-not (Test-Path $scriptPath)) {
        Write-Host " FAILED (Not Found)" -ForegroundColor Red
        Write-Error "Script file not found: '$scriptPath'. Stopping execution."
        exit 1 # Stop the script if a file is missing
    }

    try {
        # Execute the SQL script against the target server/database using the connection string
        $iterParams = $sqlParams.Clone() # Now contains ConnectionString, ErrorAction
        $iterParams.Add('InputFile', $scriptPath)

        SqlServer\Invoke-Sqlcmd @iterParams
        
        Write-Host " SUCCESS" -ForegroundColor Green
    } 
    catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Error "Error executing script '$scriptName': $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Error "Inner exception: $($_.Exception.InnerException.Message)"
        }
        Write-Error "Script execution failed. Stopping."
        exit 1 # Stop the script on error
    }
}

# --- Script Completion Summary ---
$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime
Write-Host ("=" * 80)
Write-Host "Script Finished: $($MyInvocation.MyCommand.Name) at $scriptEndTime" -ForegroundColor Yellow
Write-Host "All SQL scripts executed successfully." 
Write-Host "Total script duration: $($scriptDuration.TotalSeconds.ToString('F2')) seconds."
Write-Host ("=" * 80)