# Public/New-SqlConnectionString.ps1
# Creates a standardized connection string for SQL Server using Microsoft.Data.SqlClient format

function New-SqlConnectionString {
    <#
    .SYNOPSIS
    Creates a standardized SQL Server connection string.

    .DESCRIPTION
    Generates a properly formatted connection string for SQL Server or Azure SQL with appropriate 
    security settings based on the environment type and authentication method.

    .PARAMETER ServerInstance
    The SQL Server instance name or Azure SQL server address.

    .PARAMETER DatabaseName
    The database name to connect to.

    .PARAMETER AuthMethod
    Authentication method: 'windows' (default for on-premises) or 'sql'.
    Note: Only 'sql' authentication is supported for Azure SQL.

    .PARAMETER Username
    SQL login name (required when AuthMethod is 'sql').

    .PARAMETER Password
    SQL password (required when AuthMethod is 'sql').

    .PARAMETER EnvType
    Environment type: 'onprem' (default) or 'azure'.

    .PARAMETER AdditionalParams
    Additional connection string parameters as a hashtable.

    .EXAMPLE
    New-SqlConnectionString -ServerInstance "localhost\sqlexpress" -DatabaseName "Storyze" -AuthMethod windows

    .EXAMPLE
    New-SqlConnectionString -ServerInstance "myserver.database.windows.net" -DatabaseName "Storyze" -EnvType azure -AuthMethod sql -Username "user" -Password "pass"
    #>
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
        
        [Parameter(Mandatory=$false)]
        [ValidateSet('onprem', 'azure')]
        [string]$EnvType = 'onprem',
        
        [Parameter(Mandatory=$false)]
        [hashtable]$AdditionalParams
    )
    
    # Initialize connection string builder
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    
    # Set basic properties
    $csb["Data Source"] = $ServerInstance
    $csb["Initial Catalog"] = $DatabaseName
    
    # Security configuration based on environment and auth method
    if ($EnvType -eq 'onprem') {
        switch ($AuthMethod) {
            'windows' {
                $csb["Integrated Security"] = $true
                $csb["TrustServerCertificate"] = $true
            }
            'sql' {
                if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
                    throw "Username and Password are required for SQL authentication"
                }
                $csb["Integrated Security"] = $false
                $csb["User ID"] = $Username
                $csb["Password"] = $Password
                $csb["TrustServerCertificate"] = $true
            }
            default {
                throw "Invalid authentication method '$AuthMethod' for on-premises SQL Server. Use 'windows' or 'sql'."
            }
        }
    }
    else { # Azure
        $csb["TrustServerCertificate"] = $true
        $csb["Encrypt"] = $true
        
        # For Azure, only SQL authentication is supported
        if ($AuthMethod -ne 'sql') {
            throw "Invalid authentication method '$AuthMethod' for Azure SQL. Use 'sql'."
        }
        
        if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
            throw "Username and Password are required for SQL authentication"
        }
        $csb["User ID"] = $Username
        $csb["Password"] = $Password
    }
    
    # Add any additional parameters
    if ($AdditionalParams) {
        foreach ($key in $AdditionalParams.Keys) {
            $csb[$key] = $AdditionalParams[$key]
        }
    }
    
    return $csb.ConnectionString
}