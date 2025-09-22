@echo off
echo =======================================================
echo Building Dell LiveCaptions Translator (Local Edition) Installer
echo =======================================================

set NSIS_PATH="C:\Program Files (x86)\NSIS\makensis.exe"
set PUBLISH_DIR=".\bin\Release\net8.0-windows\win-x64\publish"
set SCRIPT_PATH=".\scripts\deployment\installer.nsi"
set OUTPUT_EXE=".\DellLiveCaptionsTranslator-LocalEdition-Setup.exe"
set PROJECT_FILE="LiveCaptionsTranslator.csproj"

echo.
echo Step 1: Publishing .NET Application...
dotnet clean %PROJECT_FILE%
dotnet publish %PROJECT_FILE% -c Release -r win-x64 --self-contained
if %errorlevel% neq 0 (
    echo.
    echo ERROR: .NET publish command failed.
    pause
    exit /b %errorlevel%
)
echo .NET Application published successfully.

echo.
echo Step 2: Checking for NSIS compiler...
if not exist %NSIS_PATH% (
    echo.
    echo ERROR: NSIS compiler not found at %NSIS_PATH%.
    echo Please make sure NSIS is installed to the default directory.
    pause
    exit /b 1
)
echo NSIS compiler found.

echo.
echo Step 3: Compiling installer with NSIS...
%NSIS_PATH% /DPROJECT_ROOT="%cd%" ".\scripts\deployment\installer.nsi"
if %errorlevel% neq 0 (
    echo.
    echo ERROR: NSIS compilation failed.
    pause
    exit /b %errorlevel%
)

echo.
echo =======================================================
echo Installer created successfully: %OUTPUT_EXE%
echo =======================================================
echo.
pause 