
<#
.SYNOPSIS
Retrieves standardized database connection information from environment variables.

.DESCRIPTION
Consolidates and normalizes database connection settings from environment variables 
to provide consistent access to connection details across the application. This function
serves as a central configuration point for all database connections, simplifying
environment-specific deployments and reducing the risk of connection string errors.

This approach allows for deployment flexibility by supporting both on-premises SQL Server
and Azure SQL Database environments through a unified interface.

.OUTPUTS
System.Collections.Hashtable
Returns a hashtable containing connection information with the following keys:
- ServerInstance: The SQL Server instance name or Azure SQL server address
- DatabaseName: The target database name
- AuthMethod: Authentication method ('windows' or 'sql')
- EnvType: Environment type ('onprem' or 'azure')
- Username: SQL authentication username (if applicable)
- Password: SQL authentication password (if applicable)
- LoginEmail: Login email for Azure environments (if applicable)

.EXAMPLE
$connectionInfo = Get-ConnectionInfo
$server = $connectionInfo.ServerInstance
$database = $connectionInfo.DatabaseName

# Retrieves connection information and accesses specific properties.

.EXAMPLE
$connectionInfo = Get-ConnectionInfo
if ($connectionInfo.EnvType -eq 'azure') {
    Write-Host "Azure environment detected"
}

# Retrieves connection information and checks the environment type.
#>
function Get-ConnectionInfo {
    [CmdletBinding()]
    param()
    
    # Initialize with defaults
    $connectionInfo = @{
        ServerInstance = $null
        DatabaseName = $null
        AuthMethod = 'windows'
        EnvType = 'onprem'
        Username = $null
        Password = $null
        LoginEmail = $null
    }
    
    # Get environment variables
    $envType = $env:ENV_TYPE
    $authMethod = $env:AUTH_METHOD
    
    # Set environment type
    if (-not [string]::IsNullOrWhiteSpace($envType)) {
        $connectionInfo.EnvType = $envType.ToLower()
    }
    
    # Set authentication method
    if (-not [string]::IsNullOrWhiteSpace($authMethod)) {
        $connectionInfo.AuthMethod = $authMethod.ToLower()
    }
    
    # Set server and database based on environment type
    if ($connectionInfo.EnvType -eq 'onprem') {
        $connectionInfo.ServerInstance = $env:ONPREM_SQL_SERVER
        $connectionInfo.DatabaseName = $env:ONPREM_SQL_DATABASE
    } else {
        $connectionInfo.ServerInstance = $env:AZURE_SQL_SERVER
        $connectionInfo.DatabaseName = $env:AZURE_SQL_DATABASE
    }
    
    # Set credentials based on auth method
    if ($connectionInfo.AuthMethod -eq 'sql') {
        $connectionInfo.Username = $env:SQL_USERNAME
        $connectionInfo.Password = $env:SQL_PASSWORD
    } elseif ($connectionInfo.AuthMethod -eq 'entraidmfa') {
        $connectionInfo.LoginEmail = $env:AZURE_ENTRA_LOGIN
    }
    
    return $connectionInfo
}