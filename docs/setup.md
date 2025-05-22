# Storyze Assessment Tracker - Setup Guide

This guide provides step-by-step instructions for setting up and running the Storyze Assessment Tracker for Microsoft SQL Server assessment findings. The solution enables tracking, monitoring, and remediation management through a standardized ETL process.

The architecture supports multiple assessment types using a consistent pattern and workflow.

## 📚 Table of Contents

* [1. Prerequisites](#1-prerequisites)
  * [1.1 Database Requirements](#11-database-requirements)
  * [1.2 Software Requirements](#12-software-requirements)
  * [1.3 Input Files](#13-input-files)
* [2. Installation](#2-installation)
  * [2.1 Get the Repository](#21-get-the-repository)
  * [2.2 Verify PowerShell Module Access](#22-verify-powershell-module-access)
* [3. Configuration](#3-configuration)
  * [3.1 The Environment File (.env)](#31-the-environment-file-env)
  * [3.2 Main Configuration (config.yaml)](#32-main-configuration-configyaml)
  * [3.3 Server Whitelist File](#33-server-whitelist-file)
* [4. Database Setup](#4-database-setup)
  * [4.1 Authentication Options](#41-authentication-options)
  * [4.2 Parameter Validation](#42-parameter-validation)
* [5. ETL Process](#5-running-the-etl-process-mssql-example)
  * [5.1 Run Entire ETL](#51-run-the-entire-etl-process-recommended-)
  * [5.2 Run Individual Scripts](#52-run-individual-scripts-for-troubleshooting)
* [6. Power BI Setup](#6-power-bi-setup-connecting-to-sql-database)
* [7. Troubleshooting](#7-troubleshooting-tips)
  * [7.1 Common Issues and Solutions](#71-common-issues-and-solutions)
  * [7.2 Need Help?](#72-need-help)

---

## 1. Prerequisites

<a id="11-database-requirements"></a>
### 1.1 Database Requirements

* **Microsoft SQL Server 2016+** or **Azure SQL Database/Managed Instance**
* **Database Permissions**: A login with `db_owner` rights (for setup) or the following specific permissions:
  * `CREATE SCHEMA`, `CREATE TABLE`, `CREATE VIEW`
  * `TRUNCATE TABLE`, `DELETE`, `INSERT`, `UPDATE`, `SELECT`
  * `ALTER TABLE`, `EXECUTE`

<a id="12-software-requirements"></a>
### 1.2 Software Requirements

* **PowerShell 5.1+**
* **Git** (optional) - For cloning the repository, or you can download as ZIP
  * [Download Git for Windows](https://git-scm.com/download/win)

#### Required PowerShell Modules

The following PowerShell modules are used for Storyze operations:

| Module | Version | Purpose | Bundled |
|--------|---------|---------|---------|
| SqlServer | 22.3.0+ | SQL Server connectivity and operations | ✅ Yes |
| powershell-yaml | 0.4.12+ | YAML configuration parsing | ✅ Yes |
| ImportExcel | 7.8.10+ | Excel file processing | ✅ Yes |

All required modules are bundled with the repository in the `modules` directory. The scripts automatically load these local modules to ensure consistent behavior without requiring global installation.

<a id="13-input-files"></a>
### 1.3 Input Files

* **SQL Server Assessment Results**: Excel/CSV output from Microsoft Assessment tools
* **Server Whitelist**: A CSV listing your SQL Server instances (created during setup)

## 2. Installation

<a id="21-get-the-repository"></a>
### 2.1 Get the Repository

**Option 1: Using Git** 💻
```powershell
git clone https://github.com/CloudWalker-Defense/storyze.git
cd storyze
```

**Option 2: Manual Download** 📦 (for offline environments)
1. Go to [GitHub Repository](https://github.com/CloudWalker-Defense/storyze)
2. Click the green "Code" button and select "Download ZIP"
3. Extract the ZIP file to a local folder
4. Open PowerShell and navigate to the extracted folder:
   ```powershell
   cd path\to\storyze-main
   ```

<a id="22-verify-powershell-module-access"></a>
### 2.2 Verify PowerShell Module Access

The repository includes all required PowerShell modules in the `modules` directory. The scripts are designed to automatically load these local modules rather than any globally installed versions.

**What to verify**:
1. Confirm that the `modules` directory exists with these required modules:
   ```
   modules/
   ├── ImportExcel/    # For Excel file processing
   ├── powershell-yaml/    # For YAML configuration parsing
   └── SqlServer/    # For SQL Server connectivity
   ```

2. **No action required**: You don't need to manually import these modules. The ETL scripts use the `StoryzeUtils.psm1` module which handles loading the correct module versions from the repository.

**For users running scripts manually**:
If you're developing custom scripts or running individual steps, the simplest approach is to run them from the repository root:

```powershell
# From the repository root folder
Import-Module .\StoryzeUtils.psm1

# Now you can run your custom commands or scripts that use StoryzeUtils functions
```

This ensures your script uses the local modules bundled with the repository instead of any globally installed versions.

**Troubleshooting module conflicts**:
If you encounter module-related errors:
1. Verify that the scripts are running from the repository root directory
2. Check that you're not manually importing conflicting module versions
3. Ensure the modules directory hasn't been modified or corrupted

## 3. Configuration

Before running any scripts, you'll need to set up three key configuration components:

### 3.1 The Environment File (`.env`)

The `.env` file contains connection information for your data warehouse - where all the assessment findings will be stored and tracked. This file is never committed to source control for security reasons.

**What to do**:
1. Copy the provided `.env.example` file to create your own `.env` file:
```powershell
   Copy-Item .env.example .env
   ```
2. Edit the `.env` file and update the variable values for your environment:

```
# Specifies which environment to use (must be either 'azure' or 'onprem')
ENV_TYPE=onprem  

# On-premises SQL Server connection info for your data warehouse
ONPREM_SERVER=SQLSERVER01       # The SQL Server instance that will host your tracking database
ONPREM_DATABASE=Storyze         # The database name where findings will be stored
ONPREM_SQL_LOGIN=username       # Optional: SQL login if using SQL Authentication
ONPREM_SQL_PASSWORD=password    # Optional: SQL password if using SQL Authentication

# Azure SQL Database connection info for your data warehouse (if using Azure)
AZURE_SERVER=yourazureserver.database.windows.net   # Your Azure SQL server address
AZURE_DATABASE=Storyze                              # The database name where findings will be stored
AZURE_SQL_LOGIN=username                            # Required: SQL login for Azure 
AZURE_SQL_PASSWORD=password                         # Required: SQL password for Azure
```

**Important**: You only need to configure the section that matches your selected `ENV_TYPE`. For example, if using on-premises SQL Server, you can leave the Azure parameters as placeholders.

**Authentication Methods**

The assessment tracker supports different authentication methods depending on your environment:

1. **On-premises SQL Server**:
   * **Windows Authentication** (default): Uses your current Windows credentials
   * **SQL Authentication**: Uses a SQL Server login and password (set in `.env` or passed to scripts)

2. **Azure SQL Database**:
   * **SQL Authentication**: Uses SQL Server login/password (set in `.env` or passed to scripts)

### 3.2 Main Configuration (`config.yaml`)

This file controls how the ETL process works, including file paths and processing parameters.

**What to do**:
1. Copy `config.example.yaml` to `config.yaml`
   ```powershell
   Copy-Item config.example.yaml config.yaml
   ```
2. Edit these critical settings:

```yaml
global_settings:
  domain_suffix: '.yourdomain.com'  # Your organization's domain suffix WITH the leading dot
  
sources:
  mssql:
    # File paths (relative to project root or absolute)
    excel_source_file: 'data/mssql/mssql_findings_source.xlsx'  # Your assessment Excel file
    csv_clean_file: 'data/mssql/mssql_findings_clean.csv'       # Where cleaned data will be saved
    object_whitelist_file: 'data/mssql/mssql_map_whitelist.csv' # Your SQL Server whitelist
    data_sample_file: 'data/mssql/mssql_demo_sample_data.csv'   # Sample tracking data
```

**About the Domain Suffix**:
- The `domain_suffix` setting is required for server name normalization.
- If your domain is `contoso.com`, set this to `.contoso.com` (include the leading dot).

### 3.3 Server Whitelist File

This CSV file lists all SQL Server instances in your environment that you're assessing. It's a critical component of the ETL process used to correctly map and categorize findings to specific servers.

The whitelist CSV must have a single column header named `ServerName` (case-sensitive). Each row under this header should contain a single server or cluster name (without domain suffix).

If a server appears in your assessment data but is missing from this whitelist, its findings will not be mapped to a known server and will be categorized as "Unknown" in reports.

**Purpose and Importance**:
- **Finding Attribution**: The whitelist helps the ETL process match assessment findings to specific servers
- **Name Normalization**: Helps standardize server names that might appear differently in assessment data
- **Accurate Reporting**: Ensures findings are attributed to the correct server for proper tracking

**What to do**:
1. Create a CSV file at the path specified in `config.yaml` (`object_whitelist_file`).
   - By default, this is `data/mssql/mssql_map_whitelist.csv` (relative to the repository root), but you can change the path in your `config.yaml` if needed.
   - Place the whitelist CSV in the `data/mssql/` directory, or update the `object_whitelist_file` path in `config.yaml` to match your chosen location.
2. Add EVERY SQL Server instance and cluster name that appears in your assessment data AND/OR that you want to track
3. Use base server names WITHOUT domain suffix (the domain is added automatically using the `domain_suffix` from config.yaml)
4. Include both physical server names AND any virtual names (like cluster names, Availability Group listeners)

**Example**:
```csv
ServerName
SQLPROD01
SQLPROD02
SQLCLUSTER
SQLNODE1
SQLNODE2
AGLISTENER1
```

**Important**: If a server appears in your assessment data but is missing from this whitelist, its findings will be categorized as "Unknown" in reports. Always ensure this list is complete and up-to-date with all your SQL Server instances.

## 4. Database Setup

> **IMPORTANT**: Always run scripts from the repository root directory (where `config.yaml` is located) to ensure correct module loading and path resolution.

<a id="41-authentication-options"></a>
### 4.1 Authentication Options

Storyze supports multiple authentication methods for both on-premises SQL Server and Azure SQL environments:

**On-premises SQL Server**:
- **Windows Authentication**: Uses the current Windows user identity (default for on-premises)
- **SQL Authentication**: Uses SQL Server login and password

**Azure SQL Database**:
- **SQL Authentication**: Uses SQL Server login and password

These can be specified either in the `.env` file or directly as script parameters.

**Option 1: Using the PowerShell Helper Script** (Recommended)
```powershell
# Uses connection settings from your .env file
.\src\mssql\Setup-Database.ps1

# For on-premises using Windows Authentication
.\src\mssql\Setup-Database.ps1 -EnvType onprem -AuthMethod windows

# For on-premises using Windows Authentication with explicit server/database
.\src\mssql\Setup-Database.ps1 -EnvType onprem -AuthMethod windows -ServerInstance "SQLSERVER\INSTANCE" -DatabaseName "Storyze"

# For on-premises using SQL Authentication
.\src\mssql\Setup-Database.ps1 -EnvType onprem -AuthMethod sql -SqlLogin "YourUser" -SqlPassword "YourPassword"

# For Azure SQL Database
.\src\mssql\Setup-Database.ps1 -EnvType azure -AuthMethod sql -SqlLogin "YourUser" -SqlPassword "YourPassword"

# For Azure SQL Database with explicit server/database
.\src\mssql\Setup-Database.ps1 -EnvType azure -AuthMethod sql -ServerInstance "yourserver.database.windows.net" -DatabaseName "Storyze" -SqlLogin "YourUser" -SqlPassword "YourPassword"
```

<a id="42-parameter-validation"></a>
### 4.2 Parameter Validation

Storyze includes thorough parameter validation to ensure valid combinations:

- When using `-EnvType azure`, only `-AuthMethod sql` is allowed
- When using `-AuthMethod windows`, `-SqlLogin` and `-SqlPassword` are not allowed
- When using `-AuthMethod sql`, credentials must be supplied via parameters or in `.env`

**Option 2: Manually Running SQL Scripts**
Run these scripts in order using SSMS:
1. `src/mssql/setup/create_schemas.sql` – Creates the required database schemas (raw, stg, prod, etc.)
2. `src/mssql/setup/create_table_raw.sql` – Creates the table for raw imported findings
3. `src/mssql/setup/create_table_map.sql` – Creates the object mapping table for server name normalization
4. `src/mssql/setup/create_table_staging.sql` – Creates the staging table for cleaned and transformed data
5. `src/mssql/setup/create_table_prod.sql` – Creates the production table for final, report-ready data
6. `src/mssql/setup/create_view.sql` – Creates the main view for Power BI and reporting

**Troubleshooting Database Setup**:
- **SQL Server Connection Issues**: Ensure the SQL Server is running and accessible from your machine
- **Permission Denied**: Confirm you have the necessary permissions outlined in [Database Requirements](#11-database-requirements)
- **Script Failures**: If a script fails:
  1. Note the error message
  2. Fix the underlying issue (usually permissions or connectivity)
  3. You may need to clean up partially created objects before retrying

## 5. Running the ETL Process (MSSQL Example)

<a id="51-run-the-entire-etl-process-recommended"></a>
### 5.1 Run the entire ETL process (RECOMMENDED) ✅

```powershell
# Run the full ETL process using settings from .env
.\src\mssql\etl.ps1 -Source mssql

# Run with specific environment type and authentication method
.\src\mssql\etl.ps1 -Source mssql -EnvType onprem -AuthMethod windows

# Run with custom server and database
.\src\mssql\etl.ps1 -Source mssql -ServerInstance "SQLSERVER\INSTANCE" -DatabaseName "Storyze"

# Run with SQL authentication
.\src\mssql\etl.ps1 -Source mssql -EnvType onprem -AuthMethod sql -SqlLogin "YourUser" -SqlPassword "YourPassword"

# Run with Azure SQL
.\src\mssql\etl.ps1 -Source mssql -EnvType azure -AuthMethod sql -SqlLogin "YourUser" -SqlPassword "YourPassword" -Verbose
```

**What to expect**:
- ⏱️ The full ETL process typically takes 15-20 minutes, depending on assessment data size
- 📊 You'll see progress messages for each of the 7 steps
- ✅ A successful run will end with "ETL Process Completed Successfully!"
- 🗄️ The process will create several tables and views in your database

<a id="52-run-individual-scripts-for-troubleshooting"></a>
### 5.2 Run individual scripts (for troubleshooting)

If you need more control or want to isolate issues, you can execute each script individually:

1. **Clean Findings Data**:
   ```powershell
   .\src\mssql\etl\001_clean_findings.ps1 -Source mssql
   ```

2. **Load Raw Data to SQL**:
   ```powershell
   .\src\mssql\etl\002_load_findings_to_sql.ps1 -Source mssql
   ```

3. **Populate Object Map**:
   ```powershell
   .\src\mssql\etl\003_populate_mssql_map.ps1 -Source mssql
   ```

4. **Transform Data to Staging** (SQL):
   * Open `src/mssql/etl/004_insert_data_staging.sql` in SSMS
   * **⚠️ CRITICAL:** The `@DomainSuffixToReplace` variable in `src/mssql/etl/004_insert_data_staging.sql` must match your `domain_suffix` from `config.yaml` exactly.
   * Execute the script

5. **Update Priority Rankings** (SQL):
   * Execute `src/mssql/etl/005_update_objectid_prio.sql` in SSMS

6. **Load Sample Tracking Data**:
   ```powershell
   .\src\mssql\etl\006_load_sample_data.ps1 -Source mssql
   ```
   > **Note**: The included sample data only provides coverage for finding IDs up to 950. If your dataset includes IDs above 950 and you don't create an extended sample data file, those findings will still appear in reports but won't have any sample tracking data (like end dates, start dates, assigned to, etc.). This is perfectly fine for demonstration purposes.

7. **Final Load to Production** (SQL):
   * Execute `src/mssql/etl/007_insert_data_prod.sql` in SSMS

## 6. Power BI Setup (Connecting to SQL Database)

1. Open the template file `docs/pbi_demo/Storyze - SQL Template.pbit` in Power BI Desktop
2. Enter your SQL Server details when prompted:
   * **Server Instance**: Your SQL Server name
   * **Database Name**: Your database name (from `.env`)
3. Choose the appropriate authentication method
4. Save as a `.pbix` file and customize as needed

## 7. Troubleshooting Tips

<a id="71-common-issues-and-solutions"></a>
### 7.1 Common Issues and Solutions

| Issue | Possible Cause | Solution |
|-------|---------------|----------|
| ❌ Connection fails | Auth issues | Verify credentials in `.env` file or parameters; check network connectivity |
| ❌ "Module not found" | Missing modules | Verify `modules` directory is present with all required module folders |
| ❌ Azure data loading fails | Auth method | For Azure, scripts 002, 006, 007 can ONLY use SQL Authentication |
| ❌ Server names show as "Unknown" | Whitelist issue | Check server names in whitelist match assessment (without domain suffix) |
| ❌ Server name normalization issues | Domain suffix mismatch | Verify domain suffix in `config.yaml` matches script 004 exactly |
| ❌ Sample data not applied | ID range issue | Default sample data only covers IDs up to 950 |
| ❌ PowerShell errors | ExecutionPolicy | Run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process` |
| ❌ Script errors | Path issues | Always run scripts from the repository root directory |
| ❌ SQL scripts fail | Table existence | Some scripts might fail if tables already exist; check for error messages |
| ❌ Parameter validation errors | Invalid combinations | Check parameter combinations (e.g., Windows auth not allowed with Azure) |
| ❌ Path resolution issues | Relative paths | If using custom paths in config.yaml, ensure they're relative to repository root or absolute |

<a id="72-need-help"></a>
### 7.2 Need Help?

📧 Contact support at: [info@cloudwalkerdefense.com](mailto:info@cloudwalkerdefense.com)