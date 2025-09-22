
# Maintenance Guide

This document is for developers and maintainers of the LiveCaptions Translator application.

## 1. Viewing Logs

For debugging and troubleshooting, the application generates a log file.

-   **Log File Path**: The main log file is named `debug_output.txt` and is located in the root directory of the application.

This file contains runtime information, API responses, and error messages that can be used to diagnose issues.

## 2. Building the Application

To build the application and create the installer, follow these steps.

### Prerequisites

-   [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
-   [NSIS (Nullsoft Scriptable Install System)](https://nsis.sourceforge.io/Download) installed in its default location (`C:\ Program Files (x86)\NSIS`).

### Build Steps

1.  **Open a command prompt** in the root directory of the project.
2.  **Run the build script**:

    ```bash
    .\build-installer.bat
    ```

This script performs the following actions:

-   **Cleans and Publishes the .NET Project**: It runs `dotnet publish` with a `Release` configuration for a self-contained `win-x64` application. The output is placed in `.\bin\Release\net8.0-windows\win-x64\publish`.
-   **Compiles the Installer**: It uses NSIS to compile the installer script located at `.\scripts\deployment\installer.nsi`.
-   **Outputs the Installer**: The final installer will be created in the root directory with the name `DellLiveCaptionsTranslator-LocalEdition-Setup.exe`.

### Manual Build (without installer)

If you only need to build the application without creating the installer, you can run the following .NET CLI command from the root directory:

```bash
dotnet publish .\LiveCaptionsTranslator.csproj -c Release -r win-x64 --self-contained
```

The application will be available in `.\bin\Release\net8.0-windows\win-x64\publish`.
