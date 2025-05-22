# filepath: d:\cwd-projects\storyze\functions\Invoke-OnPremSqlScript.ps1

<#
.SYNOPSIS
    Executes SQL script files against on-premises SQL Server environments.

.DESCRIPTION
    This function is specialized for executing SQL scripts against on-premises SQL Server
    environments. It handles authentication (Windows or SQL), connection management, and
    script execution with robust error handling for on-prem specific scenarios.

.PARAMETER ServerInstance
    The SQL Server instance name or address (e.g., 'SERVERNAME\INSTANCE' or 'localhost').

.PARAMETER DatabaseName
    The target SQL Server database name.

.PARAMETER AuthMethod
    The authentication method to use: 'windows' for Windows Authentication (default) or
    'sql' for SQL Server Authentication.

.PARAMETER Username
    The SQL authentication username. Required when AuthMethod is 'sql'.

.PARAMETER Password
    The SQL authentication password. Required when AuthMethod is 'sql'.

.PARAMETER FilePath
    The path to the SQL script file to execute.

.PARAMETER StepDescription
    Optional description of this script execution step for logging purposes.

.PARAMETER StepNumber
    Optional numeric step identifier for ordered script execution tracking.

.OUTPUTS
    PSObject
    Returns an object with execution status and any error information.

.EXAMPLE
    Invoke-OnPremSqlScript -ServerInstance "localhost" -DatabaseName "StoryzeDB" -AuthMethod "windows" -FilePath "./scripts/create_tables.sql"
#>

function Invoke-OnPremSqlScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ServerInstance,
        
        [Parameter(Mandatory=$true)]
        [string]$DatabaseName,
          [Parameter(Mandatory=$false)]
        [ValidateSet('windows', 'sql')]
        [string]$AuthMethod = 'windows',
        
        [Parameter(Mandatory=$false)]
        [string]$Username,
          [Parameter(Mandatory=$false)]
        [string]$Password,
        
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        
        [Parameter(Mandatory=$false)]
        [string]$StepDescription,
        
        [Parameter(Mandatory=$false)]
        [int]$StepNumber = 0,
        
        [Parameter(Mandatory=$false)]
        [int]$CommandTimeout = 300
    )
    
    # Format step message if provided
    $stepMsg = ""
    if ($StepNumber -gt 0 -and -not [string]::IsNullOrWhiteSpace($StepDescription)) {
        $fileName = Split-Path -Leaf $FilePath
        $stepMsg = "Step $StepNumber : $StepDescription (Running $fileName)... "
        Write-Host $stepMsg -NoNewline -ForegroundColor Cyan
    }
    
    try {
        # Build parameters for Invoke-SqlFile
        $params = @{
            ServerInstance = $ServerInstance
            DatabaseName = $DatabaseName
            AuthMethod = $AuthMethod
            EnvType = 'onprem'  # Always onprem for this function
            FilePath = $FilePath
            CommandTimeout = $CommandTimeout
        }
        
        # Add authentication parameters based on auth method
        if ($AuthMethod -eq 'sql') {
            $params['Username'] = $Username
            $params['Password'] = $Password
        }
        
        Write-Verbose "Executing SQL file for on-prem: $FilePath"
        Write-Verbose "Parameters: ServerInstance=$ServerInstance, DatabaseName=$DatabaseName, AuthMethod=$AuthMethod"
        
        # Execute the SQL file using the core function
        Invoke-SqlFile @params
        
        # Print success message if step information was provided
        if (-not [string]::IsNullOrWhiteSpace($stepMsg)) {
            Write-Host "SUCCESS" -ForegroundColor Green
        }
        
        return $true
    } 
    catch {
        # Print failure message if step information was provided
        if (-not [string]::IsNullOrWhiteSpace($stepMsg)) {
            Write-Host "FAILED" -ForegroundColor Red
        }
        
        Write-StoryzeError -Message "SQL script execution failed: $(Split-Path -Leaf $FilePath)" -ErrorRecord $_ -Fatal:$false
        throw  # Re-throw to allow caller to handle
    }
}

Export-ModuleMember -Function Invoke-OnPremSqlScript