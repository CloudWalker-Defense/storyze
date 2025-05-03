<#
.SYNOPSIS
Reads, cleans, and consolidates MSSQL security findings from an Excel file into a CSV format.

.DESCRIPTION
Reads data from a specified Excel sheet based on parameters defined in the config.yaml file.
Validates expected headers, handles multi-line entries by merging rows, trims whitespace,
and exports the cleaned data to a CSV file ready for database loading.

.PARAMETER ConfigPath
Optional. Path to the YAML configuration file. 
Defaults to 'config.yaml' in the project root directory if omitted.

.PARAMETER Source
Mandatory. The source key within the config file (e.g., 'mssql').

.EXAMPLE
# Clean findings using default ./config.yaml
.\006_clean_findings.ps1 -Source mssql

.EXAMPLE
# Clean findings using a specific config file
.\006_clean_findings.ps1 -ConfigPath ".\config-alt.yaml" -Source mssql

.NOTES
Author:      CloudWalker Defense LLC
Date:        2025-04-30
License:     MIT License
Dependencies: StoryzeUtils.psm1, powershell-yaml, ImportExcel modules.
Output:      Generates a cleaned CSV file specified by 'csv_clean_file' in the config.
#>
[CmdletBinding()]
param(
    # Optional: Path to the config file (defaults to ./config.yaml)
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath,

    # Mandatory: Source key in config.yaml (e.g., 'mssql')
    [Parameter(Mandatory=$true)]
    [string]$Source
)

# --- Minimal Bootstrapping to find and load StoryzeUtils --- 
# Find the repository root by searching upwards for the utility module.
$InitialLocation = $PSScriptRoot
$RepoRoot = $null
for ($i = 0; $i -lt 5; $i++) { # Search up to 5 levels up
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
    if ($ParentDir -eq $InitialLocation) { break } # Reached drive root
    $InitialLocation = $ParentDir
}
if (-not $RepoRoot) {
    throw "Could not find StoryzeUtils.psm1 in the script directory or parent directories. Cannot proceed."
}
$utilsModule = Get-Module -Name StoryzeUtils # Should now be loaded
if (-not $utilsModule) { throw "StoryzeUtils module loaded but Get-Module failed." } # Sanity check
Write-Verbose "Successfully Bootstrapped and Imported StoryzeUtils from: $($utilsModule.Path)"
$projectRoot = $utilsModule.ModuleBase # Use module base as project root
Write-Verbose "Project Root determined as: $projectRoot"
# --- End Bootstrapping --- 

# --- Prepare Required Modules --- 
# StoryzeUtils already imported by bootstrap
$scriptRequiredModules = @('powershell-yaml', 'ImportExcel') 
$localModulesPath = Join-Path $projectRoot "Modules"
Initialize-RequiredModules -RequiredModules $scriptRequiredModules -LocalModulesBaseDir $localModulesPath

# --- Determine Effective Config Path ---
if (-not $PSBoundParameters.ContainsKey('ConfigPath') -or [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $projectRoot "config.yaml"
    Write-Host "No -ConfigPath provided, defaulting to '$ConfigPath'" -ForegroundColor Yellow
} else {
    try {
        $resolved = Resolve-Path -Path $ConfigPath -ErrorAction Stop
        $ConfigPath = $resolved.Path
        Write-Host "Using specified ConfigPath: $ConfigPath" -ForegroundColor Yellow
    } catch {
        throw "Failed to resolve provided -ConfigPath '$ConfigPath': $($_.Exception.Message)"
    }
}
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Effective configuration file path not found: '$ConfigPath'. Verify the path or ensure config.yaml exists in project root."
}

# --- Main Script Execution ---
$scriptStartTime = Get-Date
Write-Host ("=" * 80)
Write-Host "Starting Script: $($MyInvocation.MyCommand.Name) at $scriptStartTime" -ForegroundColor Yellow
Write-Host ("Cleaning Excel Findings Data for source '$Source' and exporting to CSV.")
Write-Host ("=" * 80)

# Initialize variables potentially used in finally block (if any)
# (Currently none needed as file handles are managed by Export-Csv/Set-Content)

try {
    # --- Load Configuration from YAML File ---
    Write-Host "Loading configuration from '$ConfigPath' for source '$Source'..." -ForegroundColor Cyan
    $fullConfig = Import-YamlConfiguration -Path $ConfigPath
    # Access the specific source configuration using the -Source parameter
    $sourceConfig = $null
    if ($fullConfig.sources -is [hashtable] -and $fullConfig.sources.ContainsKey($Source)) {
        $sourceConfig = $fullConfig.sources[$Source]
    } else {
        $availableSources = if ($fullConfig.sources -is [hashtable]) { $fullConfig.sources.Keys -join ', ' } else { 'None found' }
        throw "Source '$Source' not found in configuration file '$ConfigPath'. Available sources: $availableSources"
    }

    # Extract parameters from the specific source config
    $inputPathStr = $sourceConfig.excel_source_file
    $outputPathStr = $sourceConfig.csv_clean_file
    $excelSheet = $sourceConfig.excel_sheet          # Can be name (string) or 0-based index (int)
    $excelHeaderRow = $sourceConfig.excel_header_row  # 0-based index of the header row
    $excelColumns = $sourceConfig.excel_columns      # Column range like 'A:L'
    $headerCheckCols = @($sourceConfig.header_check_cols) # List of mandatory header names
    $keyColumns = @($sourceConfig.key_columns)          # Columns identifying a unique finding record
    $concatCols = @($sourceConfig.concat_cols)        # Columns whose values should be concatenated for multi-line entries
    $concatSeparator = if (-not [string]::IsNullOrEmpty($sourceConfig.concat_separator)) { $sourceConfig.concat_separator } else { "`n" } # Separator for concatenated values

    # Validate and resolve paths
    $inputPath = Resolve-Path -Path $inputPathStr -ErrorAction SilentlyContinue
    if (-not $inputPath) { throw "Input Excel file not found at path specified in config ('excel_source_file'): '$inputPathStr'" }
    $outputDir = Split-Path -Path $outputPathStr -Parent
    if (-not (Test-Path -Path $outputDir -PathType Container)) {
        Write-Verbose "Creating output directory: '$outputDir'"
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    $outputPathStrFinal = $outputPathStr

    # Validate and parse Excel column range (e.g., "A:L")
    if ($null -eq $excelColumns -or $excelColumns -notmatch '^[A-Z]+:[A-Z]+$') {
        throw "Invalid 'excel_columns' value in configuration: '$($excelColumns)'. Must be in the format 'StartColumnLetter:EndColumnLetter' (e.g., 'A:L')."
    }
    $startColLetter, $endColLetter = $excelColumns.Split(':')
    try {
        $startColNum = Convert-ExcelColumnToNumber -ColumnLetter $startColLetter
        $endColNum = Convert-ExcelColumnToNumber -ColumnLetter $endColLetter
        if ($startColNum -le 0 -or $endColNum -le 0 -or $startColNum -gt $endColNum) {
            throw "Invalid column number range derived from '$excelColumns' -> Start: $startColNum, End: $endColNum. Ensure start column is not after end column."
        }
    } catch {
        throw "Failed to convert Excel column range '$excelColumns' to numbers. Error: $($_.Exception.Message)"
    }

    # Determine the target worksheet (handle name or index)
    $worksheetToUse = $null
    Write-Verbose "Determining worksheet. Config value ('excel_sheet'): '$excelSheet' (Type: $($excelSheet.GetType().Name))"
    if ($excelSheet -is [int]) {
        # Config specifies 0-based index, Excel uses 1-based index
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
        # Config specifies name
        Write-Verbose "Worksheet specified by name: '$excelSheet'"
        # Verify the named sheet exists (case-sensitive check by Import-Excel)
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
    $headerRowNumber = $excelHeaderRow + 1 # Convert 0-based index from config to 1-based row number for Import-Excel

    # --- Log Effective Configuration ---
    Write-Host ("-" * 60)
    Write-Host "Excel Data Cleaning Configuration" -ForegroundColor Cyan
    Write-Host "Source Excel File : $($inputPath.Path)"
    Write-Host "Output Clean CSV  : $outputPathStrFinal"
    Write-Host "Target Worksheet  : $worksheetToUse (Config value: $excelSheet)"
    Write-Host "Header Row (1-based): $headerRowNumber (Config index: $excelHeaderRow)"
    Write-Host "Column Range      : $excelColumns (Numeric: $startColNum-$endColNum)"
    Write-Host "Required Headers  : $($headerCheckCols -join ', ')"
    Write-Host "Key Columns       : $($keyColumns -join ', ')"
    Write-Host "Multi-line Columns: $($concatCols -join ', ')"
    # Display separator safely, replacing special characters for readability
    $displaySeparator = $concatSeparator -replace '\\r', '[CR]' -replace '\\n', '[LF]' -replace '\\t', '[TAB]' # Make special chars visible
    Write-Host ("Concat Separator  : '$displaySeparator'") # Construct string separately
    Write-Host ("-" * 60)

    # --- Read Raw Excel Data ---
    Write-Host "Reading data from Excel worksheet '$worksheetToUse'...'"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Use specified column range for reading
    $excelData = @(Import-Excel -Path $inputPath.Path -WorksheetName $worksheetToUse -HeaderRow $headerRowNumber -StartColumn $startColNum -EndColumn $endColNum -ErrorAction Stop)
    $stopwatch.Stop()
    Write-Host "Read $($excelData.Count) raw data rows in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds." -ForegroundColor Green

    # Handle case where no data rows are found (only header or empty sheet)
    if ($excelData.Count -eq 0) {
        Write-Warning "No data rows found in the specified range (Header Row: $headerRowNumber, Columns: $excelColumns) of worksheet '$worksheetToUse'."
        # Create an empty CSV file with headers if possible
        $headerObjects = @(Import-Excel -Path $inputPath.Path -WorksheetName $worksheetToUse -NoHeader -StartRow $headerRowNumber -EndRow $headerRowNumber -StartColumn $startColNum -EndColumn $endColNum -ErrorAction SilentlyContinue)
        if ($headerObjects.Count -gt 0 -and $headerObjects[0].PSObject.Properties.Count -gt 0) {
            # Attempt to extract headers from the single row read
            $headers = @($headerObjects[0].PSObject.Properties | ForEach-Object { $_.Value })
            # Trim and filter potentially null/empty header values read
            $cleanedHeaders = $headers | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($cleanedHeaders.Count -gt 0) {
                Write-Host "Creating empty CSV file '$outputPathStrFinal' with headers: $($cleanedHeaders -join ', ')"
                Set-Content -Path $outputPathStrFinal -Value ($cleanedHeaders -join ',') -Encoding UTF8
            } else {
                 Write-Warning "Could not extract valid headers from row $headerRowNumber. Creating completely empty CSV file."
                 Set-Content -Path $outputPathStrFinal -Value "" -Encoding UTF8
            }
        } else {
            Write-Warning "Could not read header row $headerRowNumber. Creating completely empty CSV file."
            Set-Content -Path $outputPathStrFinal -Value "" -Encoding UTF8
        }
        Write-Host "Script finished early as no data rows were found to process." -ForegroundColor Yellow
        exit 0
    }

    # --- Header Validation ---
    # Get the actual column headers read by Import-Excel
    $actualHeaders = @($excelData[0].PSObject.Properties.Name)
    Write-Verbose "Actual headers read from Excel: $($actualHeaders -join ', ')"

    # Verify all required check columns are present
    $missingHeaderCheck = $headerCheckCols | Where-Object { $actualHeaders -notcontains $_ }
    if ($missingHeaderCheck.Count -gt 0) {
        throw "Missing required columns specified in 'header_check_cols': $($missingHeaderCheck -join ', '). Please check the Excel file or the configuration."
    }
    # Verify all key columns are present
    $missingKeyCols = $keyColumns | Where-Object { $actualHeaders -notcontains $_ }
    if ($missingKeyCols.Count -gt 0) {
        throw "Missing key columns specified in 'key_columns': $($missingKeyCols -join ', '). These are required for consolidating multi-line entries."
    }
    # Verify all concatenation columns are present
    $missingConcat = $concatCols | Where-Object { $actualHeaders -notcontains $_ }
    if ($missingConcat.Count -gt 0) {
        throw "Missing multi-line columns specified in 'concat_cols': $($missingConcat -join ', '). These are required for consolidating multi-line entries."
    }
    Write-Host "Header validation passed." -ForegroundColor Green

    # --- Process Data (Consolidate Multi-line Entries & Trim) ---
    Write-Host "Processing $($excelData.Count) rows: Consolidating multi-line entries and trimming whitespace..."
    $stopwatch.Restart()
    # Use a List for better performance adding items compared to += on array
    $processedRows = [System.Collections.Generic.List[System.Management.Automation.PSCustomObject]]::new()
    $currentRowData = $null

    foreach ($row in $excelData) {
        # Check if this row starts a new finding based on key columns
        $isNewFinding = $false
        if ($null -eq $currentRowData) {
            $isNewFinding = $true # First row is always a new finding
        } else {
            # Compare key columns of the current row with the ongoing finding
            foreach ($keyCol in $keyColumns) {
                # If any key column has a non-empty value in the current row, it's a new finding
                # Assumes subsequent lines of a multi-line entry have key columns blank
                if (-not [string]::IsNullOrWhiteSpace($($row.$keyCol))) {
                    $isNewFinding = $true
                    break
                }
            }
        }

        if ($isNewFinding) {
            # If we were processing a previous finding, add it to the results list
            if ($null -ne $currentRowData) {
                $processedRows.Add([pscustomobject]$currentRowData)
            }
            # Start a new finding: Initialize data structure and trim all initial values
            $currentRowData = @{ }
            foreach ($header in $actualHeaders) {
                $value = $row.$header
                $currentRowData[$header] = if ($value -ne $null) { $value.ToString().Trim() } else { $null }
            }
        } else {
            # This row is a continuation of the previous finding
            # Append data from concatenation columns
            foreach ($concatCol in $concatCols) {
                $value = $row.$concatCol
                if ($value -ne $null -and (-not [string]::IsNullOrWhiteSpace($value.ToString()))) {
                    $trimmedValue = $value.ToString().Trim()
                    if ($trimmedValue.Length -gt 0) {
                        $currentRowData[$concatCol] = "$($currentRowData[$concatCol])$concatSeparator$trimmedValue"
                    }
                }
            }
            # Optional: Could also handle non-key, non-concat columns here if needed (e.g., take last value)
        }
    }

    # Add the last processed finding to the list
    if ($null -ne $currentRowData) {
        $processedRows.Add([pscustomobject]$currentRowData)
    }
    $stopwatch.Stop()
    Write-Host "Processed data into $($processedRows.Count) consolidated records in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds." -ForegroundColor Green

    # --- Export Cleaned Data to CSV ---
    if ($processedRows.Count -gt 0) {
        Write-Host "Exporting $($processedRows.Count) cleaned records to '$outputPathStrFinal'..."
        $stopwatch.Restart()
        # Ensure columns are exported in the order they appeared in the Excel file
        $processedRows | Select-Object -Property $actualHeaders | Export-Csv -Path $outputPathStrFinal -NoTypeInformation -Encoding UTF8
        $stopwatch.Stop()
        Write-Host "Successfully exported CSV in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds." -ForegroundColor Green
    } else {
        Write-Warning "No data to export after processing."
        # Ensure an empty file exists if no processed rows resulted
        Set-Content -Path $outputPathStrFinal -Value "" -Encoding UTF8
    }

    Write-Host "Data extraction and consolidation completed successfully" -ForegroundColor Cyan

} catch {
    # Centralized error handling
    Write-Error "Script failed: $($_.Exception.Message)"
    Write-Error "Script execution failed at line $($_.InvocationInfo.ScriptLineNumber)."
    Write-Error ($_.ScriptStackTrace)
    exit 1
}

$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime
Write-Host ("=" * 80)
Write-Host "Script Finished: $($MyInvocation.MyCommand.Name) at $scriptEndTime" -ForegroundColor Yellow
Write-Host "Total script duration: $($scriptDuration.TotalSeconds.ToString('F2')) seconds."
Write-Host ("=" * 80)