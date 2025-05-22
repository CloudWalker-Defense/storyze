<#
.SYNOPSIS
    Converts Excel column letters to their corresponding numeric index.

.DESCRIPTION
    This function converts Excel-style column letters (A, B, ..., Z, AA, AB, etc.) to
    their corresponding 1-based numeric indices (1, 2, ..., 26, 27, 28, etc.). This is
    useful when programmatically accessing Excel columns in the ImportExcel module or
    when processing Excel data with column references.

.PARAMETER ColumnLetter
    The Excel column letter(s) to convert (e.g., 'A', 'AB', 'AAA').
    Must contain only the letters A-Z (case insensitive).

.OUTPUTS
    System.Int32
    Returns the 1-based numeric index of the Excel column.

.EXAMPLE
    Convert-ExcelColumnToNumber -ColumnLetter "A"
    # Returns: 1

.EXAMPLE
    Convert-ExcelColumnToNumber -ColumnLetter "Z"
    # Returns: 26

.EXAMPLE
    Convert-ExcelColumnToNumber -ColumnLetter "AA"
    # Returns: 27

.EXAMPLE
    Convert-ExcelColumnToNumber -ColumnLetter "AAA" -Verbose
    # Returns: 703 with verbose output

.NOTES
    This function uses a base-26 conversion algorithm, treating Excel columns as a
    base-26 numbering system where A=1, B=2, ..., Z=26.
    
    The function throws an error for invalid input (empty strings or non-alphabetic characters).
    
    When used with the -Verbose parameter, the function provides detailed conversion information.
#>
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