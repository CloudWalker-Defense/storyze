# Contributing to Storyze Assessment Tracker

Thank you for your interest in contributing! We welcome improvements to the code, documentation, and overall project. Please take a moment to review these guidelines.

## Getting Started

* **Environment Setup:** Before making changes, please ensure you have set up your local development environment by following the instructions in the **`/docs/setup.md`** file.
* **Find/Discuss Work:** Check the repository's **Issues tab** to see if your idea or bug is already being tracked. Feel free to open a new issue to discuss potential changes before you start coding.

## Standards

1.  **Coding Standards:**
    * **SQL:**
        * Use **bracket notation** for all schema and object identifiers (e.g., `[stg].[mssql_findings]`, `[normalized_object]`).
        * Use standard T-SQL compatible with SQL Server 2016+.
        * Format code clearly and add comments for complex sections.
    * **PowerShell:**
        * Follow standard PowerShell **Verb-Noun** naming conventions for functions (e.g., `Import-YamlConfiguration`, `Initialize-RequiredModules`).
        * Use **PascalCase** for function names and parameters (e.g., `-ConfigPath`, `function Load-Whitelist`). Use **camelCase** for internal script variables (e.g., `$requiredModules`, `$conn`).
        * Format code clearly and use `#` comments for explanations. Use comment-based help (`<# .SYNOPSIS ... #>`) for script files and functions where appropriate.
        * Aim for compatibility with PowerShell 5.1+.
    * **General:**
        * Keep code readable and maintainable.
        * **Do not commit secrets** or user-specific paths. Use `.env` and `config.yaml` for configuration.
2.  **Commit Messages:** Write clear and concise commit messages describing the change (e.g., `fix: Correct domain suffix stripping in staging SQL`, `feat: Add initial data cleaning script for SCOM`).
3.  **Testing:** If adding new features, consider how they could be tested (manual testing steps are acceptable initially).

## Submitting Changes (Pull Requests)

1.  Push your branch to your fork (if applicable) or the main repository.
2.  Open a **Pull Request (PR)** against the repository's `main` branch.
3.  Provide a clear title and description for your PR, explaining the changes and linking to any relevant issues.
4.  We will review the PR. Please respond to any feedback or requested changes.
5.  Once approved, your contribution will be merged.

Thank you for helping improve the Storyze Assessment Tracker!