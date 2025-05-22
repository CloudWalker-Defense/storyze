function Initialize-RequiredModules {
    <#
    .SYNOPSIS
    Initializes required PowerShell modules for Storyze.

    .DESCRIPTION
    Loads the specified modules from either the local modules directory or system paths. 
    Prioritizes local bundled modules over system modules to ensure version consistency.
    Performs validation checks to ensure critical commands from each module are available.

    .PARAMETER RequiredModules
    Array of module names to load (e.g., 'SqlServer', 'powershell-yaml', 'ImportExcel').

    .PARAMETER LocalModulesBaseDir
    Path to the directory containing local module folders.

    .EXAMPLE
    Initialize-RequiredModules -RequiredModules @('SqlServer', 'powershell-yaml') -LocalModulesBaseDir "C:\path\to\modules"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$RequiredModules,
        [Parameter(Mandatory=$true)]
        [string]$LocalModulesBaseDir
    )

    $pathSeparator = [System.IO.Path]::PathSeparator
    
    # Ensure local modules directory exists
    if (-not (Test-Path -Path $LocalModulesBaseDir)) {
        Write-Verbose "Specified module directory not found at: $LocalModulesBaseDir"
        $projectRoot = (Split-Path -Parent (Split-Path -Parent $LocalModulesBaseDir))
        
        # Use case-insensitive path search for "modules" directory
        $modulesFolder = Get-ChildItem -Path $projectRoot -Directory | 
                        Where-Object { $_.Name -ieq "modules" } | 
                        Select-Object -First 1
                        
        if ($modulesFolder) {
            $LocalModulesBaseDir = $modulesFolder.FullName
            Write-Verbose "Found modules folder at: $LocalModulesBaseDir"
        }
    }
    
    # Add local modules directory to PSModulePath if needed
    if ($LocalModulesBaseDir -and (Test-Path $LocalModulesBaseDir) -and ($env:PSModulePath -notlike "*$LocalModulesBaseDir*")) {
        $env:PSModulePath = $LocalModulesBaseDir + $pathSeparator + $env:PSModulePath
        Write-Verbose "Added modules path to PSModulePath: $LocalModulesBaseDir"
    }

    foreach ($moduleName in $RequiredModules) {
        Write-Verbose "Checking module: $moduleName"
        
        # Skip if already loaded
        if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
            Write-Verbose "Module '$moduleName' is already loaded."
            continue
        }

        $moduleLoaded = $false
        
        # Find local module directory
        $moduleDir = Get-ChildItem -Path $LocalModulesBaseDir -Directory -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -ieq $moduleName } | 
                    Select-Object -First 1
                    
        if ($moduleDir) {
            Write-Verbose "Found local module directory for '$moduleName' at: $($moduleDir.FullName)"
            
            # First, check for version directories and find the highest one
            $versionDirs = Get-ChildItem -Path $moduleDir.FullName -Directory -ErrorAction SilentlyContinue | 
                           Where-Object { $_.Name -match '^\d+\.\d+(\.\d+)?(\.\d+)?$' }
            
            if ($versionDirs -and $versionDirs.Count -gt 0) {
                # Get highest version directory
                $highestVersionDir = $versionDirs | 
                                     Sort-Object { [Version]$_.Name } -Descending | 
                                     Select-Object -First 1
                
                Write-Verbose "Using highest version directory: $($highestVersionDir.FullName)"
                
                # Look for module manifest in version directory
                $moduleManifest = Get-ChildItem -Path $highestVersionDir.FullName -Filter "$moduleName.psd1" -File -ErrorAction SilentlyContinue |
                                  Select-Object -First 1
                
                if ($moduleManifest) {
                    Write-Verbose "Loading versioned module from manifest: $($moduleManifest.FullName)"
                    try {
                        Import-Module -Name $moduleManifest.FullName -Force -ErrorAction Stop
                        if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                            Write-Verbose "Successfully loaded versioned module '$moduleName'"
                            $moduleLoaded = $true
                        }
                    } catch {
                        Write-Warning "Failed to load versioned module manifest for '$moduleName': $($_.Exception.Message)"
                    }
                } else {
                    # Try module script file instead
                    $moduleFile = Get-ChildItem -Path $highestVersionDir.FullName -Filter "$moduleName.psm1" -File -ErrorAction SilentlyContinue |
                                  Select-Object -First 1
                    
                    if ($moduleFile) {
                        Write-Verbose "Loading versioned module from script file: $($moduleFile.FullName)"
                        try {
                            Import-Module -Name $moduleFile.FullName -Force -ErrorAction Stop
                            if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                                Write-Verbose "Successfully loaded versioned module '$moduleName'"
                                $moduleLoaded = $true
                            }
                        } catch {
                            Write-Warning "Failed to load versioned module script for '$moduleName': $($_.Exception.Message)"
                        }
                    }
                }
            }
            
            # If still not loaded, try root module directory
            if (-not $moduleLoaded) {
                # Look for module manifest in root directory
                $moduleManifest = Get-ChildItem -Path $moduleDir.FullName -Filter "$moduleName.psd1" -File -ErrorAction SilentlyContinue |
                                 Select-Object -First 1
                
                if ($moduleManifest) {
                    Write-Verbose "Loading module from root manifest: $($moduleManifest.FullName)"
                    try {
                        Import-Module -Name $moduleManifest.FullName -Force -ErrorAction Stop
                        if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                            Write-Verbose "Successfully loaded module '$moduleName' from root manifest"
                            $moduleLoaded = $true
                        }
                    } catch {
                        Write-Warning "Failed to load root module manifest for '$moduleName': $($_.Exception.Message)"
                    }
                } else {
                    # Try module script file instead
                    $moduleFile = Get-ChildItem -Path $moduleDir.FullName -Filter "$moduleName.psm1" -File -ErrorAction SilentlyContinue |
                                 Select-Object -First 1
                    
                    if ($moduleFile) {
                        Write-Verbose "Loading module from root script file: $($moduleFile.FullName)"
                        try {
                            Import-Module -Name $moduleFile.FullName -Force -ErrorAction Stop
                            if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                                Write-Verbose "Successfully loaded module '$moduleName' from root script"
                                $moduleLoaded = $true
                            }
                        } catch {
                            Write-Warning "Failed to load root module script for '$moduleName': $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        
        # If module is still not loaded, try system paths
        if (-not $moduleLoaded) {
            Write-Verbose "Attempting to load module '$moduleName' from system paths..."
            try {
                Import-Module -Name $moduleName -ErrorAction Stop
                if (Get-Module -Name $moduleName -ErrorAction SilentlyContinue) {
                    Write-Verbose "Successfully loaded module '$moduleName' from system path"
                    $moduleLoaded = $true
                }
            } catch {
                $errorMessage = "Required module '$moduleName' could not be loaded from any source."
                $errorMessage += " Not found in local path: $LocalModulesBaseDir/$moduleName/"
                $errorMessage += " Failed to load from system paths (Error: $($_.Exception.Message))."
                $errorMessage += " Please ensure the module exists in the local modules directory OR is installed system-wide (see docs/setup.md for details)."
                throw $errorMessage
            }
        }
        
        if (-not $moduleLoaded) {
            throw "Failed to make module '$moduleName' available after checking local and system paths."
        }
    }

    # Verify critical module commands are available
    Write-Verbose "Performing final verification of required module commands..."
    foreach ($moduleName in $RequiredModules) {
        if (-not (Get-Module -Name $moduleName -ErrorAction SilentlyContinue)) {
             throw "FINAL CHECK FAILED: Module '$moduleName' was reported as loaded, but Get-Module cannot find it."
        }
        
        # Module-specific command checks
        switch ($moduleName) {
            'SqlServer' {
                if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                     throw "FINAL CHECK FAILED: Module '$moduleName' appears loaded, but the critical command 'Invoke-Sqlcmd' could not be found. Check module integrity."
                }
                Write-Verbose "Verified command 'Invoke-Sqlcmd' is available from module '$moduleName'."
            }
            'powershell-yaml' {
                if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
                     throw "FINAL CHECK FAILED: Module '$moduleName' appears loaded, but the critical command 'ConvertFrom-Yaml' could not be found. Check module integrity."
                }
                Write-Verbose "Verified command 'ConvertFrom-Yaml' is available from module '$moduleName'."
            }
            'ImportExcel' {
                if (-not (Get-Command Import-Excel -ErrorAction SilentlyContinue)) {
                     throw "FINAL CHECK FAILED: Module '$moduleName' appears loaded, but the critical command 'Import-Excel' could not be found. Check module integrity."
                }
                Write-Verbose "Verified command 'Import-Excel' is available from module '$moduleName'."
            }
        }
    }

    Write-Verbose "Module check complete. All required modules verified."
}