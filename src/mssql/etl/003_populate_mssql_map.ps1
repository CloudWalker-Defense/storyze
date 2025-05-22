<#
.SYNOPSIS
Populates the SQL Server map table with unique, whitelisted object names from raw findings data.

.DESCRIPTION
This script analyzes the cleaned findings data to extract object names, validates them against 
a whitelist, and inserts unique entries into the mapping table. This mapping is critical for
data normalization and consistent tracking across assessments, enabling reliable object-level
reporting and remediation tracking.

The script ensures data quality by:
1. Extracting unique object names from the cleaned findings CSV
2. Validating each name against the whitelist configuration
3. Generating normalized versions of the object names
4. Inserting only new objects that don't already exist in the map table

.PARAMETER ConfigPath
Path to the YAML configuration file. Defaults to 'config.yaml' in the project root.

.PARAMETER Source
The source key within the YAML config's 'sources' section (e.g., 'mssql').

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
$scriptRequiredModules = @('SqlServer', 'powershell-yaml') 
$localModulesPath = Join-Path $projectRoot "Modules"
Initialize-RequiredModules -RequiredModules $scriptRequiredModules -LocalModulesBaseDir $localModulesPath

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
    if (-not $effectiveEnvType) { throw "Environment Type not specified via -EnvType parameter and ENV_TYPE is missing or empty in .env file." }
    Write-Verbose "Using Environment Type from .env file: $effectiveEnvType"
}
if ($effectiveEnvType -ne "onprem" -and $effectiveEnvType -ne "azure") { throw "Invalid effective Environment Type determined: '$effectiveEnvType'. Must be 'onprem' or 'azure'." }

# --- Determine Target Server ---
$targetServer = $ServerInstance 
if (-not $targetServer) {
    $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SERVER' } else { 'AZURE_SERVER' } 
    $targetServer = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue 
    if (-not $targetServer) { throw "ServerInstance parameter not provided, and $envVar environment variable is missing or empty for ENV_TYPE=$effectiveEnvType." } 
    Write-Verbose "Using server instance from $envVar environment variable: $targetServer"
} else { Write-Verbose "Using provided server instance parameter: $targetServer" }

# --- Determine Target Database ---
$targetDatabase = $DatabaseName 
if (-not $targetDatabase) { 
    $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_DATABASE' } else { 'AZURE_DATABASE' } 
    $targetDatabase = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue
    if (-not $targetDatabase) { throw "DatabaseName parameter not provided, and $envVar environment variable is missing or empty for ENV_TYPE=$effectiveEnvType." } 
    Write-Verbose "Using database name from $envVar environment variable: $targetDatabase"
} else { Write-Verbose "Using provided database name parameter: $targetDatabase" }

# --- Determine Authentication Method and Credentials ---
$authMethodToUse = $AuthMethod
$username = $null; $password = $null

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
    # Validation
    if ($effectiveEnvType -eq "onprem" -and ($authMethodToUse -ne 'windows' -and $authMethodToUse -ne 'sql')) { throw "Invalid -AuthMethod '$authMethodToUse' for on-prem." }
    if ($effectiveEnvType -eq "azure" -and ($authMethodToUse -ne 'sql')) { throw "Invalid -AuthMethod '$authMethodToUse' for Azure. Only 'sql' is supported." }
}

# Get credentials ONLY if using SQL Auth
if ($authMethodToUse -eq 'sql') {
    $username = $SqlLogin
    if (-not $username) { 
        $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SQL_LOGIN' } else { 'AZURE_SQL_LOGIN' } 
        $username = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue
        if (-not $username) { throw "SQL Auth: Login missing (-SqlLogin or $($envVar))." } 
        Write-Verbose "Using SQL login from $envVar : $username"
    } else { Write-Verbose "Using -SqlLogin: $username" }
    
    $password = $SqlPassword
    if (-not $password) { 
        $envVar = if ($effectiveEnvType -eq 'onprem') { 'ONPREM_SQL_PASSWORD' } else { 'AZURE_SQL_PASSWORD' } 
        $password = Get-Content "env:\$envVar" -ErrorAction SilentlyContinue
        if (-not $password) { throw "SQL Auth: Password missing (-SqlPassword or $($envVar))." } 
        Write-Verbose "Using SQL pwd from $envVar."
    } else { Write-Verbose "Using -SqlPassword." }
}

# --- Build Connection String (for .NET SqlConnection) --- 
$connectionString = $null
switch ("$effectiveEnvType/$authMethodToUse") { 
    "onprem/windows"   { $connectionString = "Server=$targetServer;Database=$targetDatabase;Integrated Security=True;TrustServerCertificate=True"; Write-Verbose "Auth: Windows Auth (On-Prem)" } 
    "onprem/sql"       { 
        $safePassword = $password -replace "'", "''"
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;TrustServerCertificate=True"; 
        Write-Verbose "Auth: SQL Auth (On-Prem): $username"
    }
    "azure/sql"        { 
        $safePassword = $password -replace "'", "''"
        # Enhanced connection string for Azure SQL Managed Instance
        $connectionString = "Server=$targetServer;Database=$targetDatabase;User ID=$username;Password=$safePassword;Encrypt=True;TrustServerCertificate=True;MultipleActiveResultSets=True;Connection Timeout=60;Integrated Security=False"; 
        Write-Verbose "Auth: SQL Auth (Azure): $username"
        Write-Verbose "Enhanced connection string for Azure SQL MI: Port explicitly included in server address"
    }
    default            { throw "Invalid EnvType/AuthMethod combination." }
}
if (-not $connectionString) { throw "Internal error: Failed to build connection string." }


# --- Function Definitions (Import-Whitelist, Get-PotentialServerName) ---
#region Data Processing Functions

# Loads approved object names from a CSV whitelist file into a case-insensitive HashSet for efficient lookups.
# Requires the CSV to have a single column header named 'ServerName'.
function Import-Whitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, HelpMessage="Full path or path relative to project root for the whitelist CSV file.")]
        [string]$WhitelistPathInput
    )

    $resolvedPathObject = $null
    $attemptedPathForError = $WhitelistPathInput # Path to show in error message
    try {
        if ([System.IO.Path]::IsPathRooted($WhitelistPathInput)) {
            $resolvedPathObject = Resolve-Path -Path $WhitelistPathInput -ErrorAction Stop # Stop if absolute path invalid
            $attemptedPathForError = $resolvedPathObject.Path
        } else {
            # Assume relative to project root ($PSScriptRoot of the module)
            $absolutePath = Join-Path $PSScriptRoot $WhitelistPathInput
            $attemptedPathForError = $absolutePath
            $resolvedPathObject = Resolve-Path -Path $absolutePath -ErrorAction Stop # Stop if relative path invalid
        }
    } catch {
        throw "ERROR: Could not resolve whitelist path specified in config ('$WhitelistPathInput'). Resolved to '$attemptedPathForError'. Error: $($_.Exception.Message)"
    }
    
    if ($null -eq $resolvedPathObject -or -not (Test-Path -Path $resolvedPathObject.ProviderPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "ERROR: Whitelist path resolved to '$($resolvedPathObject.ProviderPath)', but it was not found or is not a file. Check config key 'object_whitelist_file' ('$WhitelistPathInput')."
    }
    
    $actualWhitelistPath = $resolvedPathObject.ProviderPath # Use ProviderPath for consistency and accuracy

    Write-Verbose "Reading whitelist file: $actualWhitelistPath"
    $whitelistData = $null
    $whitelistColName = 'ServerName'

    # Require header and validate
    try {
        $csvConfig = @{ Path = $actualWhitelistPath; Delimiter = ',' }
        if ((Get-Item $actualWhitelistPath).Length -eq 0) {
            throw "Whitelist file '$actualWhitelistPath' is empty."
        }
        $firstLine = (Get-Content $actualWhitelistPath -TotalCount 1).Trim()
        if ($firstLine -notmatch '^(ServerName)(,)?$') {
            throw "Whitelist file must have a single column header named 'ServerName'. Found: '$firstLine'"
        }
        $whitelistData = Import-Csv @csvConfig
        if (-not $whitelistData -or $whitelistData.Count -eq 0) {
            throw "Whitelist file '$actualWhitelistPath' contains no data rows under the 'ServerName' header."
        }
    } catch {
        throw "ERROR: Failed to read or parse whitelist file '$actualWhitelistPath'. Check format, permissions, and content. Error: $($_.Exception.Message)"
    }

    # Create a HashSet for efficient, case-insensitive lookups.
    $whitelistSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Populate the HashSet
    $nullCount = 0
    foreach ($row in $whitelistData) {
        $name = $row.ServerName
        if ($null -ne $name -and $name.ToString().Trim().Length -gt 0) {
            $whitelistSet.Add($name.ToString().Trim()) | Out-Null
        } else {
            $nullCount++
        }
    }
    
    if ($nullCount -gt 0) {
        Write-Warning "$nullCount empty or null values ignored in whitelist file."
    }

    if ($whitelistSet.Count -eq 0) {
        throw "ERROR: No valid, non-empty object names loaded from whitelist file '$actualWhitelistPath'."
    }

    Write-Verbose "Loaded $($whitelistSet.Count) unique object names (case-insensitive) from whitelist column 'ServerName'."
    return $whitelistSet
}

# --- Reverted Extract-PotentialServerName from old script ---
function Get-PotentialServerName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Item,
        [string]$DomainSuffix
    )
    if ([string]::IsNullOrWhiteSpace($Item)) { return $null }

    $name = $Item.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -lt 3) { return $null }

    $nameLower = $name.ToLower()
    # Ensure DomainSuffix is usable for comparison
    $domainSuffixLower = $null
    if (-not [string]::IsNullOrEmpty($DomainSuffix)) {
        $domainSuffixLower = $DomainSuffix.ToLower()
    }

    # --- Pre-filtering (Using hardcoded list from old script) ---
    if ($nameLower -in @('none', 'file', 'errorlog', 'transactionlogfile')) {
        Write-Verbose "Extractor(Old): Ignoring hardcoded keyword '$name'"
        return $null
    }
    if ($nameLower.Contains(':file:') -or $nameLower.Contains(';file:')) {
        Write-Verbose "Extractor(Old): Ignoring file path indicator in '$name'"
        return $null
    }
    # NOTE: The old script didn't explicitly ignore GUIDs like the new one did.

    # Remove '\' onwards if it looks like a path (e.g., Server\C:\) - OLD LOGIC
    $backslashIndex = $name.IndexOf('\')
    if ($backslashIndex -ge 0) {
        # Check if it looks like a drive letter follows (e.g., \C:)
        if ($name.Length -gt ($backslashIndex + 2) -and $name[$backslashIndex + 2] -eq ':') {
            Write-Verbose "Extractor(Old): Found backslash followed by drive letter pattern in '$name'. Taking part before backslash."
            $name = $name.Substring(0, $backslashIndex).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { return $null } # Nothing before backslash
            $nameLower = $name.ToLower() # Update lower version
        } else {
            # Backslash present but not followed by drive letter - likely ignore (e.g., DOMAIN\User)
            Write-Verbose "Extractor(Old): Found backslash NOT followed by drive letter pattern in '$name'. Ignoring."
            return $null
        }
    }

    # Handle Remove ':' onwards, unless it's a drive letter like C: - OLD LOGIC
    $colonIndex = $name.IndexOf(':') # Note: Old script used IndexOf, not LastIndexOf
    if ($colonIndex -ge 0) {
        # Exclude potential drive letters C: etc. (check if colon is the second char)
        if (-not ($name.Length -gt 1 -and $colonIndex -eq 1)) {
            Write-Verbose "Extractor(Old): Found colon (not drive letter) in '$name'. Taking part before colon."
            $name = $name.Substring(0, $colonIndex).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { return $null }
            $nameLower = $name.ToLower()
        }
        # If it IS a drive letter (like C:), we likely want to discard it anyway
        elseif ($colonIndex -eq 1) {
             Write-Verbose "Extractor(Old): Ignoring '$name' as it looks like a drive letter."
             return $null # Explicitly ignore drive letters
        }
    }

    # Handle Remove '.' onwards (domain part) - OLD LOGIC
    $hostname = $null
    if (-not [string]::IsNullOrWhiteSpace($domainSuffixLower) -and $nameLower.EndsWith($domainSuffixLower)) {
        Write-Verbose "Extractor(Old): Removing configured domain suffix '$DomainSuffix' from '$name'."
        $hostname = $name.Substring(0, $name.Length - $DomainSuffix.Length).TrimEnd('.') # Also trim trailing dot
    } elseif ($name.Contains('.')) { # If not specific domain suffix, take part before first dot
        Write-Verbose "Extractor(Old): Found dot in '$name' (no suffix match). Taking part before first dot."
        $hostname = $name.Split('.')[0]
    } else {
        $hostname = $name # No domain found, use the whole name
    }

    if ([string]::IsNullOrWhiteSpace($hostname)) {
        Write-Verbose "Extractor(Old): Hostname became empty after processing '$Item'."
        return $null
    }

    # --- Final Validation: Does the result look like a server/instance name? --- OLD LOGIC
    # Simple check: Alphanumeric and hyphens allowed. Avoid names ending in 'db' (unless 'DBL').
    $hostnameLower = $hostname.ToLower()
    if (($hostname -match '^[a-zA-Z0-9-]+$') -and `
        ( (-not ($hostnameLower.EndsWith('db'))) -or ($hostname.ToUpper().EndsWith('DBL')) ) ) {
        Write-Verbose "Extractor(Old): SUCCESS - Final -> '$hostname' (from '$Item')"
        # Old script returned mixed case, let's stick to UPPER for consistency with rest of script
        return $hostname.ToUpper()
    }

    Write-Verbose "Extractor(Old): FAILED final validation -> '$hostname' (from '$Item')"
    return $null
}
#endregion

# --- Main Processing Function (Refactored to accept connection string) ---
function Update-MapTableFromWhitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [hashtable]$Config,        
        [Parameter(Mandatory=$true)] [string]$ConnectionString, # Use connection string
        [Parameter(Mandatory=$true)] [hashtable]$GlobalSettings 
    )
    # Extract relevant configuration parameters
    $inputCsvPathStr = $Config.csv_clean_file
    $mapSchema = $Config.map_schema
    $mapTable = $Config.map_table # Reads 'map_table' key from config
    $sourceObjectCol = $Config.source_object_column # Column in CSV containing potential object names
    $whitelistPathStrRaw = $Config.object_whitelist_file
    $mapTargetCol = $Config.map_target_column # Column in map table to insert names into
    
    # Get extractor ignore keywords from config, default to empty list if missing, convert to lowercase
    $extractorIgnoreKeywords = @()
    if ($Config.ContainsKey('extractor_ignore_keywords')) {
        $configValue = $Config.extractor_ignore_keywords
        # More robust check: is it a collection but not just a string?
        if ($configValue -is [System.Collections.IEnumerable] -and $configValue -isnot [string]) { 
            $extractorIgnoreKeywords = $configValue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLower() }
        } elseif (-not [string]::IsNullOrWhiteSpace($configValue)) {
            # Handle single string case explicitly if it's NOT a collection
            $extractorIgnoreKeywords = @($configValue.ToLower())
            # Keep the warning here, as it *is* unexpected if it's just a string
            Write-Warning "Config 'extractor_ignore_keywords' should be an array/list, but a single string was found. Using it." 
        } # If it's null/empty/whitespace or some other type, it defaults to @()
    }
    Write-Verbose "Using Extractor Ignore Keywords (lowercase): $($extractorIgnoreKeywords -join ', ')"
    
    # Get batch size for map inserts from global settings
    $batchSize = 1000 # Default batch size
    if ($GlobalSettings.ContainsKey('batch_size_map_insert')) {
        try {
            $configValue = $GlobalSettings.batch_size_map_insert
            if (-not [string]::IsNullOrWhiteSpace($configValue)) {
                $parsedValue = [int]$configValue
                if ($parsedValue -gt 0) { $batchSize = $parsedValue } else { Write-Warning "Global config 'batch_size_map_insert' ($($configValue)) not positive. Using default: $batchSize." }
            }
        } catch { Write-Warning "Failed to parse global config 'batch_size_map_insert' ('$($configValue)'). Error: $($_.Exception.Message). Using default: $batchSize." }
    } # Else: Use default
    Write-Verbose "Using Map Insert Batch Size: $batchSize"
    
    # Get domain suffix from global settings (optional)
    $domainSuffix = $GlobalSettings.domain_suffix # Can be null/empty
    if ([string]::IsNullOrWhiteSpace($domainSuffix)) {
        Write-Verbose "Global setting 'domain_suffix' is not defined or empty. FQDN stripping in extractor might be limited."
    }

    # Validate mandatory config keys existence
    foreach($key in @('csv_clean_file', 'map_schema', 'map_table', 'source_object_column', 'object_whitelist_file', 'map_target_column')) {
        if (-not $Config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Config[$key])) {
            throw "Required configuration key '$key' is missing or empty in the source config."
        }
    }

    # --- Resolve and Validate Input CSV Path (relative to project root) --- 
    $resolvedCsvPathObject = $null
    $attemptedCsvPathForError = $inputCsvPathStr
    try {
        # Assume relative path is relative to project root (where StoryzeUtils.psm1 is)
        if (-not [System.IO.Path]::IsPathRooted($inputCsvPathStr)) {
            $inputCsvPathStr = Join-Path $PSScriptRoot $inputCsvPathStr
            $attemptedCsvPathForError = $inputCsvPathStr # Update path shown in error
        }
        $resolvedCsvPathObject = Resolve-Path -Path $inputCsvPathStr -ErrorAction Stop
    } catch {
        throw "ERROR: Could not resolve input CSV path specified in config ('$($Config.csv_clean_file)'). Resolved to '$attemptedCsvPathForError'. Error: $($_.Exception.Message)"
    }
    if ($null -eq $resolvedCsvPathObject -or -not (Test-Path -Path $resolvedCsvPathObject.ProviderPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "ERROR: Input CSV path resolved to '$($resolvedCsvPathObject.ProviderPath)', but it was not found or is not a file. Check config key 'csv_clean_file' ('$($Config.csv_clean_file)')."
    }
    $actualInputCsvPath = $resolvedCsvPathObject.ProviderPath
    Write-Verbose "Validated Input Clean CSV Path: $actualInputCsvPath"

    # --- Resolve and Validate Whitelist Path --- (Whitelist path is resolved inside Import-Whitelist)
    # No change needed here, Import-Whitelist handles its own path validation now.

    # Get relevant timeouts from global settings, applying robust defaults
    $connectTimeout = 30
    if ($GlobalSettings.ContainsKey('sql_connect_timeout')) {
        try {
            $configValue = $GlobalSettings.sql_connect_timeout
            if (-not [string]::IsNullOrWhiteSpace($configValue)) {
                $parsedValue = [int]$configValue
                if ($parsedValue -gt 0) { $connectTimeout = $parsedValue } else { Write-Warning "Config 'sql_connect_timeout' ($($configValue)) not positive. Using default: $connectTimeout." }
            }
        } catch { Write-Warning "Failed to parse config 'sql_connect_timeout' ('$($configValue)'). Error: $($_.Exception.Message). Using default: $connectTimeout." }
    } # Else: Use default
    Write-Verbose "Using Connect Timeout: $connectTimeout seconds"
    
    $mapReadTimeout = 120
    if ($GlobalSettings.ContainsKey('sql_cmd_timeout_map_read')) {
        try {
            $configValue = $GlobalSettings.sql_cmd_timeout_map_read
            if (-not [string]::IsNullOrWhiteSpace($configValue)) {
                $parsedValue = [int]$configValue
                if ($parsedValue -gt 0) { $mapReadTimeout = $parsedValue } else { Write-Warning "Config 'sql_cmd_timeout_map_read' ($($configValue)) not positive. Using default: $mapReadTimeout." }
            }
        } catch { Write-Warning "Failed to parse config 'sql_cmd_timeout_map_read' ('$($configValue)'). Error: $($_.Exception.Message). Using default: $mapReadTimeout." }
    } # Else: Use default
    Write-Verbose "Using Map Read Timeout: $mapReadTimeout seconds"

    $mapWriteTimeout = 120
    if ($GlobalSettings.ContainsKey('sql_cmd_timeout_map_write')) {
        try {
            $configValue = $GlobalSettings.sql_cmd_timeout_map_write
            if (-not [string]::IsNullOrWhiteSpace($configValue)) {
                $parsedValue = [int]$configValue
                if ($parsedValue -gt 0) { $mapWriteTimeout = $parsedValue } else { Write-Warning "Config 'sql_cmd_timeout_map_write' ($($configValue)) not positive. Using default: $mapWriteTimeout." }
            }
        } catch { Write-Warning "Failed to parse config 'sql_cmd_timeout_map_write' ('$($configValue)'). Error: $($_.Exception.Message). Using default: $mapWriteTimeout." }
    } # Else: Use default
    Write-Verbose "Using Map Write Timeout: $mapWriteTimeout seconds"
    
    Write-Verbose "Timeouts (seconds) - Connect: $connectTimeout, Map Read: $mapReadTimeout, Map Write: $mapWriteTimeout"

    $targetMapTableFull = "[$mapSchema].[$mapTable]"
    $mapNameColQuoted = "[$mapTargetCol]"

    Write-Verbose "Task: Populate Object Map Table (Filtered by Whitelist)"
    Write-Verbose "Input Cleaned CSV  : $actualInputCsvPath" # Use validated path
    Write-Verbose "Source Name Column : '$sourceObjectCol'"
    Write-Verbose "Whitelist File     : $whitelistPathStrRaw" # Show configured path; Import-Whitelist shows resolved
    Write-Verbose "Target Map Table   : $targetMapTableFull"
    Write-Verbose "Target Map Column  : $mapNameColQuoted"
    Write-Verbose "Insert Batch Size  : $batchSize"
    Write-Verbose "Domain Suffix Used : $(if ([string]::IsNullOrEmpty($domainSuffix)){ '<None Provided>'} else {$domainSuffix})"

    # --- Load Whitelist --- (Pass raw path, function resolves)
    $whitelistSet = Import-Whitelist -WhitelistPathInput $whitelistPathStrRaw 
    
    # --- Read Distinct, Processed Object Names from Input CSV --- 
    Write-Verbose "Reading and processing distinct potential object names from '$actualInputCsvPath' (Column: '$sourceObjectCol')..." # Use validated path
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $potentialObjectsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $processedRowCount = 0
    $extractedCount = 0
    # Use effective domain suffix determined earlier (passed into Populate-MapTableFromWhitelist, stored in $Config.domain_suffix)
    $effectiveDomainSuffix = $Config.domain_suffix
    try {
        # Use TextFieldParser for robust CSV reading
        Add-Type -AssemblyName Microsoft.VisualBasic
        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($actualInputCsvPath) # Use validated path
        $parser.SetDelimiters(",")
        $parser.HasFieldsEnclosedInQuotes = $true

        if ($parser.EndOfData) { throw "Input CSV file '$actualInputCsvPath' is empty." } # Use validated path

        $headers = $parser.ReadFields()
        $targetColIndex = [array]::IndexOf($headers, $sourceObjectCol)
        if ($targetColIndex -lt 0) {
            throw "Source column '$sourceObjectCol' not found in CSV header: $($headers -join ', ')"
        }
        Write-Verbose "Source column '$sourceObjectCol' found at index $targetColIndex."

        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            $processedRowCount++
            if ($fields.Length -gt $targetColIndex) {
                $rawName = $fields[$targetColIndex]
                # --- Apply Semicolon Splitting (from old script) ---
                if (-not [string]::IsNullOrWhiteSpace($rawName)) {
                    $items = $rawName.Split(';') | ForEach-Object { $_.Trim().Trim('"') }
                    foreach ($item in $items) {
                        if ($item.Length -ge 3) { # Check length of split item (as per old script)
                            # Call the REVERTED Get-PotentialServerName function
                            $extractedName = Get-PotentialServerName -Item $item -DomainSuffix $effectiveDomainSuffix 
                            if ($extractedName) {
                                # Add the extracted (and uppercased) name to the set
                                if ($potentialObjectsSet.Add($extractedName)) { # Add returns $true if item was new
                                    $extractedCount++
                                    Write-Verbose "Added potential object: '$extractedName' (from item '$item' in row $processedRowCount)"
                                }
                            }
                        }
                    }
                }
            }
            if ($processedRowCount % 5000 -eq 0) { Write-Verbose "..processed $processedRowCount CSV rows..." }
        }
    } finally {
        if ($null -ne $parser) { $parser.Close() }
    }
    $stopwatch.Stop()
    Write-Verbose "Processed $processedRowCount rows from CSV and extracted $extractedCount unique potential object names in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds."
    
    if ($potentialObjectsSet.Count -eq 0) {
        Write-Warning "No potential object names could be extracted from the source column '$sourceObjectCol' in the CSV."
        return # Nothing further to do
    }

    # --- Filter potential names against the whitelist ---
    Write-Verbose "Filtering $($potentialObjectsSet.Count) potential names against $($whitelistSet.Count) whitelisted names..."
    
    # Create a new set for the intersection result
    $intersectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Iterate through potential objects and add to intersectedSet if they are in the whitelist
    foreach ($item in $potentialObjectsSet) {
        if ($whitelistSet.Contains($item)) {
            $intersectedSet.Add($item) | Out-Null
        }
    }
    
    $whitelistedNamesCount = $intersectedSet.Count

    Write-Verbose "Found $whitelistedNamesCount unique, whitelisted object names from the CSV data."

    if ($whitelistedNamesCount -eq 0) {
        Write-Warning "No object names from the CSV data were found in the whitelist file."
        return # Nothing further to do
    }

    # --- Get Existing Names from Map Table ---
    $conn = $null
    $cmd = $null
    $reader = $null
    $existingNamesSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Define the SQL query before the try block
    $sqlGetExisting = "SELECT DISTINCT $mapNameColQuoted FROM $targetMapTableFull WHERE $mapNameColQuoted IS NOT NULL;"

    try {
        Write-Verbose "Connecting to database to fetch existing map names..."
        # Use the passed-in connection string directly
        $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
        $conn.Open()

        # SQL Query is already defined above
        Write-Verbose "Executing SQL: $sqlGetExisting"
        $cmd = New-Object System.Data.SqlClient.SqlCommand($sqlGetExisting, $conn)
        $cmd.CommandTimeout = $mapReadTimeout # Use specific map read timeout

        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $existingName = $reader.GetString(0)
            if (-not [string]::IsNullOrEmpty($existingName)) {
                $existingNamesSet.Add($existingName.Trim()) | Out-Null
            }
        }
        Write-Verbose "Found $($existingNamesSet.Count) existing unique names in map table '$targetMapTableFull'."

    } catch {
        # $sqlGetExisting is now guaranteed to be defined here
        throw "Error fetching existing names from map table '$targetMapTableFull'. SQL: '$sqlGetExisting'. Error: $($_.Exception.Message)"
    } finally {
        # Clean up reader, command, and connection (connection closed later)
        if ($null -ne $reader -and -not $reader.IsClosed) { $reader.Close() }
        if ($null -ne $cmd) { $cmd.Dispose() }
        # Keep connection open for inserts
    }

    # --- Determine Names to Insert ---
    # Find names that are in the intersected set BUT NOT already existing in the map table.
    Write-Verbose "Determining new names to insert..."
    # Filter the intersected set
    $namesToInsertList = $intersectedSet | Where-Object { -not $existingNamesSet.Contains($_) }
    
    # Create an empty HashSet with the desired comparer
    $namesToInsert = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Add items from the filtered list to the HashSet (Add method handles uniqueness)
    $namesToInsertList | ForEach-Object { $namesToInsert.Add($_) | Out-Null }

    $insertCount = $namesToInsert.Count
    
    if ($insertCount -eq 0) {
        Write-Verbose "No new whitelisted object names found to insert into the map table."
        # Close connection explicitly here if no inserts are needed
        if ($null -ne $conn -and $conn.State -ne [System.Data.ConnectionState]::Closed) { $conn.Close() }
        return
    }

    Write-Verbose "Identified $insertCount new object names to insert into '$targetMapTableFull'."

    # --- Insert New Names (Row by Row) ---
    Write-Verbose "Inserting $insertCount new names into '$targetMapTableFull' (one by one)..."
    $stopwatchInsert = [System.Diagnostics.Stopwatch]::StartNew()
    $transaction = $null
    $totalRowsInserted = 0
    $cmdInsert = $null

    try {
        # Start transaction for the insert operation
        $transaction = $conn.BeginTransaction("MapInsertTransaction")
        Write-Verbose "Insert transaction started."
        
        # Prepare the single-row insert command ONCE
        $sqlInsert = "INSERT INTO $targetMapTableFull ($mapNameColQuoted) VALUES (@Name);"
        $cmdInsert = New-Object System.Data.SqlClient.SqlCommand($sqlInsert, $conn, $transaction)
        $cmdInsert.CommandTimeout = $mapWriteTimeout # Use specific map write timeout
        # Add the single parameter ONCE
        $paramName = $cmdInsert.Parameters.Add("@Name", [System.Data.SqlDbType]::NVarChar) # Use NVarChar, max length inferred

        # Loop through the guaranteed unique names and insert one by one
        $progressCounter = 0
        foreach ($name in $namesToInsert) { # $namesToInsert is already a unique HashSet
            # Update the value of the single parameter
            $paramName.Value = $name
            # Execute the single-row insert
            $cmdInsert.ExecuteNonQuery() | Out-Null
            $totalRowsInserted++
            $progressCounter++

            # Optional: Log progress periodically (mimicking old batch log)
            if ($progressCounter % $batchSize -eq 0) { 
                Write-Verbose "..inserted $progressCounter / $insertCount rows..."
            }
        }

        # Commit transaction after all rows are inserted
        $transaction.Commit()
        $stopwatchInsert.Stop()
        Write-Verbose "Row-by-row insert completed successfully. Inserted $totalRowsInserted new object names in $($stopwatchInsert.Elapsed.TotalSeconds.ToString('F2')) seconds."

    } catch { # Catch block remains similar
        Write-Error "Error during row-by-row insert operation (around row #$($totalRowsInserted + 1) for value '$($paramName.Value)'). Error: $($_.Exception.Message)"
        if ($null -ne $transaction) {
            try { Write-Warning "Attempting transaction rollback..."; $transaction.Rollback(); Write-Warning "Rollback successful." } catch { Write-Error "Rollback failed: $($_.Exception.Message)" }
        }
        # Re-throw the original exception to be caught by the main script block
        throw
    } finally {
        # Dispose command and transaction, close connection
        if ($null -ne $cmdInsert) { $cmdInsert.Dispose() }
        if ($null -ne $transaction) { $transaction.Dispose() }
        if ($null -ne $conn -and $conn.State -ne [System.Data.ConnectionState]::Closed) { $conn.Close() }
        Write-Verbose "Insert resources disposed and connection closed."
    }
}
#endregion

# --- Main Script Execution ---
$scriptStartTime = Get-Date
Write-Verbose "Starting Script: $($MyInvocation.MyCommand.Name) at $scriptStartTime"

# Define $conn outside try for finally block access
$conn = $null 

try {
    # --- Configuration Loading ---
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
    Write-Verbose "Configuration loaded successfully."

    # --- Execute Main Logic --- 
    Update-MapTableFromWhitelist -Config $sourceConfig -ConnectionString $connectionString -GlobalSettings $globalSettings

    # --- Script Completion --- 
    $scriptEndTime = Get-Date
    $scriptDuration = $scriptEndTime - $scriptStartTime
    Write-Verbose "Script Completed Successfully: $($MyInvocation.MyCommand.Name)"
    Write-Verbose "End Time: $scriptEndTime"
    Write-Verbose "Total Duration: $($scriptDuration.ToString('g'))"
    exit 0

} catch {
    # Centralized error handling for the main script body
    Write-Error "Script [$($MyInvocation.MyCommand.Name)] failed: $($_.Exception.Message)"
    Write-Error "At line: $($_.InvocationInfo.ScriptLineNumber) in script $($_.InvocationInfo.ScriptName)"
    Write-Error ($_.ScriptStackTrace)
    # --- Script Failure --- 
    $scriptEndTime = Get-Date
    $scriptDuration = $scriptEndTime - $scriptStartTime
    Write-Error "Script FAILED: $($MyInvocation.MyCommand.Name)"
    Write-Error "End Time: $scriptEndTime"
    Write-Error "Total Duration: $($scriptDuration.ToString('g'))"
    exit 1 # Exit with a non-zero code to indicate failure
} finally {
    # Add a finally block to ensure connection is closed if opened by the function
    # Note: This assumes the function might leave $conn open. If Populate function *always* closes it, this is redundant.
    if ($null -ne $conn -and $conn.State -ne [System.Data.ConnectionState]::Closed) {
        try {
            Write-Verbose "Closing database connection in main finally block."
            $conn.Close()
        } catch { Write-Warning "Error closing database connection in main finally block: $($_.Exception.Message)" }
    }
}
