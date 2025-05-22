<#
.SYNOPSIS
Cleans and exports MSSQL security findings from Excel to CSV for database loading.

.DESCRIPTION
Performs the initial data preparation step in the ETL pipeline by extracting raw assessment
data from Excel, cleaning it for consistency, and producing a standardized CSV file for
further processing. This ensures that all downstream processes work with validated, 
properly formatted data regardless of variations in the source files.

Key operations:
- Extracts data from configured Excel worksheets
- Validates required column headers
- Trims whitespace and normalizes text
- Exports to a clean CSV file with consistent format

.PARAMETER ConfigPath
Path to the YAML configuration file. Defaults to 'config.yaml' in the project root.

.PARAMETER Source
The source key within the config file (e.g., 'mssql').

.OUTPUTS
None. This script creates a CSV file at the location specified in the configuration file.

.EXAMPLE
# Clean findings using default config
.\001_clean_findings.ps1 -Source mssql

.EXAMPLE
# Clean findings using a specific config file
.\001_clean_findings.ps1 -ConfigPath ".\config-alt.yaml" -Source mssql
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,

    [Parameter(Mandatory=$true)]
    [string]$Source
)

# --- Load StoryzeUtils and required modules ---
$InitialLocation = $PSScriptRoot
$RepoRoot = $null
for ($i = 0; $i -lt 5; $i++) {
    $UtilsPath = Join-Path $InitialLocation "StoryzeUtils.psm1"
    if (Test-Path $UtilsPath -PathType Leaf) {
        $RepoRoot = $InitialLocation
        try {
            Import-Module $UtilsPath -Force -ErrorAction Stop
        } catch {
            throw "Found StoryzeUtils.psm1 at '$UtilsPath' but failed to import it: $($_.Exception.Message)"
        }
        break
    }
    $ParentDir = Split-Path -Parent $InitialLocation
    if ($ParentDir -eq $InitialLocation) { break }
    $InitialLocation = $ParentDir
}
if (-not $RepoRoot) {
    throw "Could not find StoryzeUtils.psm1 in the script directory or parent directories. Cannot proceed."
}
$utilsModule = Get-Module -Name StoryzeUtils
if (-not $utilsModule) { throw "StoryzeUtils module loaded but Get-Module failed." }
Write-Verbose "Successfully Bootstrapped and Imported StoryzeUtils from: $($utilsModule.Path)"
$projectRoot = $utilsModule.ModuleBase
Write-Verbose "Project Root determined as: $projectRoot"

# --- Prepare Required Modules ---
$scriptRequiredModules = @('powershell-yaml', 'ImportExcel') 
$localModulesPath = Join-Path $projectRoot "Modules"
Initialize-RequiredModules -RequiredModules $scriptRequiredModules -LocalModulesBaseDir $localModulesPath

# --- Determine Effective Config Path ---
if (-not $PSBoundParameters.ContainsKey('ConfigPath') -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $projectRoot "config.yaml"
    Write-Verbose "Using default config path: $ConfigPath"
} else {
    try {
        $resolved = Resolve-Path -Path $ConfigPath -ErrorAction Stop
        $ConfigPath = $resolved.Path
        Write-Verbose "Using specified config path: $ConfigPath"
    } catch {
        throw "Failed to resolve provided -ConfigPath '$ConfigPath': $($_.Exception.Message)"
    }
}
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Configuration file not found: '$ConfigPath'"
}

# --- Main Script Execution ---
$scriptStartTime = Get-Date
Write-Verbose "Reading Excel Findings Data for source '$Source' and exporting to CSV."

try {
    # --- Load Configuration from YAML File ---
    Write-Verbose "Loading configuration from '$ConfigPath' for source '$Source'..."
    $fullConfig = Import-YamlConfiguration -Path $ConfigPath
    $sourceConfig = $null
    if ($fullConfig.sources -is [hashtable] -and $fullConfig.sources.ContainsKey($Source)) {
        $sourceConfig = $fullConfig.sources[$Source]
    } else {
        $availableSources = if ($fullConfig.sources -is [hashtable]) { $fullConfig.sources.Keys -join ', ' } else { 'None found' }
        throw "Source '$Source' not found in configuration file. Available sources: $availableSources"
    }

    # Validate and resolve paths
    $inputPathStr = $sourceConfig.excel_source_file
    $outputPathStr = $sourceConfig.csv_clean_file
    $excelSheet = $sourceConfig.excel_sheet
    $excelHeaderRow = $sourceConfig.excel_header_row
    $excelColumns = $sourceConfig.excel_columns
    $headerCheckCols = @($sourceConfig.header_check_cols)

    $inputPath = Resolve-Path -Path $inputPathStr -ErrorAction SilentlyContinue
    if (-not $inputPath) { throw "Input Excel file not found at path specified in config: '$inputPathStr'" }
    $outputDir = Split-Path -Path $outputPathStr -Parent
    if (-not (Test-Path -Path $outputDir -PathType Container)) {
        Write-Verbose "Creating output directory: '$outputDir'"
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $outputPathStrFinal = $outputPathStr

    # Validate and parse Excel column range
    if ($null -eq $excelColumns -or $excelColumns -notmatch '^[A-Z]+:[A-Z]+$') {
        throw "Invalid 'excel_columns' value in configuration: '$($excelColumns)'. Must be in the format 'StartColumnLetter:EndColumnLetter'."
    }
    $startColLetter, $endColLetter = $excelColumns.Split(':')
    try {
        $startColNum = Convert-ExcelColumnToNumber -ColumnLetter $startColLetter
        $endColNum = Convert-ExcelColumnToNumber -ColumnLetter $endColLetter
        if ($startColNum -le 0 -or $endColNum -le 0 -or $startColNum -gt $endColNum) {
            throw "Invalid column number range derived from '$excelColumns' -> Start: $startColNum, End: $endColNum."
        }
    } catch {
        throw "Failed to convert Excel column range '$excelColumns' to numbers. Error: $($_.Exception.Message)"
    }

    # Determine the target worksheet
    $worksheetToUse = $null
    Write-Verbose "Determining worksheet. Config value ('excel_sheet'): '$excelSheet' (Type: $($excelSheet.GetType().Name))"
    if ($excelSheet -is [int]) {
        $targetIndex = $excelSheet + 1
        Write-Verbose "Worksheet specified by 0-based index: $excelSheet (Excel 1-based index: ${targetIndex})"
        $excelInfo = Get-ExcelSheetInfo -Path $inputPath.Path
        $targetWorksheet = $excelInfo | Where-Object { $_.Index -eq $targetIndex }
        if ($targetWorksheet) {
            $worksheetToUse = $targetWorksheet.Name
            Write-Verbose "Found worksheet at index ${targetIndex}: '$worksheetToUse'"
        } else {
            $availableSheets = ($excelInfo | ForEach-Object { "$($_.Index): $($_.Name)" }) -join ', '
            throw "Worksheet index ${targetIndex} (config value $excelSheet) not found in '$($inputPath.Path)'. Available sheets (Index: Name): $availableSheets"
        }
    } elseif ($excelSheet -is [string] -and (-not [string]::IsNullOrWhiteSpace($excelSheet))) {
        Write-Verbose "Worksheet specified by name: '$excelSheet'"
        try {
            Get-ExcelSheetInfo -Path $inputPath.Path | Where-Object { $_.Name -eq $excelSheet } -ErrorAction Stop | Out-Null
            $worksheetToUse = $excelSheet
            Write-Verbose "Verified worksheet name '$worksheetToUse' exists."
        } catch {
            $availableSheets = (Get-ExcelSheetInfo -Path $inputPath.Path | ForEach-Object { $_.Name }) -join ', '
            throw "Worksheet named '$excelSheet' not found in '$($inputPath.Path)'. Available sheets: $availableSheets. Error: $($_.Exception.Message)"
        }
    } else {
        throw "Invalid 'excel_sheet' value in configuration: '$excelSheet'. Must be a non-empty string (sheet name) or an integer (0-based index)."
    }

    # Calculate 1-based row numbers for Import-Excel parameters
    $headerRowNumber = $excelHeaderRow + 1

    # Log Effective Configuration
    Write-Verbose ("-" * 60)
    Write-Verbose "Excel Data Reading Configuration"
    Write-Verbose "Source Excel File : $($inputPath.Path)"
    Write-Verbose "Output CSV        : $outputPathStrFinal"
    Write-Verbose "Target Worksheet  : $worksheetToUse (Config value: $excelSheet)"
    Write-Verbose "Header Row (1-based): $headerRowNumber (Config index: $excelHeaderRow)"
    Write-Verbose "Column Range      : $excelColumns (Numeric: $startColNum-$endColNum)"
    Write-Verbose "Required Headers  : $($headerCheckCols -join ', ')"
    Write-Verbose ("-" * 60)

    # Read Raw Excel Data
    Write-Verbose "Reading data from Excel worksheet '$worksheetToUse'...'"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $excelData = @(Import-Excel -Path $inputPath.Path -WorksheetName $worksheetToUse -HeaderRow $headerRowNumber -StartColumn $startColNum -EndColumn $endColNum -ErrorAction Stop)
    $stopwatch.Stop()
    Write-Verbose "Read $($excelData.Count) raw data rows in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds."

    # Ensure Actual Headers Variable is Populated
    if ($excelData.Count -gt 0) {
        $actualHeaders = @($excelData[0].PSObject.Properties.Name)
        Write-Verbose "Actual headers from Excel: $($actualHeaders -join ', ')"
    } else {
        Write-Warning "Excel data is empty, cannot determine headers."
    }

    # Handle case where no data rows are found
    if ($excelData.Count -eq 0) {
        Write-Warning "No data rows found in the specified range (Header Row: $headerRowNumber, Columns: $excelColumns) of worksheet '$worksheetToUse'."
        $headerObjects = @(Import-Excel -Path $inputPath.Path -WorksheetName $worksheetToUse -NoHeader -StartRow $headerRowNumber -EndRow $headerRowNumber -StartColumn $startColNum -EndColumn $endColNum -ErrorAction SilentlyContinue)
        if ($headerObjects.Count -gt 0 -and $headerObjects[0].PSObject.Properties.Count -gt 0) {
            $headers = @($headerObjects[0].PSObject.Properties | ForEach-Object { $_.Value })
            $cleanedHeaders = $headers | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($cleanedHeaders.Count -gt 0) {
                Write-Verbose "Creating empty CSV file with headers: $($cleanedHeaders -join ', ')"
                Set-Content -Path $outputPathStrFinal -Value ($cleanedHeaders -join ',') -Encoding UTF8
            } else {
                 Write-Warning "Could not extract valid headers from row $headerRowNumber. Creating completely empty CSV file."
                 Set-Content -Path $outputPathStrFinal -Value "" -Encoding UTF8
            }
        } else {
            Write-Warning "Could not read header row $headerRowNumber. Creating completely empty CSV file."
            Set-Content -Path $outputPathStrFinal -Value "" -Encoding UTF8
        }
        Write-Verbose "Script finished early as no data rows were found to process."
        exit 0
    }

    # Header Validation
    $missingHeaderCheck = $headerCheckCols | Where-Object { $actualHeaders -notcontains $_ }
    if ($missingHeaderCheck.Count -gt 0) {
        throw "Missing required columns specified in 'header_check_cols': $($missingHeaderCheck -join ', '). Please check the Excel file or the configuration."
    }
    Write-Verbose "Header validation passed."

    # Process Data (Basic Cleaning Only)
    Write-Verbose "Processing $($excelData.Count) rows: Basic cleaning only (trimming whitespace)..."
    $stopwatch.Restart()
    
    $processedRows = $excelData | ForEach-Object {
        $row = $_
        $cleanedRow = [PSCustomObject]@{}
        
        foreach ($header in $actualHeaders) {
            $value = $row.$header
            $cleanedValue = if ($value -ne $null) { $value.ToString().Trim() } else { $null }
            $cleanedRow | Add-Member -MemberType NoteProperty -Name $header -Value $cleanedValue
        }
        
        $cleanedRow
    }
    
    $stopwatch.Stop()
    Write-Verbose "Processed $($processedRows.Count) rows with basic cleaning in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds."

    # Export Cleaned Data to CSV
    if ($processedRows.Count -gt 0) {
        Write-Verbose "Exporting $($processedRows.Count) rows to CSV..."
        $stopwatch.Restart()
        $processedRows | Select-Object -Property $actualHeaders | Export-Csv -Path $outputPathStrFinal -NoTypeInformation -Encoding UTF8
        $stopwatch.Stop()
        Write-Verbose "Successfully exported CSV in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds."
    } else {
        Write-Warning "No data to export after processing."
        Set-Content -Path $outputPathStrFinal -Value "" -Encoding UTF8
    }

    Write-Verbose "Data extraction completed successfully"

} catch {
    Write-Error "Script failed: $($_.Exception.Message)"
    Write-Error "Script execution failed at line $($_.InvocationInfo.ScriptLineNumber)."
    Write-Error ($_.ScriptStackTrace)
    exit 1
}

$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime
Write-Verbose "Total script duration: $($scriptDuration.TotalSeconds.ToString('F2')) seconds."