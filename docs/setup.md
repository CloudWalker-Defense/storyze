# Storyze Assessment Tracker - Detailed Setup and Execution Guide

This document provides detailed instructions for setting up the necessary environment, configuring the project, setting up the database, and running the ETL process for the Storyze Assessment Tracker (specifically focusing on the MSSQL Findings module initially).

---

## Table of Contents

* [1. Prerequisites](#1-prerequisites)
* [2. Environment Setup](#2-environment-setup)
    * [2.1 Clone Repository](#21-clone-repository)
    * [2.2 PowerShell Module Requirements](#22-powershell-module-requirements)
* [3. Configuration](#3-configuration)
    * [3.1 Environment Variables (`.env` file)](#31-environment-variables-env-file)
    * [3.2 Main Configuration (config.yaml)](#32-main-configuration-configyaml)
    * [3.3 Whitelist File](#33-whitelist-file)
* [4. Database Setup](#4-database-setup)
* [5. Running the ETL Process (MSSQL Example)](#5-running-the-etl-process-mssql-example)
* [6. Power BI Setup (Connecting to SQL Database)](#6-power-bi-setup-connecting-to-sql-database)
* [7. Troubleshooting Tips](#7-troubleshooting-tips)

---

## 1. Prerequisites

Ensure the following software and permissions are available before proceeding:

* **Database System:**
    * Microsoft SQL Server (Version 2016 or later is required due to the use of `STRING_SPLIT`).
    * Tested on SQL Server 2022 and Azure SQL Managed Instance.
    * An existing database to host the tables/views, OR permissions to create a new database.
* **Database Permissions:**
    * A SQL Server login/user with permissions in the target database to:
        * `CREATE SCHEMA`
        * `CREATE TABLE`
        * `CREATE VIEW`
        * `TRUNCATE TABLE` / `DELETE`
        * `INSERT`, `UPDATE`, `SELECT`
        * `EXECUTE` stored procedures (if any are added later)
        * `ALTER TABLE` (for adding constraints if not in main script)
    * `db_owner` rights are simplest during initial setup but can likely be restricted afterwards.
* **Execution Environment:**
    * PowerShell: Version 5.1 or higher.
    * PowerShell Modules: SqlServer, powershell-yaml, ImportExcel (see installation instructions in section 2.2).
* **Source Control:**
    * Git: Required for cloning the repository. Download from [git-scm.com](https://git-scm.com/downloads).
* **Reporting:**
    * Power BI Desktop: Latest version recommended for opening and editing the `.pbix` report template. Download from Microsoft.
    * Power BI Service (Cloud) *OR* Power BI Report Server (On-Premises): Required for publishing and sharing the report.
* **Input Files:**
    * Access to the raw SQL Server Offline Assessment output file(s) (Excel or CSV format).
    * Ability to create/provide a Server Whitelist CSV file (see Configuration section).

## 2. Environment Setup

These steps prepare your local machine to run the project's scripts.

### 2.1 Clone Repository

Navigate to the parent directory on your local machine where you want to place the project folder. Then, clone this repository using Git:
```bash
git clone https://github.com/CloudWalker-Defense/storyze.git
cd storyze
```

### 2.2 PowerShell Module Requirements

The Storyze Assessment Tracker relies on several PowerShell modules: `SqlServer`, `powershell-yaml`, and `ImportExcel`.

**Bundled Modules (Preferred Method)**

This repository includes a `Modules` directory containing specific versions of these PowerShell modules required for consistent operation:

*   `ImportExcel` (Version: 7.8.10)
*   `powershell-yaml` (Version: 0.4.12)
*   `SqlServer` (Version: 22.3.0)

The scripts are configured to automatically detect and use the modules from this local `storyze/Modules` directory first.

*   **Action Required:** Ensure the `Modules` directory exists in the root of your cloned `storyze` repository and contains subdirectories for `SqlServer`, `powershell-yaml`, and `ImportExcel`. If you cloned the repository correctly, this directory should already be present and populated. **No installation steps are typically needed.**

**Alternative: Online Installation (System-Wide)**

If the `Modules` directory is missing, or if you prefer to manage these modules system-wide and have an internet connection, you can install them using PowerShell's `Install-Module` command.

Run the following in PowerShell (potentially requiring administrative privileges depending on scope):

```powershell
# Install the required modules
Install-Module -Name SqlServer
Install-Module -Name powershell-yaml
Install-Module -Name ImportExcel
```
*Note: Using this method might install different module versions than those bundled in the repository.*

**Verification**

You can verify that PowerShell can discover the modules (either from the bundled `Modules` path or system paths) by running:

```powershell
# Check if modules are discoverable
Get-Module -ListAvailable -Name SqlServer, powershell-yaml, ImportExcel
```
This command should list the modules. The scripts will automatically attempt to load them when executed, prioritizing the bundled versions.

## 3. Configuration

Configure the necessary files before running any scripts.

### 3.1 Environment Variables (`.env` file)

This file stores connection details and environment type information. It is critical for security that this file is **NEVER** committed to version control (like Git).

1.  **Create `.env` File:** Locate the `.env.example` file in the project root directory. Copy it to a new file named `.env` in the same directory.
2.  **Edit `.env` File:** Open the `.env` file and configure the following variables:

    *   **`ENV_TYPE` (Required):** Set the target environment.
        *   `onprem`: For connecting to an on-premises SQL Server instance.
        *   `azure`: For connecting to Azure SQL Database or Azure SQL Managed Instance.
        *   *Default Behavior:* PowerShell scripts in this solution may apply default behaviors based on this setting (e.g., defaulting to SQL Authentication if `ENV_TYPE=azure` and no specific authentication method is provided via parameters).

    *   **On-Premises Connection (Required if `ENV_TYPE=onprem`):**
        *   `ONPREM_SERVER`: Your on-premises server name (e.g., `SQLSERVER01` or `SQLSERVER01\SQLEXPRESS`).
        *   `ONPREM_DATABASE`: The name of the database on the on-premises server.
        *   `ONPREM_SQL_LOGIN` (Optional): The SQL login to use if using SQL Authentication (`-AuthMethod sql`).
        *   `ONPREM_SQL_PASSWORD` (Optional): The password for the SQL login if using SQL Authentication (`-AuthMethod sql`).

    *   **Azure Connection (Required if `ENV_TYPE=azure`):**
        *   `AZURE_SERVER`: Your Azure SQL server name (e.g., `yourserver.database.windows.net` or `yourmanagedinstance.public.xxxxx.database.windows.net,3342`).
        *   `AZURE_DATABASE`: The name of the database on the Azure server.
        *   `AZURE_SQL_LOGIN` (Optional): The SQL login to use if using SQL Authentication (`-AuthMethod sql`).
        *   `AZURE_SQL_PASSWORD` (Optional): The password for the SQL login if using SQL Authentication (`-AuthMethod sql`).
        *   `AZURE_ENTRA_LOGIN` (Optional): The email address (UPN) to use for Entra ID MFA authentication (`-AuthMethod entraidmfa`, supported by `Setup-Database.ps1` only).

3.  **`.gitignore` File:** Ensure the `.gitignore` file in the project root contains a line `.env` to prevent accidentally committing this file.

#### Authentication & Connection Logic

PowerShell scripts in this solution (`Setup-Database.ps1`, `007`, `008`, `011`) that connect to SQL Server follow a standard pattern to determine connection settings:

1.  **Parameter Precedence:** Command-line parameters (like `-EnvType`, `-AuthMethod`, `-ServerInstance`, `-DatabaseName`, credentials) **always override** settings found in the `.env` file for that specific script execution. This allows for flexible one-off runs.

2.  **Environment Type Determination:**
    *   The script first looks for the `-EnvType` parameter.
    *   If `-EnvType` is not provided, it reads the `ENV_TYPE` variable from the `.env` file.
    *   The resulting value (`onprem` or `azure`) becomes the *effective environment type* for the run.
    *   An error occurs if neither the parameter nor the `.env` variable provides a valid type.

3.  **Server & Database Determination:**
    *   The script looks for `-ServerInstance` and `-DatabaseName` parameters.
    *   If parameters are missing, it falls back to environment variables *based on the effective environment type*:
        *   If `onprem`: Uses `ONPREM_SERVER` and `ONPREM_DATABASE` from `.env`.
        *   If `azure`: Uses `AZURE_SERVER` and `AZURE_DATABASE` from `.env`.
    *   An error occurs if parameters are missing and the corresponding required environment variables are also missing.

4.  **Authentication Method Determination:**
    *   The script looks for the `-AuthMethod` parameter.
    *   If `-AuthMethod` is not provided, it **defaults based on the effective environment type**:
        *   If `onprem`, defaults to `windows` (Integrated Authentication).
        *   If `azure`, defaults to `sql` (SQL Server Authentication). *(See Note Below)*
    *   The script validates that the chosen (or defaulted) authentication method is supported for the target environment and the specific script being run.

5.  **Credential Determination:**
    *   **`windows`:** No extra credentials needed; uses the current Windows user context.
    *   **`sql`:** Looks for `-SqlLogin` and `-SqlPassword` parameters first. If missing, falls back to environment variables (`ONPREM_SQL_LOGIN`/`PASSWORD` for onprem, `AZURE_SQL_LOGIN`/`PASSWORD` for azure). Error if required credentials aren't found.
    *   **`entraidmfa`:** *(Supported by `Setup-Database.ps1` only)* Looks for the `-LoginEmail` parameter first. If missing, falls back to the `AZURE_ENTRA_LOGIN` environment variable. Triggers interactive browser login. Error if email is not found.

**Note on Azure Authentication Defaults:**
While Microsoft Entra ID MFA (`entraidmfa`) is a highly secure option for interactive logins (supported by `Setup-Database.ps1`), the underlying .NET methods used for bulk data loading in other ETL scripts (`007`, `008`, `011`) have limitations with this method in the current library versions. Therefore, for consistency across the ETL workflow when targeting Azure, the **default authentication method is SQL Authentication (`sql`)**. You must ensure `AZURE_SQL_LOGIN` and `AZURE_SQL_PASSWORD` are set in your `.env` file if you are running these scripts against Azure without providing explicit credentials via parameters.

#### Common Examples (`Setup-Database.ps1`)

```powershell
# Example 1: Run using ONLY settings from the .env file
# Behavior depends entirely on ENV_TYPE and corresponding variables in .env
# e.g., If ENV_TYPE=onprem, attempts Windows Auth to ONPREM_SERVER/DATABASE
# e.g., If ENV_TYPE=azure, attempts SQL Auth to AZURE_SERVER/DATABASE using AZURE_SQL_LOGIN/PASSWORD
.\scripts\mssql\Setup-Database.ps1

# Example 2: Explicitly target On-Prem with default Windows Auth (overrides ENV_TYPE if set to azure)
.\scripts\mssql\Setup-Database.ps1 -EnvType onprem 
# (Equivalent: .\scripts\mssql\Setup-Database.ps1 -EnvType onprem -AuthMethod windows)

# Example 3: Explicitly target On-Prem with SQL Auth (using credentials from .env)
# Requires ONPREM_SQL_LOGIN/PASSWORD in .env
.\scripts\mssql\Setup-Database.ps1 -EnvType onprem -AuthMethod sql

# Example 4: Explicitly target On-Prem with explicit SQL credentials
.\scripts\mssql\Setup-Database.ps1 -EnvType onprem -AuthMethod sql -ServerInstance "onprem-server\sqlexpress" -DatabaseName "onprem-db" -SqlLogin "sa" -SqlPassword "your_onprem_password"

# Example 5: Explicitly target Azure with default SQL Auth (using credentials from .env)
# Requires AZURE_SQL_LOGIN/PASSWORD in .env
.\scripts\mssql\Setup-Database.ps1 -EnvType azure 
# (Equivalent: .\scripts\mssql\Setup-Database.ps1 -EnvType azure -AuthMethod sql)

# Example 6: Explicitly target Azure with explicit SQL credentials
.\scripts\mssql\Setup-Database.ps1 -EnvType azure -AuthMethod sql -ServerInstance "yourserver.database.windows.net" -DatabaseName "azure-db" -SqlLogin "your_azure_sql_user" -SqlPassword "your_azure_sql_password"

# Example 7: Explicitly target Azure with Entra ID MFA (using email from .env)
# Requires AZURE_ENTRA_LOGIN in .env
.\scripts\mssql\Setup-Database.ps1 -EnvType azure -AuthMethod entraidmfa

# Example 8: Explicitly target Azure with explicit Entra ID MFA email 
.\scripts\mssql\Setup-Database.ps1 -EnvType azure -AuthMethod entraidmfa -LoginEmail "user@yourdomain.com"

```

### 3.2 Main Configuration (config.yaml)

This file contains paths, table/schema names, and source-specific processing parameters.

1.  Locate the `config.example.yaml` file.
2.  **Copy** it to `config.yaml` in the same location.
3.  **Edit** `config.yaml`:
    * **`global_settings`:** Verify the `domain_name` and `domain_suffix` match the primary domain for your findings data. Ensure `domain_suffix` includes the leading dot (`.`). Review timeout and batch size settings.
    * **`sources -> mssql` (and other sources):**
        * **Input/Output Files:**
            *   `excel_source_file`: Set the path (absolute or relative to project root) to your raw SQL Server Offline Assessment Excel file.
            *   `csv_clean_file`: Set the path (absolute or relative to project root) where the cleaned CSV from Task 006 should be **written to** and **read from** by subsequent tasks.
            *   `object_whitelist_file`: Set the path (absolute or relative to project root) to the location of the whitelist CSV file (see Section 3.3).
            *   `data_sample_file`: (Optional) Set the path (absolute or relative to project root) to the sample data CSV used by script 011.
        * **Database Objects:**
            *   `raw_schema`, `raw_table`: Verify names for the raw findings table (e.g., `raw`, `mssql_findings`).
            *   `map_schema`, `map_table`: Verify names for the object map table (e.g., `prod`, `mssql_objects_map`).
            *   `stg_schema`, `stg_table`: Verify names for the staging findings table (e.g., `stg`, `mssql_findings`).
            *   `prod_schema`, `prod_table`: Verify names for the final production table.
        * **Processing Parameters:**
            *   `excel_sheet`: Specify the name or 0-based index of the sheet containing the findings within the Excel file.
            *   `excel_header_row`: Specify the 0-based index of the row containing the column headers.
            *   `excel_columns`: Define the column range to read from Excel (e.g., 'A:L').
            *   `header_check_cols`: List mandatory column headers expected in the Excel file.
            *   `key_columns`: List columns that identify a unique finding record for consolidation.
            *   `concat_cols`: List columns whose values should be concatenated for multi-line entries.
            *   `concat_separator`: Define the separator used for concatenation (default: newline).
            *   `source_object_column`: Set the **exact column header name** from the cleaned CSV (output of Task 006) that contains the semi-colon separated list of affected targets (e.g., `'Affected Targets'`).
            *   `extract_ignore_keywords`: List of lowercase strings to ignore during server name extraction.
            *   `sample_data_key_column`: Key column used to join sample data in script 011 (default: `finding_object_id`).
            *   `unknown_object_name`: Keep as `'Unknown'`.
            *   `truncate_staging`: Set to `true` (overwrite staging each run) or `false` (append to staging). Not typically used if `009...staging` script truncates.
            *   `truncate_production`: Set to `true` (overwrite production table each run) or `false` (append). Typically `true`.

### 3.3 Whitelist File (`mssql_map_whitelist.csv`)

**Action Required: This configuration step must be performed by the user or organization deploying the Assessment Tracker.**

This CSV file acts as a **whitelist**, defining exactly which SQL Server instances, nodes, Failover Cluster Instance (FCI) names, or Availability Group (AG) listener names from **your specific environment** should be actively tracked by this tool. The ETL process uses this list to filter the objects identified in the assessment findings.

* Objects found in findings whose names (after normalization) **match** an entry in this whitelist will be processed and linked accordingly.
* Objects found in findings whose names do **not** match any entry in this list (including non-whitelisted servers or items identified as noise like database names) will ultimately be linked to the 'Unknown' object ID during the staging process.

**Steps:**

1.  **Locate/Create the Whitelist CSV file:**
    * The recommended default location for this file within the cloned repository (`storyze` folder) is:
      `data/mssql/mssql_map_whitelist.csv`
    * Ensure this file exists or create a new CSV file with this exact name (`mssql_map_whitelist.csv`) inside the `data/mssql/` directory.
    * **Verify `config.yaml`:** Check the `object_whitelist_file` key under the `mssql` source in your `config.yaml` file. Ensure it points to the correct path of this whitelist file (e.g., `data/mssql/mssql_map_whitelist.csv` if running scripts from the project root, or specify an absolute path if necessary).

2.  **Populate the File:**
    * Open the `data/mssql/mssql_map_whitelist.csv` file.
    * Add **one column** to the file. A header row (e.g., `ServerName`) is recommended for clarity but optional.
    * In this column, list the **canonical names** of all the SQL Server resources from *your environment* that you want findings to be mapped against (Standalone Instances, Nodes, FCI Names, AG Listeners, etc.).
    * **CRITICAL:** Enter the **base names only**. Do **NOT** include the domain suffix (e.g., use `MYSERVER01`, not `MYSERVER01.mycorp.local`). The ETL process strips the domain before comparing against this list.
    * *Example Content:*
      ```csv
      ServerName
      SQLPRODCLST01
      SQLPRODNODEA
      SQLPRODNODEB
      SQLDEV01
      SQLQA01
      PRODAGLISTENER
      ```

3.  **Save the File:** Save `mssql_map_whitelist.csv`, preferably using **UTF-8 encoding**.

*Maintaining the accuracy and completeness of this whitelist file is essential for ensuring the tracker correctly identifies and maps findings to the relevant servers in your environment.*

---

## 4. Database Setup

These steps create the necessary schemas, tables, and views in your target SQL Server database.

There are two primary methods:

**Method 1: Using SQL Server Management Studio (SSMS) (Recommended)**

1.  Connect to your SQL Server instance using SSMS or a similar tool with an account that has the required permissions (see Prerequisites).
2.  Select the target database (e.g., `USE YourDatabaseName;`).
3.  Open and execute the T-SQL scripts located in the `/sql/sql_server/` directory **in the following numerical order**:
    *   `000_create_schemas.sql`
    *   `001_mssql_create_table_raw.sql`
    *   `002_mssql_create_table_map.sql` (Creates map table and inserts 'Unknown' row)
    *   `003_mssql_create_table_staging.sql`
    *   `004_mssql_create_table_prod.sql` (Creates the production table)
    *   `005_mssql_create_view.sql` (Creates the production view)

**Method 2: Using the `Setup-Database.ps1` Helper Script (Optional)**

This PowerShell script executes the same `.sql` files in the correct order.

1.  Open PowerShell and navigate to the project root directory.
2.  Run the script. It uses the connection settings defined in your `.env` file or overridden by command-line parameters (see Section 3.1 for details).
    ```powershell
    # Example using default settings from .env (e.g., Windows Auth for on-prem)
    .\scripts\mssql\Setup-Database.ps1

    # Example explicitly using SQL Auth for on-prem from .env
    .\scripts\mssql\Setup-Database.ps1 -AuthMethod sql

    # Example explicitly targeting Azure using Entra ID MFA from .env
    .\scripts\mssql\Setup-Database.ps1 -EnvType azure 

    # Example overriding everything for an on-prem SQL Auth connection
    .\scripts\mssql\Setup-Database.ps1 -EnvType onprem -AuthMethod sql -ServerInstance "YOUR_SERVER\INSTANCE" -DatabaseName "YOUR_DB" -SqlLogin "your_user" -SqlPassword "your_pass"
    ```
    *(Ensure the account/method used has the necessary SQL permissions to create objects.)*

## 5. Running the ETL Process (MSSQL Example)

Execute the following PowerShell scripts and SQL scripts **in the specified numerical order**. PowerShell scripts should be run from the **project root directory** (the directory containing `config.yaml`) using the `-ConfigPath` and `-Source` parameters. SQL scripts should be run via SSMS (or a similar tool) connected to your target database.

Replace `mssql` with your specific source key from `config.yaml` if different.

*Tip: Add the `-Verbose` switch to any of the PowerShell commands below to see detailed step-by-step output, which can be helpful for troubleshooting.*

**ETL Steps:**

1.  **Script:** `.\scripts\mssql\006_clean_findings.ps1 -ConfigPath .\config.yaml -Source mssql`
    *   **Purpose:** Cleans the raw Excel source file and outputs a standardized CSV (`csv_clean_file`).

2.  **Script:** `.\scripts\mssql\007_load_findings_to_sql.ps1 -ConfigPath .\config.yaml -Source mssql`
    *   **Purpose:** Bulk loads the cleaned CSV into the raw SQL table (`[raw_schema].[raw_table]`).

3.  **Script:** `.\scripts\mssql\008_populate_mssql_map.ps1 -ConfigPath .\config.yaml -Source mssql`
    *   **Purpose:** Populates the object map table (`[map_schema].[map_table]`) with new, whitelisted object names found in the raw data.

4.  **Script:** `sql/sql_server/009_mssql_insert_data_staging.sql` (Run via SSMS)
    *   **Action Required:** Before running this script, you **must** open it and edit the `@DomainSuffixToReplace` variable near the top to match your organization's domain suffix (e.g., `.mycorp.local`). This is crucial for correct object name normalization.
    *   **Purpose:** Loads data from the raw table into the staging table (`[stg_schema].[stg_table]`), normalizing and linking to the map table.

5.  **Script:** `sql/sql_server/010_mssql_update_objectid_prio.sql` (Run via SSMS)
    *   **Purpose:** Calculates `priority_rank` and `finding_object_id` in the staging table.

6.  **Script:** `.\scripts\mssql\011_mssql_load_sample_data.ps1 -ConfigPath .\config.yaml -Source mssql`
    *   **Purpose:** Loads the **provided sample tracking data** into the staging table. This is essential for the **demo** to show reporting features with example tracking info.
    *   **Note:** For real-world usage, this step would involve loading actual tracking data, potentially via a different CSV or method.

7.  **Script:** `sql/sql_server/012_mssql_insert_data_prod.sql` (Run via SSMS)
    *   **Purpose:** Loads the final, processed data from the staging table into the production table (`[prod_schema].[prod_table]`).

After completing these 7 steps in order, the production table (`[prod].[mssql_findings]`) and the corresponding view (`[prod].[vw_mssql_findings]`) should contain the fully processed findings data, ready for reporting in Power BI.

## 6. Power BI Setup (Connecting to SQL Database)

This section describes how to connect the Power BI **template file** (`.pbit`) to the SQL database populated by the ETL process described above.

* **Note:** A simpler CSV-based demo report (`Storyze - CSV.pbix`) is also included in the `docs/pbi_demo` folder. For instructions on using the CSV demo, please refer to the **`How To Storyze.pdf`** document located in the same folder.

**Steps for SQL Template Connection:**

1.  Navigate to the `docs/pbi_demo/` directory.
2.  Open the Power BI Template file: `Storyze - SQL Template.pbit` in Power BI Desktop.
3.  When the template opens, you will likely be prompted to enter parameters for the data source:
    *   **Server Instance:** Enter the name of your SQL Server instance (e.g., `YOUR_SERVER\YOUR_INSTANCE` or `yourserver.database.windows.net`).
    *   **Database Name:** Enter the name of the database where the Storyze tables were created (e.g., `YOUR_DATABASE_NAME`).
4.  Click **Load**. Power BI will attempt to connect to your database using these parameters.
5.  You may be prompted to specify credentials for the database connection. Choose the appropriate authentication method (e.g., Windows, Database) and provide the necessary credentials. The account used needs `SELECT` permissions on the `[prod].[vw_mssql_findings]` view.
6.  Once the connection is successful and credentials are approved, Power BI will load the data from the `[prod].[vw_mssql_findings]` view into the report model.
7.  Save the configured report as a standard `.pbix` file for future use.

## 7. Troubleshooting Tips

-   **PowerShell Errors:** Check script console output for specific error messages. Ensure all required PowerShell modules are available (see Section 2.2). Verify file paths in `config.yaml` (absolute or relative to project root) are correct and accessible. Confirm you are running scripts from the project root directory. Check `.env` variables are correctly set.
-   **SQL Errors:** Check script console output or SSMS messages for specific errors. Verify database connection details in `.env` and/or script parameters are correct. Ensure the SQL login/user has the necessary permissions (see Section 1). Check T-SQL syntax in `.sql` files. Verify referenced tables/columns exist and names match.
-   **Data Not Appearing:** Confirm the correct source Excel file (`excel_source_file`) is specified and processed. Check the contents of the intermediate CSV (`csv_clean_file`). Use SSMS to check row counts in the `raw`, `stg`, and `prod` tables after relevant ETL steps. Ensure the server whitelist (`object_whitelist_file`) contains the expected server names (base names only, no domain suffix). Review script console output for warnings or errors.
-   **Power BI Refresh Errors:** In Power BI Desktop, go to File > Options and settings > Data source settings. Find the SQL Server connection, click "Edit Permissions", and ensure the correct credentials and authentication method are being used. Verify the Server/Database names are accurate. Confirm the underlying view (`[prod].[vw_mssql_findings]`) exists and the account used by Power BI has `SELECT` permissions on it and its underlying tables/schema.

* * * * *
