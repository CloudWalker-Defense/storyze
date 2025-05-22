# Public/Import-YamlConfiguration.ps1
# Imports a YAML configuration file and returns it as a PowerShell object

<#
.SYNOPSIS
    Imports and parses YAML configuration files for Storyze operations.

.DESCRIPTION
    This function loads YAML configuration files and converts them to PowerShell objects.
    It provides robust path resolution, validation, and error handling for configuration
    management. The function supports both relative and absolute file paths.

.PARAMETER Path
    The path to the YAML configuration file. Default is "config.yaml" in the current directory.
    Supports both relative paths (resolved from current location) and absolute paths.

.OUTPUTS
    System.Object
    Returns the parsed YAML content as a PowerShell object, or $null if file not found or parsing fails.

.EXAMPLE
    $config = Import-YamlConfiguration
    $domainSuffix = $config.global_settings.domain_suffix

    Load the default config.yaml file and access configuration values.

.EXAMPLE
    $config = Import-YamlConfiguration -Path "custom-config.yaml"
    $sources = $config.sources.mssql

    Load a custom configuration file and access specific settings.

.EXAMPLE
    $config = Import-YamlConfiguration -Path "C:\configs\production.yaml"
    if ($config) {
        Write-Host "Configuration loaded successfully"
    }

    Load configuration from an absolute path with validation.

.NOTES
    This function requires the powershell-yaml module to be available.
    If the specified configuration file is not found, a warning is displayed and $null is returned.
    The function handles both file existence and YAML parsing errors gracefully.
#>
function Import-YamlConfiguration {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]$Path = "config.yaml"
    )
    
    try {
        # Resolve and validate path
        if (-not [System.IO.Path]::IsPathRooted($Path)) {
            $Path = Join-Path (Get-Location).Path $Path
        }
        
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            Write-Warning "Configuration file not found: '$Path'. Using default configuration."
            return $null
        }
        
        Write-Verbose "Loading configuration from $Path"
        
        # Ensure the powershell-yaml module is loaded
        $yamlModule = Get-Module -Name 'powershell-yaml' -ListAvailable
        if (-not $yamlModule) {
            throw "Required module 'powershell-yaml' is not installed. Please install it with: Install-Module -Name 'powershell-yaml'"
        }
        
        Import-Module -Name 'powershell-yaml' -ErrorAction Stop
        
        # Read and parse YAML file
        $yamlContent = Get-Content -Path $Path -Raw
        $config = ConvertFrom-Yaml -Yaml $yamlContent -ErrorAction Stop
        
        Write-Verbose "Configuration loaded successfully"
        return $config
    }
    catch {
        Write-StoryzeError -Message "Failed to load configuration from $Path" -ErrorRecord $_ -Fatal:$false
        return $null
    }
}