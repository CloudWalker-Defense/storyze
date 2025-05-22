# Get-SafeTimeoutValue.ps1
# Retrieves integer configuration values safely from settings with validation and defaults

<#
.SYNOPSIS
    Safely retrieves timeout values from configuration objects with validation and defaults.

.DESCRIPTION
    This function retrieves integer timeout values from configuration objects while providing
    validation, reasonable defaults, and verbose reporting. It supports various configuration
    object types (PSCustomObject from YAML, Hashtable, etc.) and handles nested configuration
    structures like global_settings.

.PARAMETER ConfigObject
    The configuration object (typically from Import-YamlConfiguration) containing timeout settings.
    Supports PSCustomObject (from YAML) or Hashtable types.

.PARAMETER Key
    The key name for the timeout setting to retrieve.

.PARAMETER DefaultValue
    The default timeout value to use if the setting is missing or invalid. Defaults to 30 seconds.

.OUTPUTS
    System.Int32
    Returns an integer value representing the timeout in seconds.

.EXAMPLE
    $config = Import-YamlConfiguration
    $timeout = Get-SafeTimeoutValue -ConfigObject $config -Key "command_timeout" -DefaultValue 60
    
    Retrieves the "command_timeout" setting from configuration, defaulting to 60 seconds if not found.

.EXAMPLE
    $config = Import-YamlConfiguration
    $timeout = Get-SafeTimeoutValue $config "bulk_copy_timeout"
    
    Retrieves the "bulk_copy_timeout" setting with the default fallback of 30 seconds.

.NOTES
    This function first checks for a value in the global_settings section of the configuration.
    If not found there, it tries the root level of the configuration object.
    
    This function ensures that timeout values are always valid integers.
    Invalid values are reported verbosely and replaced with the default value.
    Values less than 0 are replaced with the default value.
#>
function Get-SafeTimeoutValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [Alias('Settings')]
        [object]$ConfigObject,

        [Parameter(Mandatory=$true, Position=1)]
        [string]$Key,

        [Parameter(Mandatory=$false, Position=2)]
        [Alias('Default')]
        [int]$DefaultValue = 30
    )

    # Return default if ConfigObject is null
    if ($null -eq $ConfigObject) {
        Write-Verbose "Settings object is null. Using default value: $DefaultValue"
        return $DefaultValue
    }
    
    # Handle different types of configuration objects - focus on global_settings section
    $configValue = $null
    $keyFound = $false
    
    # Check if the ConfigObject is a PSCustomObject (from ConvertFrom-Yaml)
    if ($ConfigObject -is [PSCustomObject]) {
        # First check in global_settings section
        if ($ConfigObject.PSObject.Properties.Name -contains 'global_settings' -and 
            $ConfigObject.global_settings.PSObject.Properties.Name -contains $Key) {
            $configValue = $ConfigObject.global_settings.$Key
            $keyFound = $true
        }
        # Then check in root object
        elseif ($ConfigObject.PSObject.Properties.Name -contains $Key) {
            $configValue = $ConfigObject.$Key
            $keyFound = $true
        }
    }
    # Check if the ConfigObject is a Hashtable or Dictionary
    elseif ($ConfigObject -is [hashtable] -or $ConfigObject -is [System.Collections.IDictionary]) {
        # First check in global_settings section
        if ($ConfigObject.ContainsKey('global_settings') -and 
            $ConfigObject['global_settings'] -is [object] -and
            ($ConfigObject['global_settings'] -is [hashtable] -and $ConfigObject['global_settings'].ContainsKey($Key) -or
             $ConfigObject['global_settings'] -is [PSCustomObject] -and $ConfigObject['global_settings'].PSObject.Properties.Name -contains $Key)) {
            $configValue = $ConfigObject['global_settings'][$Key]
            $keyFound = $true
        }
        # Then check in root object
        elseif ($ConfigObject.ContainsKey($Key)) {
            $configValue = $ConfigObject[$Key]
            $keyFound = $true
        }
    }
    
    # If key wasn't found, return default
    if (-not $keyFound -or $null -eq $configValue -or [string]::IsNullOrWhiteSpace($configValue)) {
        Write-Verbose "Key '$Key' not found or has empty value. Using default: $DefaultValue"
        return $DefaultValue
    }
    
    # Parse and validate the integer value
    try {
        $intValue = [int]$configValue
        if ($intValue -le 0) {
            Write-Warning "Config value for '$Key' ($configValue) must be positive. Using default: $DefaultValue."
            return $DefaultValue
        }
        return $intValue
    }
    catch {
        Write-Warning "Failed to parse config value for '$Key' ($configValue) as integer. Using default: $DefaultValue."
        return $DefaultValue
    }
}