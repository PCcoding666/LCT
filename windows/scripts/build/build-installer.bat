@echo off
setlocal enabledelayedexpansion

echo =======================================================
echo Building LCT (LiveCaptions Translator) with Version Management
echo =======================================================

:: Configuration
set PROJECT_FILE="LiveCaptionsTranslator.csproj"
set BUILD_CONFIG=Release
set TARGET_RUNTIME=win-x64
set NSIS_PATH="C:\Program Files (x86)\NSIS\makensis.exe"
set PUBLISH_DIR=".\bin\Release\net8.0-windows\%TARGET_RUNTIME%\publish"
set INSTALLER_SCRIPT=".\scripts\deployment\installer.nsi"
set VERSION_SCRIPT=".\scripts\build-version.ps1"

:: Parse command line arguments
:parse_args
if "%~1"=="" goto :args_done
if "%~1"=="--version" (
    set VERSION_PREFIX=%~2
    shift
    shift
    goto :parse_args
)
if "%~1"=="--suffix" (
    set VERSION_SUFFIX=%~2
    shift
    shift
    goto :parse_args
)
if "%~1"=="--config" (
    set BUILD_CONFIG=%~2
    shift
    shift
    goto :parse_args
)
if "%~1"=="--runtime" (
    set TARGET_RUNTIME=%~2
    shift
    shift
    goto :parse_args
)
shift
goto :parse_args
:args_done

:: Set default version if not provided
if "%VERSION_PREFIX%"=="" set VERSION_PREFIX=1.0.1
if "%VERSION_SUFFIX%"=="" set VERSION_SUFFIX=

echo Configuration:
echo   Project File: %PROJECT_FILE%
echo   Build Config: %BUILD_CONFIG%
echo   Target Runtime: %TARGET_RUNTIME%
echo   Version Prefix: %VERSION_PREFIX%
echo   Version Suffix: %VERSION_SUFFIX%
echo.

:: Step 1: Generate version information
echo Step 1: Generating version information...
powershell.exe -ExecutionPolicy Bypass -File "%VERSION_SCRIPT%" -ProjectRoot "." -VersionPrefix "%VERSION_PREFIX%" -VersionSuffix "%VERSION_SUFFIX%" -BuildConfiguration "%BUILD_CONFIG%" -UseGitInfo
if %errorlevel% neq 0 (
    echo.
    echo ERROR: Version generation failed.
    pause
    exit /b %errorlevel%
)
echo Version information generated successfully.

:: Load version information from generated JSON
if exist "version-info.json" (
    for /f "tokens=*" %%i in ('powershell.exe -Command "(Get-Content 'version-info.json' | ConvertFrom-Json).InformationalVersion"') do set FULL_VERSION=%%i
    for /f "tokens=*" %%i in ('powershell.exe -Command "(Get-Content 'version-info.json' | ConvertFrom-Json).VersionPrefix"') do set VERSION_NUMBER=%%i
    echo Generated Version: !FULL_VERSION!
) else (
    echo WARNING: version-info.json not found, using default version
    set FULL_VERSION=%VERSION_PREFIX%-%VERSION_SUFFIX%
    set VERSION_NUMBER=%VERSION_PREFIX%
)

:: Step 2: Clean and publish .NET application
echo.
echo Step 2: Publishing .NET Application...
dotnet clean %PROJECT_FILE% -c %BUILD_CONFIG%
if %errorlevel% neq 0 (
    echo.
    echo ERROR: dotnet clean failed.
    pause
    exit /b %errorlevel%
)

dotnet publish %PROJECT_FILE% -c %BUILD_CONFIG% -r %TARGET_RUNTIME% --self-contained
if %errorlevel% neq 0 (
    echo.
    echo ERROR: .NET publish command failed.
    pause
    exit /b %errorlevel%
)
echo .NET Application published successfully.

:: Step 3: Verify published files
echo.
echo Step 3: Verifying published files...
if not exist %PUBLISH_DIR% (
    echo.
    echo ERROR: Publish directory not found: %PUBLISH_DIR%
    pause
    exit /b 1
)

if not exist "%PUBLISH_DIR%\LiveCaptionsTranslator.exe" (
    echo.
    echo ERROR: Main executable not found in publish directory.
    pause
    exit /b 1
)
echo Published files verified.

:: Step 4: Check NSIS compiler
echo.
echo Step 4: Checking for NSIS compiler...

:: Try multiple possible NSIS locations
set NSIS_FOUND=0
if exist %NSIS_PATH% (
    set NSIS_FOUND=1
    echo NSIS compiler found at %NSIS_PATH%
) else (
    echo NSIS not found at default location, checking alternatives...
    
    :: Check Program Files
    set ALT_NSIS_PATH="C:\Program Files\NSIS\makensis.exe"
    if exist !ALT_NSIS_PATH! (
        set NSIS_PATH=!ALT_NSIS_PATH!
        set NSIS_FOUND=1
        echo NSIS compiler found at !ALT_NSIS_PATH!
    )
)

if %NSIS_FOUND%==0 (
    echo.
    echo ERROR: NSIS compiler not found.
    echo Searched locations:
    echo   - C:\Program Files ^(x86^)\NSIS\makensis.exe
    echo   - C:\Program Files\NSIS\makensis.exe
    echo.
    echo Please install NSIS from: https://nsis.sourceforge.io/Download
    echo Make sure to install to the default directory.
    pause
    exit /b 1
)

:: Step 5: Prepare for NSIS compilation
echo.
echo Step 5: Preparing for NSIS compilation...
echo Using installer script: %INSTALLER_SCRIPT%
echo Version: %VERSION_NUMBER%
echo Output: %OUTPUT_NAME%

:: Step 6: Compile installer with NSIS
echo.
echo Step 6: Compiling installer with NSIS...
set OUTPUT_NAME=LCT-v%VERSION_NUMBER%-Setup.exe
%NSIS_PATH% /DPROJECT_ROOT="%cd%" /DAPP_VERSION="%VERSION_NUMBER%" /DOUTPUT_NAME="%OUTPUT_NAME%" "%INSTALLER_SCRIPT%"
if %errorlevel% neq 0 (
    echo.
    echo ERROR: NSIS compilation failed.
    pause
    exit /b %errorlevel%
)

:: Step 7: Verify installer
echo.
echo Step 7: Verifying installer...
set INSTALLER_PATH="scripts\deployment\%OUTPUT_NAME%"
if not exist %INSTALLER_PATH% (
    echo.
    echo ERROR: Installer not created: %OUTPUT_NAME%
    echo Expected location: %INSTALLER_PATH%
    pause
    exit /b 1
)

:: Get file size
for %%F in (%INSTALLER_PATH%) do set INSTALLER_SIZE=%%~zF
set /a INSTALLER_SIZE_MB=!INSTALLER_SIZE!/1024/1024

echo.
echo =======================================================
echo Build completed successfully!
echo =======================================================
echo Installer: %OUTPUT_NAME%
echo Version: !FULL_VERSION!
echo Size: !INSTALLER_SIZE_MB! MB
echo Location: %cd%\scripts\deployment\%OUTPUT_NAME%
echo =======================================================

:: Step 8: Optional - Create release notes
echo.
echo Step 8: Creating release information...
set RELEASE_INFO_FILE=release-info-%VERSION_NUMBER%.txt
echo LiveCaptions Translator v%VERSION_NUMBER% > "%RELEASE_INFO_FILE%"
echo Build Date: %DATE% %TIME% >> "%RELEASE_INFO_FILE%"
echo Full Version: !FULL_VERSION! >> "%RELEASE_INFO_FILE%"
echo Configuration: %BUILD_CONFIG% >> "%RELEASE_INFO_FILE%"
echo Target Runtime: %TARGET_RUNTIME% >> "%RELEASE_INFO_FILE%"
echo Installer Size: !INSTALLER_SIZE_MB! MB >> "%RELEASE_INFO_FILE%"
echo. >> "%RELEASE_INFO_FILE%"
echo Files: >> "%RELEASE_INFO_FILE%"
echo   - %OUTPUT_NAME% >> "%RELEASE_INFO_FILE%"
if exist "version-info.json" echo   - version-info.json >> "%RELEASE_INFO_FILE%"
echo Release information saved to: %RELEASE_INFO_FILE%

echo.
echo Build process completed! Press any key to exit.
pause > nul