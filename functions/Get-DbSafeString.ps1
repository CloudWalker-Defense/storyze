function Get-DbSafeString {
    <#
    .SYNOPSIS
    Converts a string value to a database-safe format.

    .DESCRIPTION
    Ensures consistent handling of string values for SQL operations by trimming whitespace and 
    converting null or empty strings to DBNull.Value for proper database storage.

    .PARAMETER Value
    The string value to process and make database-safe.

    .OUTPUTS
    System.String or System.DBNull
    Returns the trimmed string if the input is valid, or DBNull.Value if null or empty.

    .EXAMPLE
    Get-DbSafeString -Value "  Example  "
    # Returns: "Example"

    .EXAMPLE
    Get-DbSafeString -Value $null
    # Returns: [System.DBNull]::Value
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Value
    )
    
    if ($null -ne $Value -and $Value -is [string] -and $Value.Trim().Length -gt 0) {
        return $Value.Trim()
    } else {
        return [System.DBNull]::Value
    }
}