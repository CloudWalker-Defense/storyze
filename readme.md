# Storyze Assessment Tracker

## Overview

The Storyze Assessment Tracker is a comprehensive solution for tracking, monitoring, and managing security and compliance findings from Microsoft SQL Server assessments. This tool provides a streamlined ETL (Extract, Transform, Load) process for cleaning, normalizing, and loading assessment data into SQL Server, enabling effective tracking and visualization of issues.

**Note: Only SQL Server Offline Assessment results are included in this repository. If you're interested in any of the other Offline Assessment products (e.g., SCOM, Active Directory), please contact us at [info@cloudwalkerdefense.com](mailto:info@cloudwalkerdefense)**

## Key Features

- **🔄 Automated ETL Pipeline**: PowerShell scripts for cleaning, loading, and transforming assessment data
- **📊 Data Normalization**: Standardizes server names, categorizes findings, and assigns priorities
- **🗺️ Object Mapping**: Maps findings to specific servers using customizable whitelists
- **📈 Tracking Capabilities**: Track remediation status, exceptions, and notes with built-in sample data
- **📊 Visualization**: Pre-built Power BI reports for effective data analysis and reporting
- **⚙️ Flexible Configuration**: Run with environment variables or explicit parameters for maximum flexibility
- **🔐 Multiple Authentication**: Supports Windows and SQL authentication for both on-premises and Azure environments

## System Requirements

- **PowerShell**: Version 5.1 or higher (all required modules are bundled)
- **SQL Server**: Version 2016 or higher (for `STRING_SPLIT` function support)
- **Power BI**: For report visualization (template included)

## Quick Start

For detailed setup and usage instructions, see the [Setup Guide](docs/setup.md).

1. **Clone the repository** and verify module requirements
2. **Configure your environment** in the config.yaml file
3. **Set up your database** using the setup scripts
4. **Run the ETL process** to prepare your data
5. **Connect to your data** with the Power BI template

The configuration files include example data and templates to help you get started quickly. The ETL process is fully parameterized to adapt to your specific environment.

**Note on Sample Data**: The included sample data file contains data for finding IDs up to 950. If your dataset includes IDs above this limit, you'll need to create an extended sample data file.

## Authentication Methods

Storyze supports multiple authentication methods for flexibility in different environments:

### 🔒 On-premises SQL Server
- **Windows Authentication** (default): Uses current Windows credentials
- **SQL Authentication**: Username/password for SQL Server login

### ☁️ Azure SQL Database
- **SQL Authentication**: Username/password for Azure SQL login

Authentication parameters can be passed directly to scripts or stored in your .env file for convenience.

## Support

📧 **Contact**: [info@cloudwalkerdefense.com](mailto:info@cloudwalkerdefense.com)  
🌐 **Website**: [www.cloudwalkerdefense.com](https://www.cloudwalkerdefense.com)

CloudWalker Defense is a Hispanic, Service-Disabled Veteran-Owned Small Business (SDVOSB) 
that accelerates digital transformation for the U.S. Federal Government.

## Core Utilities

All ETL and setup scripts utilize the `StoryzeUtils.psm1` module, which provides:

- **Dependency Management**: Automatically loads required PowerShell modules
- **Configuration Handling**: Reads YAML configuration and .env files
- **Database Connectivity**: Manages connections to SQL Server instances
- **Data Processing**: Provides data cleaning and transformation utilities

The module is automatically loaded by all scripts - no manual steps required.