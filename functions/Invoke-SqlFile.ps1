# Public/Invoke-SqlFile.ps1
# Executes a SQL script file with GO batch separators

function Invoke-SqlFile {
    <#
    .SYNOPSIS
    Executes a SQL script file with GO batch separators.

    .DESCRIPTION
    Parses a SQL script file into individual batches separated by GO statements and executes each batch sequentially against the specified SQL Server instance.

    .PARAMETER ConnectionString
    Complete SQL Server connection string. If provided, other connection parameters are ignored.

    .PARAMETER ServerInstance
    SQL Server instance name (when not using ConnectionString).

    .PARAMETER DatabaseName
    Database name to connect to (when not using ConnectionString).

    .PARAMETER AuthMethod
    Authentication method: 'windows' (default for on-premises) or 'sql'.

    .PARAMETER Username
    SQL login name (required when AuthMethod is 'sql').

    .PARAMETER Password
    SQL password (required when AuthMethod is 'sql').

    .PARAMETER EnvType
    Environment type: 'onprem' (default) or 'azure'.

    .PARAMETER FilePath
    Path to the SQL script file to execute.

    .PARAMETER CommandTimeout
    Timeout in seconds for each batch execution. Default is 300 seconds.

    .EXAMPLE
    Invoke-SqlFile -ConnectionString "Server=myserver;Database=mydb;Integrated Security=True" -FilePath "C:\scripts\setup.sql"

    .EXAMPLE
    Invoke-SqlFile -ServerInstance "myserver\instance" -DatabaseName "mydb" -AuthMethod windows -FilePath "C:\scripts\setup.sql"

    .EXAMPLE
    Invoke-SqlFile -ServerInstance "myserver" -DatabaseName "mydb" -AuthMethod sql -Username "user" -Password "pass" -FilePath "C:\scripts\setup.sql"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ParameterSetName="ConnectionString")]
        [string]$ConnectionString,
        
        [Parameter(Mandatory=$true, ParameterSetName="ConnectionParams")]
        [string]$ServerInstance,
        
        [Parameter(Mandatory=$true, ParameterSetName="ConnectionParams")]
        [string]$DatabaseName,
        
        [Parameter(Mandatory=$false, ParameterSetName="ConnectionParams")]
        [ValidateSet('windows', 'sql')]
        [string]$AuthMethod = 'windows',
        
        [Parameter(Mandatory=$false, ParameterSetName="ConnectionParams")]
        [string]$Username,
        
        [Parameter(Mandatory=$false, ParameterSetName="ConnectionParams")]
        [string]$Password,
        
        [Parameter(Mandatory=$false, ParameterSetName="ConnectionParams")]
        [ValidateSet('onprem', 'azure')]
        [string]$EnvType = 'onprem',
        
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        
        [Parameter(Mandatory=$false)]
        [int]$CommandTimeout = 300
    )
    
    # Build connection string if not provided directly
    if ($PSCmdlet.ParameterSetName -eq "ConnectionParams") {
        $connParams = @{
            ServerInstance = $ServerInstance
            DatabaseName = $DatabaseName
            AuthMethod = $AuthMethod
            EnvType = $EnvType
        }
        
        if ($AuthMethod -eq 'sql') {
            $connParams['Username'] = $Username
            $connParams['Password'] = $Password
        }
        
        $ConnectionString = New-SqlConnectionString @connParams
    }
    
    # Validate file exists
    if (-not (Test-Path $FilePath -PathType Leaf)) {
        throw "SQL script file not found: $FilePath"
    }
    
    try {
        # Read and parse script file
        $scriptContent = Get-Content -Path $FilePath -Raw -Encoding UTF8
        $batches = @()
        $reader = New-Object System.IO.StringReader($scriptContent)
        $currentBatch = New-Object System.Text.StringBuilder
        
        # Split script into batches at GO statements
        while (($line = $reader.ReadLine()) -ne $null) {
            $trimmedLine = $line.Trim()
            if ($trimmedLine -match '^GO\s*$') {
                if ($currentBatch.Length -gt 0) {
                    $batches += $currentBatch.ToString().Trim()
                    $null = $currentBatch.Clear()
                }
            } else {
                if (-not $trimmedLine.StartsWith('--')) {
                    $null = $currentBatch.AppendLine($line)
                }
            }
        }
        
        # Add the final batch if not empty
        if ($currentBatch.Length -gt 0) {
            $batches += $currentBatch.ToString().Trim()
        }
        
        Write-Verbose "Parsed SQL file into $($batches.Count) batches."
        
        # Execute each batch
        $sqlConn = $null
        try {
            $sqlObj = New-SqlConnection -ConnectionString $ConnectionString -CommandTimeout $CommandTimeout
            $sqlConn = $sqlObj.Connection
            $sqlCmd = $sqlObj.Command
            
            $sqlConn.Open()
            
            foreach ($batch in $batches) {
                if (-not [string]::IsNullOrWhiteSpace($batch)) {
                    Write-Verbose "Executing SQL batch (${CommandTimeout}s timeout)..."
                    $sqlCmd.CommandText = $batch
                    $rowsAffected = $sqlCmd.ExecuteNonQuery()
                    Write-Verbose "Batch execution complete. Rows affected: $rowsAffected"
                }
            }
            
            return $true
        }
        finally {
            if ($sqlConn -and $sqlConn.State -ne [System.Data.ConnectionState]::Closed) { 
                $sqlConn.Close() 
            }
        }
    }
    catch {
        Write-StoryzeError -Message "Failed to execute SQL file: $FilePath" -ErrorRecord $_ -Fatal:$false
        throw # Re-throw to allow caller to handle
    }
}