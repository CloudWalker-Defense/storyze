
<#
.SYNOPSIS
Core utility module for the Storyze Assessment Tracker.

.DESCRIPTION
Provides foundational services that enable all components of the Storyze Assessment Tracker
to operate with consistent behavior. This module handles critical infrastructure needs
such as configuration management, database connections, environment settings, and function discovery.

This centralized approach ensures that all scripts maintain consistent behavior
regardless of the environment in which they're executed, reducing the risk of
configuration drift and environment-specific issues.

.NOTES
Version: 1.0.0
Last Updated: May 22, 2025
Author: CloudWalker Defense
#>

# Get the path to this module
$ModulePath = $PSScriptRoot
$FunctionsPath = Join-Path -Path $ModulePath -ChildPath 'functions'

# Get all function files
$FunctionFiles = Get-ChildItem -Path $FunctionsPath -Filter "*.ps1" -ErrorAction SilentlyContinue

# If no files found, display warning
if ($null -eq $FunctionFiles -or $FunctionFiles.Count -eq 0) {
    Write-Warning "No function files found in $FunctionsPath"
} else {
    Write-Verbose "Found $($FunctionFiles.Count) function files in $FunctionsPath"
}

# Dot-source each function file
foreach ($file in $FunctionFiles) {
    try {
        . $file.FullName
        Write-Verbose "Imported $($file.Name)"
    } catch {
        Write-Error "Failed to import $($file.FullName): $_"
    }
}

# Create an array of function names to export 
$Functions = $FunctionFiles | Select-Object -ExpandProperty BaseName

# Export all functions
Export-ModuleMember -Function $Functions -Verbose:$false

Write-Verbose "StoryzeUtils module loaded with $($Functions.Count) functions."