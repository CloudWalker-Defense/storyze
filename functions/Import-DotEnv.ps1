
function Import-DotEnv {
    <#
    .SYNOPSIS
    Loads environment variables from a .env file.

    .DESCRIPTION
    Parses a .env file containing key=value pairs and sets them as environment variables 
    in the current PowerShell session. This facilitates configuration management by allowing
    environment-specific settings to be stored in a file rather than hardcoded.
    
    Variables already defined in the environment are preserved unless -Force is specified,
    ensuring that runtime environment settings take precedence over file-based configuration.

    .PARAMETER Path
    Path to the .env file. Defaults to ".env" in the current directory.

    .PARAMETER Force
    If specified, overwrites existing environment variables with values from the file.

    .OUTPUTS
    None. This function sets environment variables as a side effect.

    .EXAMPLE
    Import-DotEnv
    # Loads variables from .env in the current directory

    .EXAMPLE
    Import-DotEnv -Path "C:\projects\myapp\.env" -Force
    # Loads variables from the specified file, overwriting any existing variables
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]$Path = ".env",
        
        [Parameter(Mandatory=$false)]
        [switch]$Force
    )
    
    try {
        # Resolve and validate path
        if (-not [System.IO.Path]::IsPathRooted($Path)) {
            $Path = Join-Path (Get-Location).Path $Path
        }
        
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            Write-Warning "Environment file not found: '$Path'. Using existing environment variables only."
            return
        }
        
        Write-Verbose "Loading environment variables from $Path"
        
        # Read the file line by line
        Get-Content -Path $Path | ForEach-Object {
            # Skip comments and empty lines
            if ([string]::IsNullOrWhiteSpace($_) -or $_.StartsWith('#')) {
                return
            }
            
            # Parse the line for key-value pairs
            $line = $_.Trim()
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim()
                
                # Remove quotes around the value if present
                if ($value -match '^[''"](.*)[''"]\s*$') {
                    $value = $Matches[1]
                }
                
                # Set environment variable if not already set or if force
                if (-not (Test-Path Env:\$key) -or $Force) {
                    if ([string]::IsNullOrEmpty($value)) {
                        Write-Verbose "Setting env:$key = [empty string]"
                    } else {
                        Write-Verbose "Setting env:$key = $value"
                    }
                    [Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::Process)
                } else {
                    Write-Verbose "Keeping existing env:$key (use -Force to override)"
                }
            } else {
                Write-Warning "Invalid line in .env file: $_"
            }
        }
        
        Write-Verbose "Environment variables loaded successfully"
        return $true
    } catch {
        Write-Error "Failed to load environment variables from $Path`: $_"
        return $false
    }
}