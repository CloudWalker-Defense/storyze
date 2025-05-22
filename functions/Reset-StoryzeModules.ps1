<#
.SYNOPSIS
    Removes specified PowerShell modules from the current session for clean reloading.

.DESCRIPTION
    This function safely removes specified PowerShell modules from the current session,
    allowing for clean reloading of potentially modified modules. It's particularly useful
    when developing or troubleshooting module loading issues within the Storyze environment.

.PARAMETER ModuleNames
    An array of module names to be removed from the current PowerShell session.

.EXAMPLE
    Reset-StoryzeModules -ModuleNames 'SqlServer', 'powershell-yaml'
    
    Removes the SqlServer and powershell-yaml modules from the current session to allow clean reloading.

.EXAMPLE
    Reset-StoryzeModules -ModuleNames 'ImportExcel' -Verbose
    
    Removes the ImportExcel module with verbose output showing the removal process.

.NOTES
    This function is primarily used during development or when troubleshooting module conflicts.
    It handles errors gracefully, continuing to remove other modules even if one fails to be removed.
    The function only attempts to remove modules that are actually loaded, skipping those that aren't present.
#>
function Reset-StoryzeModules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$ModuleNames
    )
    
    foreach ($moduleName in $ModuleNames) {
        if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
            try {
                Write-Verbose "Removing module: $moduleName"
                Remove-Module -Name $moduleName -Force -ErrorAction Stop
                Write-Verbose "Successfully removed module: $moduleName"
            } catch {
                Write-Warning "Failed to remove module '$moduleName'. Error: $($_.Exception.Message)"
            }
        } else {
            Write-Verbose "Module '$moduleName' is not currently loaded."
        }
    }
    
    Write-Verbose "Module reset complete."
}