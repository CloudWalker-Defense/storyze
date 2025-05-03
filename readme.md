# Storyze Assessment Tracker

## Overview

The Storyze Assessment Tracker is a comprehensive solution for tracking, monitoring, and managing security and compliance findings from Microsoft SQL Server assessments. This tool provides a streamlined ETL (Extract, Transform, Load) process for cleaning, normalizing, and loading assessment data into SQL Server, enabling effective tracking and visualization of issues.

**Note: Only SQL Server Offline Assessment results are included in this repository. If you're interested in any of the other Offline Assessment products (e.g., SCOM, Active Directory), please contact us at [info@cloudwalkerdefense.com](mailto:info@cloudwalkerdefense)**

## Key Features

- **Automated ETL Pipeline**: PowerShell scripts for cleaning, loading, and transforming assessment data.
- **Data Normalization**: Standardizes server names, categorizes findings, and assigns priorities.
- **Object Mapping**: Maps findings to specific servers using customizable whitelists.
- **Tracking Capabilities**: Allows tracking of remediation status, exceptions, and notes via sample data updates.
- **Visualization**: Pre-built Power BI reports for effective data analysis.

## PowerShell Scripts

The core ETL logic is handled by PowerShell scripts in the `scripts/mssql/` directory:

- `006_clean_findings.ps1`: Reads raw findings from an Excel source, cleans data (handles multi-line entries, trims whitespace), and outputs a standardized CSV (`csv_clean_file` from config).
- `007_load_findings_to_sql.ps1`: Bulk loads the cleaned CSV data into the raw SQL table (`[raw_schema].[raw_table]` from config). Uses `SqlBulkCopy` for efficiency. Can truncate or append.
- `008_populate_mssql_map.ps1`: Extracts unique object names from raw data, compares against a whitelist (`object_whitelist_file` from config) and existing map entries, then inserts new, whitelisted objects into the map table (`[map_schema].[map_table]` from config).
- `011_mssql_load_sample_data.ps1`: Updates the staging table (`[stg_schema].[stg_table]`) with tracking data (LOE, assignment, dates, etc.) from a sample CSV file (`data_sample_file` from config or `-SampleDataPath` parameter) using an efficient temp table and bulk update approach.

**Helper Scripts:**
- `StoryzeUtils.psm1`: Contains common functions used by the other scripts.

## System Requirements

- **PowerShell**: Version 5.1 or higher.
- **PowerShell Modules**: `SqlServer`, `powershell-yaml`, `ImportExcel`. Bundled versions are included in the `Modules/` directory and used by default.
- **SQL Server**: Version 2016 or higher (for `STRING_SPLIT` function support).
- **Power BI**: For report visualization.

## Getting Started

Follow these steps to set up and use the Storyze Assessment Tracker:

1.  **Clone the Repository**:
    ```bash
    git clone https://github.com/CloudWalker-Defense/storyze.git
    cd storyze
    ```

2.  **Check Modules**: Verify the `Modules/` directory exists. No installation is typically needed as scripts use the bundled modules. See [Setup Guide Section 2.2](docs/setup.md#22-powershell-module-requirements) for details.

3.  **Configure Environment**:
    - Copy `.env.example` to `.env` and update database credentials (see [Setup Guide 3.1](docs/setup.md#31-environment-variables-env)).
    - Copy `config.example.yaml` to `config.yaml`. Update necessary paths (like `excel_source_file`, `csv_clean_file`, `object_whitelist_file`), table/schema names, Excel details, etc. (see [Setup Guide 3.2](docs/setup.md#32-main-configuration-configyaml)).
    - **Crucially**: Create and populate the server whitelist file (e.g., `data/mssql/mssql_map_whitelist.csv`) as specified by `object_whitelist_file` in `config.yaml`. This defines which servers to track (see [Setup Guide 3.3](docs/setup.md#33-whitelist-file)).
    - Optionally, prepare a sample data CSV file for tracking updates and set its path in `config.yaml` (`data_sample_file`).

4.  **Set Up Database**: Connect to your SQL instance (e.g., using SSMS) and execute the `.sql` scripts in `sql/sql_server/` **in numerical order** (`000` through `005`) against your target database. Alternatively, you can use the helper script: `.\scripts\mssql\Setup-Database.ps1`. See [Setup Guide 4](docs/setup.md#4-database-setup).

5.  **Run ETL Process**: Execute the following scripts **in the specified order**. PowerShell scripts should be run from the project root directory. SQL scripts should be run via SSMS (or a similar tool). See [Setup Guide 5](docs/setup.md#5-running-the-etl-process-mssql-example) for full details. *Tip: Add the `-Verbose` flag to any PowerShell command to see detailed execution logs.*
    *   **Step 1 (PS):** `.\scripts\mssql\006_clean_findings.ps1 -ConfigPath .\config.yaml -Source mssql` (Cleans Excel source)
    *   **Step 2 (PS):** `.\scripts\mssql\007_load_findings_to_sql.ps1 -ConfigPath .\config.yaml -Source mssql` (Loads cleaned CSV to Raw Table)
    *   **Step 3 (PS):** `.\scripts\mssql\008_populate_mssql_map.ps1 -ConfigPath .\config.yaml -Source mssql` (Populates Map Table)
    *   **Note on PowerShell Script Authentication:** The example commands above rely on default connection settings derived from your `.env` file (`ENV_TYPE` determines defaults: On-Prem uses Windows Auth, Azure uses SQL Auth with `AZURE_SQL_LOGIN`/`PASSWORD`). If you need to override these, you can use parameters like `-EnvType`, `-AuthMethod`, `-SqlLogin`, `-SqlPassword`. The `Setup-Database.ps1` script also supports `-AuthMethod entraidmfa` with `-LoginEmail` for Azure MFA. See the [Setup Guide Authentication Section](docs/setup.md#authentication-details) for comprehensive details and examples.
    *   **Step 4 (SQL):** `009_mssql_insert_data_staging.sql` (Loads Staging Table from Raw/Map)
    *   **Step 5 (SQL):** `010_mssql_update_objectid_prio.sql` (Calculates Priority/ID in Staging)
    *   **Step 6 (PS):** `.\scripts\mssql\011_mssql_load_sample_data.ps1 -ConfigPath .\config.yaml -Source mssql` (Loads **sample tracking data** into Staging for demo purposes)
    *   **Step 7 (SQL):** `012_mssql_insert_data_prod.sql` (Loads Production Table from Staging)
    *   *Note: For real-world deployment, the sample data loaded in Step 6 would be replaced by actual tracking data mechanisms.*

6.  **View Reports**: Open and configure the Power BI file (`docs/pbi_demo/Storyze.pbix`) (see [Setup Guide 6](docs/setup.md#6-power-bi-setup)).

For detailed setup and usage instructions, see the full [Setup Guide](docs/setup.md).

## Directory Structure

- `config.yaml`: Configuration settings
- `data/`: Input and output data files
- `docs/`: Documentation and Power BI reports
- `scripts/`: PowerShell scripts for ETL processes
- `sql/`: SQL scripts for database setup and operations

## License

This project is licensed under the MIT License - see the [LICENSE](license) file for details.

## Contributing

We welcome contributions! Please see [contributing.md](contributing.md) for more details.

## Support

- CloudWalker Defense, a Hispanic, Service-Disabled Veteran-Owned Small Business (SDVOSB), accelerates digital transformation for the U.S. Federal Government. With over 15+ years of combined DoD and commercial experience, we fuse creativity, cutting-edge technology, and strategic vision to optimize your operations and mission-critical capabilities.
- Contact us: [info@cloudwalkerdefense.com](mailto:info@cloudwalkerdefense)
- Visit our website: [www.cloudwalkerdefense.com](https://www.cloudwalkerdefense.com)  

