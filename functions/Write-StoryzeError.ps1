
<#
.SYNOPSIS
Provides standardized error reporting and handling for Storyze scripts.

.DESCRIPTION
Creates consistent, user-friendly error messages across all application components
while providing detailed technical information when needed for troubleshooting.

This function centralizes error handling logic to ensure that users receive appropriate
feedback regardless of which component encounters an error, and that administrators
have access to detailed diagnostic information for resolving issues.

.PARAMETER Message
The primary error message to display to the user.

.PARAMETER ErrorRecord
Optional ErrorRecord object containing detailed exception information for debugging.

.PARAMETER Fatal
If specified, the function will terminate the script execution after displaying the error.

.OUTPUTS
None. This function writes to the console and optionally terminates execution.

.EXAMPLE
Write-StoryzeError -Message "Failed to connect to database"
# Displays: ERROR: Failed to connect to database

.EXAMPLE
try {
    # Some operation
} catch {
    Write-StoryzeError -Message "Operation failed" -ErrorRecord $_ -Fatal
}
# Displays detailed error information and exits

.EXAMPLE
Write-StoryzeError -Message "Configuration file not found" -Fatal
# Displays error and terminates script execution
#>
function Write-StoryzeError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        
        [Parameter(Mandatory=$false)]
        [switch]$Fatal
    )
    
    $errorDetails = if ($ErrorRecord) {
        "  Error Details: " + 
        "  Type: $($ErrorRecord.Exception.GetType().FullName)" + 
        "  Message: $($ErrorRecord.Exception.Message)" + 
        "  Stack Trace: $($ErrorRecord.ScriptStackTrace)"
    } else { "" }
    
    Write-Host "ERROR: $Message $errorDetails" -ForegroundColor Red
    
    if ($Fatal) {
        Write-Host "Fatal error encountered. Exiting with code 1." -ForegroundColor Red
        exit 1
    }
}