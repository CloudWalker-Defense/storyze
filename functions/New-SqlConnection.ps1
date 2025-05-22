
<#
.SYNOPSIS
Creates standardized SQL connections with proper timeout configuration.

.DESCRIPTION
Establishes SQL Server connections using the Microsoft.Data.SqlClient provider,
ensuring consistent connection handling throughout the application. This function
manages assembly loading, creates properly configured connections, and returns
ready-to-use connection and command objects with appropriate timeout settings.

This approach provides a single point of control for all database connections,
simplifying maintenance and ensuring consistent error handling across the application.

.PARAMETER ConnectionString
The SQL Server connection string. Should be properly formatted for Microsoft.Data.SqlClient.

.PARAMETER CommandTimeout
The command timeout value in seconds for SQL operations. Default is 30 seconds.

.OUTPUTS
System.Object
Returns a hashtable containing:
- Connection: The Microsoft.Data.SqlClient.SqlConnection object (opened)
- Command: A pre-configured SqlCommand object with the specified timeout

.EXAMPLE
$connectionString = "Server=SQLSERVER01;Database=Storyze;Integrated Security=true;"
$sqlObjects = New-SqlConnection -ConnectionString $connectionString
$connection = $sqlObjects.Connection
$command = $sqlObjects.Command

# Create a connection using Windows Authentication with default timeout.

.EXAMPLE
$connStr = "Server=server.database.windows.net;Database=Storyze;User ID=user;Password=pass;"
$sqlObjects = New-SqlConnection -ConnectionString $connStr -CommandTimeout 60

# Create a connection to Azure SQL Database with extended timeout.
#>
function New-SqlConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ConnectionString,
        
        [Parameter(Mandatory=$false)]
        [int]$CommandTimeout = 30
    )
    
    try {
        # Check if Microsoft.Data.SqlClient is available
        $sqlClientAssembly = [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Data.SqlClient")
        if (-not $sqlClientAssembly) {
            Write-Verbose "Microsoft.Data.SqlClient not loaded, attempting to load from modules directory..."
            
            # Find Microsoft.Data.SqlClient.dll in the modules directory
            $modulesDir = Join-Path $PSScriptRoot "modules"
            $sqlClientDll = Get-ChildItem -Path $modulesDir -Recurse -Filter "Microsoft.Data.SqlClient.dll" | 
                            Select-Object -First 1
            
            if ($sqlClientDll) {
                try {
                    Write-Verbose "Loading Microsoft.Data.SqlClient from: $($sqlClientDll.FullName)"
                    [System.Reflection.Assembly]::LoadFrom($sqlClientDll.FullName) | Out-Null
                } catch {
                    throw "Failed to load Microsoft.Data.SqlClient assembly: $($_.Exception.Message)"
                }
            } else {
                throw "Microsoft.Data.SqlClient assembly not found. Please ensure the SqlServer module is properly installed."
            }
        }
        
        # Create and configure the connection
        $connection = New-Object Microsoft.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $ConnectionString
        
        # Create a command with the default timeout
        $command = $connection.CreateCommand()
        $command.CommandTimeout = $CommandTimeout
        
        return @{
            Connection = $connection
            Command = $command
        }
    }
    catch {
        Write-StoryzeError -Message "Failed to create SQL connection" -ErrorRecord $_ -Fatal:$false
        throw  # Re-throw to allow caller to handle
    }
}