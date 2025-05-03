<#
.SYNOPSIS
Shared PowerShell functions module for Storyze Assessment Tracker.

.DESCRIPTION
Core utility module providing common functions for the Storyze Assessment Tracker system.
Includes functionality for configuration management, database connections, environment 
variables, and module loading.

.NOTES
ModuleName:  StoryzeUtils.psm1
Author:      CloudWalker Defense LLC
Date:        2025-04-30
License:     MIT License - Copyright (c) 2025 CloudWalker Defense LLC
Location:    Repository Root

.COMPONENT
Core Utilities

.FUNCTIONALITY
- .env File Loading (Import-DotEnv)
- YAML Config Loading (Get-StoryzeConfig)
- SQL Connection Info Generation (Get-ConnectionInfo)
- Dynamic Module Loading (Initialize-RequiredModules)
- Data Cleaning/Validation Helpers (Get-DbSafe*, Get-ValueOrDefault, etc.)

.HISTORY
2025-04-30   CWD        Refined comments and standardized env var names.
2025-04-26   CWD        Initial creation by extracting from other scripts.
#>

# --- Load .env File ---
# Loads key=value pairs from a specified .env file (defaults to ./.env)
# into environment variables for the current PowerShell process.
function Import-DotEnv {
    param($Path = ".env")
    $envPath = Join-Path $PSScriptRoot $Path
    $resolvedPath = Resolve-Path $envPath -ErrorAction SilentlyContinue

    Write-Verbose "Attempting to load .env from: $(if ($resolvedPath) { $resolvedPath.Path } else { $envPath })"
    if (-not $resolvedPath) {
        Write-Warning ".env file not found at path: $envPath"
        return # Don't throw, just warn if .env is missing
    }

    $linesRead = 0
    $varsSet = 0
    Get-Content $resolvedPath.Path | ForEach-Object {
        $linesRead++
        $line = $_.Trim()
        if ($line -like '#*' -or [string]::IsNullOrWhiteSpace($line)) { return }

        $parts = $line -split '=', 2
        if ($parts.Length -eq 2) {
            $key = $parts[0].Trim()
            $value = $parts[1].Trim().Trim('"')
            Write-Verbose "  >> Found Key: '$key', Value: '$value'"
            try {
                [System.Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::Process)
                $varsSet++
                Write-Verbose "  >> Set env var '$key' for current process."
            } catch {
                 Write-Warning "Failed to set environment variable '$key': $($_.Exception.Message)"
            }
        } else {
            Write-Warning "Skipping malformed line in .env: $line"
        }
    }
    Write-Host ".env file processed. Lines read: $linesRead, Variables set: $varsSet" -ForegroundColor DarkCyan
}

# --- Load YAML Configuration ---
# Loads and parses a YAML configuration file from a given path.
# Requires the 'powershell-yaml' module to be loaded beforehand.
function Import-YamlConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    
    Write-Verbose "Validating config path received: $Path"
    if (-not (Test-Path -Path $Path -PathType Leaf -IsValid)) {
        throw "Configuration file path provided is invalid or not found: '$Path'."
    }
    Write-Verbose "Configuration path validated: $Path"

    try {
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
            throw "Required command 'ConvertFrom-Yaml' (from module 'powershell-yaml') not found. Ensure Initialize-RequiredModules was called first."
        }
        
        $config = Get-Content -Path $Path -Raw | ConvertFrom-Yaml -ErrorAction Stop
        if ($null -eq $config) {
            throw "Configuration file '$Path' is empty or invalid YAML format."
        }
        Write-Host "Configuration loaded successfully from: $Path" -ForegroundColor Green
        return $config
    }
    catch [yaml.YamlException] {
        throw "ERROR: Failed to parse YAML file '$Path': $($_.Exception.Message)"
    }
    catch {
        throw "ERROR: Failed to load configuration file '$Path': $($_.Exception.Message)"
    }
}

# --- Get SQL Connection Parameters ---
# Determines SQL connection parameters based on ENV_TYPE and AUTH_METHOD environment variables.
# NOTE: This function is useful for scripts needing a pre-built parameter hashtable.
#       The Setup-Database.ps1 script uses its own logic, prioritizing command-line parameters.
function Get-ConnectionInfo {
    [CmdletBinding()]
    param()
    
    $envType = $env:ENV_TYPE
    if (-not $envType) { $envType = "azure" }
    $envType = $envType.ToLower()
    Write-Verbose "Determined environment type: $envType"
    
    $authMethod = $env:AUTH_METHOD
    if (-not $authMethod) {
        if ($envType -eq "onprem") {
            $authMethod = "integrated" # On-prem default
        } else { # Azure default
            $authMethod = "entraidmfa" 
            Write-Host "No AUTH_METHOD environment variable set for Azure, defaulting to 'entraidmfa' (Entra ID MFA Interactive)." -ForegroundColor Yellow
        }
    }
    $authMethod = $authMethod.ToLower()
    Write-Verbose "Determined authentication method: $authMethod"

    # --- Build Connection Parameter Hashtable --- 
    $connParams = @{}
    switch ($envType) {
        "onprem" {
            $server = $env:ONPREM_SERVER
            $database = $env:ONPREM_DATABASE
            if (-not $server -or -not $database) { throw "Missing required ONPREM_SERVER or ONPREM_DATABASE environment variables for On-Premises." }
            
            # On-Prem Auth Methods
            switch ($authMethod) {
                "integrated" {
                    $connParams = @{ ServerInstance = $server; Database = $database; IntegratedSecurity = $true; TrustServerCertificate=$true }
                    $connParams['ConnectionString'] = "Server=$server;Database=$database;Integrated Security=True;TrustServerCertificate=True"
                    Write-Host "Using On-Prem configuration: Windows Authentication."
                }
                "sqlauth" {
                    $username = $env:ONPREM_SQL_LOGIN 
                    $password = $env:ONPREM_SQL_PASSWORD 
                    if (-not $username -or -not $password) { throw "Missing required ONPREM_SQL_LOGIN or ONPREM_SQL_PASSWORD environment variables for On-Prem SQL Auth." }
                    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
                    $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
                    $connParams = @{ ServerInstance = $server; Database = $database; UserID = $username; Credential = $credential; IntegratedSecurity = $false; TrustServerCertificate=$true }
                    $connParams['ConnectionString'] = "Server=$server;Database=$database;User ID=$username;Password=$password;TrustServerCertificate=True"
                    Write-Host "Using On-Prem configuration: SQL Authentication."
                }
                default { throw "Invalid AUTH_METHOD: '$authMethod' for onprem environment. Allowed: 'integrated', 'sqlauth'." }
            }
        }
        "azure" {
            $server = $env:AZURE_SERVER
            $database = $env:AZURE_DATABASE
            if (-not $server -or -not $database) { throw "Missing required AZURE_SERVER or AZURE_DATABASE environment variables for Azure." }
            
            # Base Azure Params (Encryption mandatory)
            $connParams = @{ ServerInstance = $server; Database = $database; Encrypt = 'Strict'; TrustServerCertificate = $true }

            # Azure Auth Methods
            switch ($authMethod) {
                "entraidmfa" {
                    $username = $env:AZURE_ENTRA_LOGIN 
                    if (-not $username) { throw "Missing required AZURE_ENTRA_LOGIN environment variable for Entra ID MFA auth." }
                    $connParams.Add('Authentication', 'ActiveDirectoryInteractive')
                    $connParams.Add('UserID', $username) 
                    $connParams['ConnectionString'] = "Server=$server;Database=$database;Authentication=ActiveDirectoryInteractive;User ID=$username;Encrypt=Strict;TrustServerCertificate=True"
                    Write-Host "Using Azure configuration: Entra ID MFA (Interactive)."
                }
                "sqlauth" {
                    $username = $env:AZURE_SQL_LOGIN 
                    $password = $env:AZURE_SQL_PASSWORD 
                    if (-not $username -or -not $password) { throw "Missing required AZURE_SQL_LOGIN or AZURE_SQL_PASSWORD environment variables for Azure SQL Auth." }
                    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
                    $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
                    $connParams.Add('UserID', $username) # Note: Invoke-Sqlcmd often uses Credential OR UserID+Password, not both directly, but providing for completeness
                    $connParams.Add('Credential', $credential)
                    $connParams['ConnectionString'] = "Server=$server;Database=$database;User ID=$username;Password=$password;Encrypt=Strict;TrustServerCertificate=True"
                    Write-Host "Using Azure configuration: SQL Authentication."
                }
                # Future: Add 'entraidpassword' using AZURE_ENTRA_LOGIN and a new AZURE_ENTRA_PASSWORD env var?
                default { throw "Invalid AUTH_METHOD: '$authMethod' for Azure environment. Allowed: 'sqlauth', 'entraidmfa'." }
            }
        }
        default {
            throw "Invalid ENV_TYPE: '$envType'. Supported: 'onprem', 'azure'."
        }
    }
    
    if ($connParams.Count -eq 0) { throw "Failed to construct connection parameters." }
    return $connParams
}

# --- Helper Function: Get Value or Default ---
# Returns the input value if it's not null/empty, otherwise returns the default.
function Get-ValueOrDefault {
    param(
        [Parameter(ValueFromPipeline=$true)]
        $InputValue,
        
        [Parameter(Mandatory=$true)]
        $Default
    )
    if ($null -ne $InputValue -and $InputValue -ne '') {
        return $InputValue
    } else {
        return $Default
    }
}

# --- Helper Function: Clean String for DB ---
# Returns trimmed string or DBNull.Value if input is null, empty, or whitespace.
function Get-DbSafeString {
    param($Value)
    if ($null -ne $Value -and $Value -is [string] -and $Value.Trim().Length -gt 0) {
        return $Value.Trim()
    } else {
        return [System.DBNull]::Value
    }
}

# --- Helper Function: Parse Date for DB ---
# Attempts to parse a date string, returning DBNull.Value on failure or for known "null" dates.
function Get-DbSafeDate {
    param(
        $Value,
        [string[]]$NullDateStrings = @('1900-01-01', '') # Explicitly define date strings considered NULL
    )
    $cleanedValue = Get-DbSafeString -Value $Value # Utilizes the DbSafeString function now in the same module
    if ($cleanedValue -is [System.DBNull] -or $cleanedValue -in $NullDateStrings) {
        return [System.DBNull]::Value
    }
    try {
        # Attempt flexible parsing first, then specific format if needed
        $parsedDate = [datetime]$cleanedValue
        # Optional: Check for unreasonably old dates after parsing if needed
        # if ($parsedDate -lt (Get-Date "1950-01-01")) { return [System.DBNull]::Value }
        return $parsedDate
    } catch {
        Write-Warning "Failed to parse date string '$Value'. Returning NULL for database."
        return [System.DBNull]::Value
    }
}

# --- Helper Function: Convert Excel Column Letter to Number ---
# Converts Excel-style column letters (e.g., A, Z, AA) into 1-based numbers.
function Convert-ExcelColumnToNumber {
    param(
        [Parameter(Mandatory=$true, HelpMessage="Excel column letter(s) like 'A', 'AA', etc.")]
        [string]$ColumnLetter
    )
    Write-Verbose "Converting column letter '$ColumnLetter' to 1-based number."
    if ([string]::IsNullOrWhiteSpace($ColumnLetter)) {
        throw "Input column letter cannot be empty."
    }
    $ColumnLetter = $ColumnLetter.ToUpper()
    $number = 0
    $power = 1
    # Process letters from right to left (least significant to most significant)
    for ($i = $ColumnLetter.Length - 1; $i -ge 0; $i--) {
        $char = $ColumnLetter[$i]
        # Validate character
        if ($char -lt 'A' -or $char -gt 'Z') {
            throw "Invalid character '$char' found in column letter '$ColumnLetter'. Only A-Z allowed."
        }

        # Calculate numeric value (A=1, B=2, ... Z=26)
        try {
            # Use ASCII values for conversion
            $charAscii = [System.Text.Encoding]::ASCII.GetBytes($char)[0]
            $baseAscii = [System.Text.Encoding]::ASCII.GetBytes('A')[0]
            $charValue = $charAscii - $baseAscii + 1
        } catch {
            throw "Failed to convert character '$char' to numeric value. Error: $($_.Exception.Message)"
        }

        # Add to total, weighted by position (base 26)
        $number += $charValue * $power
        Write-Verbose "Char '$char' (Value: $charValue), Power: $power, Current Total: $number"

        # Calculate power for the next position (26^1, 26^2, ...), checking for potential overflow
        if ($i -gt 0) { # Avoid multiplying power on the last (leftmost) character
             try {
                 # Use MultiplyExact for explicit overflow check
                 $power = [System.Math]::MultiplyExact($power, 26)
             } catch {
                 throw "Potential overflow detected while calculating power for column '$ColumnLetter'. Column letter might be too long."
             }
        }
    }
    Write-Verbose "Converted '$ColumnLetter' to column number $number."
    return $number
}

# --- Helper Function: Get Integer Config Value Safely ---
# Retrieves and parses a positive integer from a settings object (hashtable/pscustomobject).
# Returns a default value if key is missing, value is invalid, or object is null.
function Get-SafeTimeoutValue {
    param(
        [Parameter(Mandatory=$true)]
        $Settings, # The configuration object (e.g., $globalSettings)

        [Parameter(Mandatory=$true)]
        [string]$Key, # The key to look for (e.g., 'sql_command_timeout')

        [Parameter(Mandatory=$true)]
        [int]$DefaultValue # The default value to return on failure
    )

    if ($null -eq $Settings -or -not $Settings.ContainsKey($Key)) {
        Write-Verbose "Key '$Key' not found in settings or settings object is null. Using default value: $DefaultValue"
        return $DefaultValue
    }

    $configValue = $Settings[$Key]
    if ([string]::IsNullOrWhiteSpace($configValue)) {
         Write-Verbose "Key '$Key' exists but value is empty. Using default value: $DefaultValue"
        return $DefaultValue
    }

    try {
        $parsedValue = [int]$configValue
        if ($parsedValue -gt 0) {
            Write-Verbose "Found and parsed valid value for '$Key': $parsedValue"
            return $parsedValue
        } else {
            Write-Warning "Config value for '$Key' ('$configValue') is not a positive integer. Using default: $DefaultValue."
            return $DefaultValue
        }
    } catch {
        Write-Warning "Failed to parse config value for '$Key' ('$configValue') as an integer. Error: $($_.Exception.Message). Using default: $DefaultValue."
        return $DefaultValue
    }
}

# --- Initialize Required PowerShell Modules ---
# Checks for required modules, attempts to load them from a local path first,
# then system paths. Verifies key commands are available after loading.
function Initialize-RequiredModules {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$RequiredModules,
        [Parameter(Mandatory=$true)]
        [string]$LocalModulesBaseDir
    )

    if (-not (Test-Path -Path $LocalModulesBaseDir)) {
        Write-Verbose "Specified module directory not found at: $LocalModulesBaseDir"
        $projectRoot = (Split-Path -Parent (Split-Path -Parent $LocalModulesBaseDir))
        
        # Use case-insensitive path search for "modules" directory
        $modulesFolder = Get-ChildItem -Path $projectRoot -Directory | 
                        Where-Object { $_.Name -ieq "modules" } | 
                        Select-Object -First 1
                        
        if ($modulesFolder) {
            $LocalModulesBaseDir = $modulesFolder.FullName
            Write-Verbose "Found modules folder at: $LocalModulesBaseDir"
        }
    }
    
    $pathSeparator = [System.IO.Path]::PathSeparator
    if ($LocalModulesBaseDir -and (Test-Path $LocalModulesBaseDir) -and ($env:PSModulePath -notlike "*$LocalModulesBaseDir*")) {
        $env:PSModulePath = $LocalModulesBaseDir + $pathSeparator + $env:PSModulePath
        Write-Verbose "Added modules path to PSModulePath: $LocalModulesBaseDir"
    }

    foreach ($moduleName in $RequiredModules) {
        Write-Verbose "Checking module: $moduleName"
        
        if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
            Write-Verbose "Module '$moduleName' is already loaded."
            continue
        }

        $moduleLoaded = $false
        
        $moduleDir = Get-ChildItem -Path $LocalModulesBaseDir -Directory -Recurse -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -ieq $moduleName } | 
                    Select-Object -First 1
                    
        if ($moduleDir) {
            Write-Verbose "Found local module directory for '$moduleName' at: $($moduleDir.FullName)"
            
            $moduleManifest = Get-ChildItem -Path $moduleDir.FullName -Recurse -Filter "*.psd1" -ErrorAction SilentlyContinue | 
                            Where-Object { $_.Name -ieq "$moduleName.psd1" } | 
                            Select-Object -First 1
            
            if ($moduleManifest -and (Test-Path -Path $moduleManifest.FullName)) {
                Write-Verbose "Found local module manifest for '$moduleName' at: $($moduleManifest.FullName)"
                try {
                    Import-Module -Name $moduleManifest.FullName -Force -ErrorAction Stop
                    
                    if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                        Write-Verbose "Successfully loaded and verified module '$moduleName' from required local path."
                        $moduleLoaded = $true
                    } else {
                        throw "Import-Module for local path '$($moduleManifest.FullName)' completed without error, but module '$moduleName' is still not loaded. Check module integrity."
                    }
                } catch {
                    Write-Warning "Found local module '$moduleName' at '$($moduleManifest.FullName)' but FAILED to import it. Error: $($_.Exception.Message)"
                }
            } else {
                $moduleFile = Get-ChildItem -Path $moduleDir.FullName -Recurse -Filter "$moduleName.psm1" -ErrorAction SilentlyContinue | 
                            Select-Object -First 1
                
                if ($moduleFile -and (Test-Path -Path $moduleFile.FullName)) {
                    Write-Verbose "Found local module script for '$moduleName' at: $($moduleFile.FullName)"
                    try {
                        Import-Module -Name $moduleFile.FullName -Force -ErrorAction Stop
                        
                        if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                            Write-Verbose "Successfully loaded and verified module '$moduleName' from required local path."
                            $moduleLoaded = $true
                        } else {
                            throw "Import-Module for local script '$($moduleFile.FullName)' completed without error, but module '$moduleName' is still not loaded. Check module integrity."
                        }
                    } catch {
                        Write-Warning "Found local module script '$moduleName' at '$($moduleFile.FullName)' but FAILED to import it. Error: $($_.Exception.Message)"
                    }
                } else {
                    Write-Verbose "Module '$moduleName' manifest/script file not found in local module path."
                }
            }
        }

        if (-not $moduleLoaded) {
            Write-Verbose "Attempting to load module '$moduleName' from system paths..."
            try {
                Import-Module -Name $moduleName -ErrorAction Stop
                if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                     Write-Verbose "Successfully loaded and verified module '$moduleName' from system path."
                     $moduleLoaded = $true
                } else {
                    throw "Import-Module for system path for '$moduleName' completed without error, but module is still not loaded."
                }
            } catch {
                $errorMessage = "Required module '$moduleName' could not be loaded."
                $errorMessage += " Not found properly in local path."
                $errorMessage += " Failed to load from system paths (Error: $($_.Exception.Message))."
                $errorMessage += " Please ensure the module exists in the local '$LocalModulesBaseDir/$moduleName/' directory OR is installed system-wide (see docs/setup.md for details)."
                throw $errorMessage
            }
        }
        
        if (-not $moduleLoaded) {
             throw "Failed to make module '$moduleName' available after checking local and system paths."
        }

    }

    Write-Verbose "Performing final verification of required module commands..."
    foreach ($moduleName in $RequiredModules) {
        if (-not (Get-Module -Name $moduleName -ErrorAction SilentlyContinue)) {
             throw "FINAL CHECK FAILED: Module '$moduleName' was reported as loaded, but Get-Module cannot find it."
        }
        if ($moduleName -eq 'SqlServer') {
            if (-not (Get-Command SqlServer\Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                 throw "FINAL CHECK FAILED: Module '$moduleName' appears loaded, but the critical command 'Invoke-Sqlcmd' could not be found within it. Check module integrity or session state."
            }
            Write-Verbose "Verified command 'Invoke-Sqlcmd' is available from module '$moduleName'."
        } 
        if ($moduleName -eq 'powershell-yaml') {
            if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
                 throw "FINAL CHECK FAILED: Module '$moduleName' appears loaded, but the critical command 'ConvertFrom-Yaml' could not be found within it. Check module integrity or session state."
            }
             Write-Verbose "Verified command 'ConvertFrom-Yaml' is available from module '$moduleName'."
        }
        if ($moduleName -eq 'ImportExcel') {
            if (-not (Get-Command Import-Excel -ErrorAction SilentlyContinue)) {
                 throw "FINAL CHECK FAILED: Module '$moduleName' appears loaded, but the critical command 'Import-Excel' could not be found within it. Check module integrity or session state."
            }
             Write-Verbose "Verified command 'Import-Excel' is available from module '$moduleName'."
        }
    }

    Write-Host "Module check complete. All required modules verified." -ForegroundColor DarkGray
}

# --- Module Exports ---
# Explicitly list functions exported by this module.
Export-ModuleMember -Function Import-DotEnv, Import-YamlConfiguration, Get-ConnectionInfo, Get-ValueOrDefault, Get-DbSafeString, Get-DbSafeDate, Convert-ExcelColumnToNumber, Get-SafeTimeoutValue, Initialize-RequiredModules

Write-Verbose "StoryzeUtils module loaded."