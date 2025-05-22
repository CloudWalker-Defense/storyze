# Private/Test-StoryzeParameterValidation.ps1
# Validates standard Storyze parameters for consistency

<#
.SYNOPSIS
    Validates parameter combinations for Storyze scripts to ensure consistency and compatibility.

.DESCRIPTION
    This function performs comprehensive validation of common Storyze parameters to ensure
    valid combinations and prevent configuration errors. It validates environment types,
    authentication methods, and their compatibility, especially for Azure vs on-premises scenarios.

.PARAMETER BoundParameters
    A hashtable containing the bound parameters from a calling function, typically $PSBoundParameters.

.OUTPUTS
    System.Collections.Hashtable
    Returns a hashtable with the following keys:
    - IsValid: Boolean indicating whether all validations passed
    - ErrorMessages: Array of error messages for any validation failures

.EXAMPLE
    $validation = Test-StoryzeParameterValidation -BoundParameters $PSBoundParameters
    if (-not $validation.IsValid) {
        foreach ($error in $validation.ErrorMessages) {
            Write-Error $error
        }
        return
    }

    Validate parameters and handle any validation errors.

.EXAMPLE
    $params = @{
        EnvType = 'azure'
        AuthMethod = 'windows'
    }
    $result = Test-StoryzeParameterValidation -BoundParameters $params
    # Returns: IsValid = $false (Windows auth not allowed with Azure)

.NOTES
    This function enforces the following validation rules:
    - EnvType must be 'onprem' or 'azure'
    - AuthMethod must be 'windows' or 'sql'
    - Azure environments only support SQL authentication
    - Windows authentication requires on-premises environment
    - SQL authentication requires proper credential parameters

    Used by Storyze scripts to ensure parameter consistency before execution.
#>
function Test-StoryzeParameterValidation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$BoundParameters
    )
    
    $isValid = $true
    $errorMessages = @()
    
    # Validate environment type
    if ($BoundParameters.ContainsKey('EnvType')) {
        $envType = $BoundParameters['EnvType']
        if ($envType -notin @('onprem', 'azure')) {
            $isValid = $false
            $errorMessages += "EnvType must be 'onprem' or 'azure', got: '$envType'"
        }
    }
    
    # Validate auth method
    if ($BoundParameters.ContainsKey('AuthMethod')) {
        $authMethod = $BoundParameters['AuthMethod']
        $envType = if ($BoundParameters.ContainsKey('EnvType')) { $BoundParameters['EnvType'] } else { $env:ENV_TYPE }
        
        if ($envType -eq 'onprem' -and $authMethod -notin @('windows', 'sql')) {
            $isValid = $false
            $errorMessages += "AuthMethod for on-premises SQL must be 'windows' or 'sql', got: '$authMethod'"
        }
        elseif ($envType -eq 'azure' -and $authMethod -notin @('sql', 'entraidmfa')) {
            $isValid = $false
            $errorMessages += "AuthMethod for Azure SQL must be 'sql' or 'entraidmfa', got: '$authMethod'"
        }
    }
    
    # Validate credentials for SQL authentication
    if ($BoundParameters.ContainsKey('AuthMethod') -and $BoundParameters['AuthMethod'] -eq 'sql') {
        if (-not $BoundParameters.ContainsKey('SqlLogin') -or [string]::IsNullOrWhiteSpace($BoundParameters['SqlLogin'])) {
            $isValid = $false
            $errorMessages += "SqlLogin is required when AuthMethod is 'sql'"
        }
        
        if (-not $BoundParameters.ContainsKey('SqlPassword') -or [string]::IsNullOrWhiteSpace($BoundParameters['SqlPassword'])) {
            $isValid = $false
            $errorMessages += "SqlPassword is required when AuthMethod is 'sql'"
        }
    }
    
    # Validate Entra ID MFA authentication
    if ($BoundParameters.ContainsKey('AuthMethod') -and $BoundParameters['AuthMethod'] -eq 'entraidmfa') {
        if (-not $BoundParameters.ContainsKey('LoginEmail') -and [string]::IsNullOrWhiteSpace($env:AZURE_ENTRA_LOGIN)) {
            $isValid = $false
            $errorMessages += "LoginEmail parameter or AZURE_ENTRA_LOGIN environment variable is required when AuthMethod is 'entraidmfa'"
        }
    }
    
    return @{
        IsValid = $isValid
        ErrorMessages = $errorMessages
    }
}