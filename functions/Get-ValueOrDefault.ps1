<#
.SYNOPSIS
    Returns a value if it exists and is not null/empty, otherwise returns a specified default.

.DESCRIPTION
    This utility function provides null-coalescing behavior for PowerShell, returning the input
    value if it's not null or empty, otherwise returning a specified default value. Useful for
    parameter validation and configuration value handling.

.PARAMETER InputValue
    The value to test. Can be passed via pipeline. If null or empty string, the default will be returned.

.PARAMETER Default
    The default value to return if InputValue is null or empty.

.OUTPUTS
    System.Object
    Returns either the InputValue (if valid) or the Default value.

.EXAMPLE
    $result = Get-ValueOrDefault -InputValue $env:DATABASE_NAME -Default "DefaultDB"
    # Returns environment variable value or "DefaultDB" if not set

.EXAMPLE
    $timeout = $null | Get-ValueOrDefault -Default 30
    # Returns: 30

.EXAMPLE
    $server = Get-ValueOrDefault -InputValue "" -Default "localhost"
    # Returns: "localhost"

.NOTES
    This function treats both $null and empty string ('') as "no value" conditions.
    Supports pipeline input for convenient chaining with other commands.
    Commonly used throughout Storyze for configuration value fallbacks.
#>
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