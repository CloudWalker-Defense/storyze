# functions/Invoke-AzureSqlScript.ps1
# Executes a SQL script file specifically for Azure SQL Managed Instance environments

<#
.SYNOPSIS
    Executes SQL script files against Azure SQL Database environments.

.DESCRIPTION
    This function is specialized for executing SQL scripts against Azure SQL Database
    environments. It handles authentication, connection management, and script execution
    with appropriate error handling for Azure-specific scenarios such as firewall issues.

.PARAMETER ServerInstance
    The Azure SQL server address (e.g., 'servername.database.windows.net').

.PARAMETER DatabaseName
    The target Azure SQL database name.

.PARAMETER AuthMethod
    The authentication method to use. Only 'sql' authentication is supported for Azure.
    This parameter is included for API consistency with Invoke-OnPremSqlScript.

.PARAMETER Username
    The SQL authentication username for connecting to Azure SQL Database.

.PARAMETER Password
    The SQL authentication password for connecting to Azure SQL Database.

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
    Invoke-AzureSqlScript -ServerInstance "myserver.database.windows.net" -DatabaseName "StoryzeDB" -Username "admin" -Password $securePassword -FilePath "./scripts/create_tables.sql"
#>
function Invoke-AzureSqlScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ServerInstance,
        
        [Parameter(Mandatory=$true)]
        [string]$DatabaseName,
          [Parameter(Mandatory=$false)]
        [ValidateSet('sql')]
        [string]$AuthMethod = 'sql',
        
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
            EnvType = 'azure'  # Always azure for this function
            FilePath = $FilePath
            CommandTimeout = $CommandTimeout
        }
        
        # Add authentication parameters for SQL authentication
        if ($AuthMethod -eq 'sql') {
            $params['Username'] = $Username
            $params['Password'] = $Password
        }
        
        Write-Verbose "Executing SQL file for Azure SQL MI: $FilePath"
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

Export-ModuleMember -Function Invoke-AzureSqlScript