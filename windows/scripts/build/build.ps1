#!/usr/bin/env pwsh
# PowerShell Core script for cross-platform building

param(
    [string]$Configuration = \"Release\",
    [string]$Runtime = \"win-x64\",
    [string]$Version = \"\",
    [string]$VersionSuffix = \"\",
    [switch]$SkipTests = $false,
    [switch]$SkipInstaller = $false,
    [switch]$Clean = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host \"LiveCaptions Translator Build Script\" -ForegroundColor Green
    Write-Host \"\"
    Write-Host \"Usage: .\\build.ps1 [options]\"
    Write-Host \"\"
    Write-Host \"Options:\"
    Write-Host \"  -Configuration <config>   Build configuration (Debug/Release, default: Release)\"
    Write-Host \"  -Runtime <runtime>        Target runtime (win-x64/win-x86/win-arm64, default: win-x64)\"
    Write-Host \"  -Version <version>        Override version (e.g., 1.2.3)\"
    Write-Host \"  -VersionSuffix <suffix>   Version suffix (e.g., beta, rc)\"
    Write-Host \"  -SkipTests               Skip running tests\"
    Write-Host \"  -SkipInstaller           Skip building installer\"
    Write-Host \"  -Clean                   Clean before building\"
    Write-Host \"  -Help                    Show this help\"
    Write-Host \"\"
    Write-Host \"Examples:\"
    Write-Host \"  .\\build.ps1                                    # Build release version\"
    Write-Host \"  .\\build.ps1 -Configuration Debug              # Build debug version\"
    Write-Host \"  .\\build.ps1 -Version 1.2.3 -VersionSuffix rc  # Build RC version 1.2.3-rc\"
    Write-Host \"  .\\build.ps1 -Clean                            # Clean and build\"
    exit 0
}

# Script configuration
$ProjectFile = \"LiveCaptionsTranslator.csproj\"
$ErrorActionPreference = \"Stop\"
$ProgressPreference = \"SilentlyContinue\"

# Colors for output
$ColorInfo = \"Cyan\"
$ColorSuccess = \"Green\"
$ColorWarning = \"Yellow\"
$ColorError = \"Red\"

function Write-Step {
    param([string]$Message, [string]$Color = $ColorInfo)
    Write-Host \"\"
    Write-Host \"==> $Message\" -ForegroundColor $Color
}

function Write-Success {
    param([string]$Message)
    Write-Host \"✅ $Message\" -ForegroundColor $ColorSuccess
}

function Write-Warning {
    param([string]$Message)
    Write-Host \"⚠️  $Message\" -ForegroundColor $ColorWarning
}

function Write-Error {
    param([string]$Message)
    Write-Host \"❌ $Message\" -ForegroundColor $ColorError
}

try {
    # Validate prerequisites
    Write-Step \"Validating prerequisites\"
    
    if (-not (Get-Command \"dotnet\" -ErrorAction SilentlyContinue)) {
        Write-Error \".NET SDK not found. Please install .NET 8.0 SDK.\"
        exit 1
    }
    
    $dotnetVersion = (dotnet --version).Split('.')[0]
    if ([int]$dotnetVersion -lt 8) {
        Write-Error \".NET 8.0 or later is required. Current version: $(dotnet --version)\"
        exit 1
    }
    
    if (-not (Test-Path $ProjectFile)) {
        Write-Error \"Project file not found: $ProjectFile\"
        exit 1
    }
    
    Write-Success \"Prerequisites validated\"
    
    # Clean if requested
    if ($Clean) {
        Write-Step \"Cleaning previous builds\"
        dotnet clean $ProjectFile
        if (Test-Path \"bin\") { Remove-Item \"bin\" -Recurse -Force }
        if (Test-Path \"obj\") { Remove-Item \"obj\" -Recurse -Force }
        if (Test-Path \"publish\") { Remove-Item \"publish\" -Recurse -Force }
        Get-ChildItem -Filter \"*.exe\" | Remove-Item -Force
        Get-ChildItem -Filter \"version-info.json\" | Remove-Item -Force
        Get-ChildItem -Filter \"release-info-*.txt\" | Remove-Item -Force
        Write-Success \"Clean completed\"
    }
    
    # Generate version information
    Write-Step \"Generating version information\"
    
    $versionParams = @{
        ProjectRoot = \".\"
        BuildConfiguration = $Configuration
        UseGitInfo = $true
    }
    
    if ($Version) { $versionParams.VersionPrefix = $Version }
    if ($VersionSuffix) { $versionParams.VersionSuffix = $VersionSuffix }
    
    $versionInfo = & \".\\scripts\\build-version.ps1\" @versionParams
    
    if (-not $versionInfo) {
        Write-Error \"Failed to generate version information\"
        exit 1
    }
    
    $fullVersion = $versionInfo.InformationalVersion
    $versionNumber = $versionInfo.VersionPrefix
    
    Write-Success \"Version: $fullVersion\"
    
    # Restore dependencies
    Write-Step \"Restoring dependencies\"
    dotnet restore $ProjectFile
    Write-Success \"Dependencies restored\"
    
    # Build application
    Write-Step \"Building application ($Configuration)\"
    dotnet build $ProjectFile --configuration $Configuration --no-restore
    Write-Success \"Build completed\"
    
    # Run tests
    if (-not $SkipTests) {
        Write-Step \"Running tests\"
        $testResult = dotnet test --configuration $Configuration --no-build --verbosity minimal
        if ($LASTEXITCODE -eq 0) {
            Write-Success \"All tests passed\"
        } else {
            Write-Warning \"Some tests failed, but continuing build\"
        }
    } else {
        Write-Warning \"Tests skipped\"
    }
    
    # Publish application
    Write-Step \"Publishing application ($Runtime)\"
    $publishDir = \"publish\"
    dotnet publish $ProjectFile `
        --configuration $Configuration `
        --runtime $Runtime `
        --self-contained `
        --output $publishDir `
        --no-build
    
    Write-Success \"Application published to $publishDir\"
    
    # Build installer
    if (-not $SkipInstaller -and $Runtime -eq \"win-x64\") {
        Write-Step \"Building installer\"
        
        # Check for NSIS
        $nsisPath = \"C:\\Program Files (x86)\\NSIS\\makensis.exe\"
        if (-not (Test-Path $nsisPath)) {
            Write-Warning \"NSIS not found at $nsisPath. Installer build skipped.\"
            Write-Host \"Download NSIS from: https://nsis.sourceforge.io/Download\" -ForegroundColor Yellow
        } else {
            # Build installer using enhanced build script
            $installerArgs = @(
                \"--config\", $Configuration,
                \"--runtime\", $Runtime
            )
            
            if ($Version) {
                $installerArgs += @(\"--version\", $Version)
            }
            
            if ($VersionSuffix) {
                $installerArgs += @(\"--suffix\", $VersionSuffix)
            }
            
            & \".\\build-installer.bat\" @installerArgs
            
            if ($LASTEXITCODE -eq 0) {
                $installerName = "LCT-v$versionNumber-Setup.exe"
                if (Test-Path $installerName) {
                    $size = (Get-Item $installerName).Length
                    $sizeMB = [math]::Round($size / 1MB, 2)
                    Write-Success \"Installer created: $installerName ($sizeMB MB)\"
                } else {
                    Write-Warning \"Installer build completed but file not found\"
                }
            } else {
                Write-Warning \"Installer build failed\"
            }
        }
    } else {
        if ($SkipInstaller) {
            Write-Warning \"Installer build skipped\"
        } else {
            Write-Warning \"Installer build only supported for win-x64 runtime\"
        }
    }
    
    # Summary
    Write-Step \"Build Summary\" $ColorSuccess
    Write-Host \"  Project: LiveCaptions Translator\" -ForegroundColor White
    Write-Host \"  Version: $fullVersion\" -ForegroundColor White
    Write-Host \"  Configuration: $Configuration\" -ForegroundColor White
    Write-Host \"  Runtime: $Runtime\" -ForegroundColor White
    Write-Host \"  Publish Directory: $publishDir\" -ForegroundColor White
    
    if (Test-Path \"version-info.json\") {
        Write-Host \"  Version Info: version-info.json\" -ForegroundColor White
    }
    
    $installerFile = Get-ChildItem -Filter \"*Setup.exe\" | Select-Object -First 1
    if ($installerFile) {
        Write-Host \"  Installer: $($installerFile.Name)\" -ForegroundColor White
    }
    
    Write-Success \"Build completed successfully!\"
    
} catch {
    Write-Error \"Build failed: $($_.Exception.Message)\"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}"