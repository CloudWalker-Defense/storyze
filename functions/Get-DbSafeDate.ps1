<#
.SYNOPSIS
    Converts date values to database-safe format, handling null and invalid dates.

.DESCRIPTION
    This function processes date values to ensure they are compatible with SQL Server database operations.
    It handles various null date scenarios, attempts flexible date parsing, and returns appropriate
    database null values when dates cannot be parsed or are considered invalid.

.PARAMETER Value
    The date value to be processed. Can be a string, DateTime object, or other type.

.PARAMETER NullDateStrings
    An array of string values that should be treated as null dates. Default includes '1900-01-01' and empty string.

.OUTPUTS
    System.DateTime or System.DBNull
    Returns a parsed DateTime object if successful, or DBNull if the value is null or unparseable.

.EXAMPLE
    $safeDate = Get-DbSafeDate -Value "2024-01-15"
    # Returns: DateTime object for January 15, 2024

.EXAMPLE
    $safeDate = Get-DbSafeDate -Value "1900-01-01"
    # Returns: [System.DBNull]::Value

.EXAMPLE
    $safeDate = Get-DbSafeDate -Value "invalid-date"
    # Returns: [System.DBNull]::Value (with warning)

.NOTES
    This function is designed to work with SQL Server's date handling requirements.
    It utilizes Get-DbSafeString for initial value cleaning before date parsing.
    Warning messages are generated for unparseable date strings to aid in debugging.
#>
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