# PowerShell Deployment Script for LiveCaptions Translator
# This script handles automated deployment tasks

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet(\"build\", \"test\", \"package\", \"deploy\", \"release\")]
    [string]$Action,
    
    [string]$Version = \"\",
    [string]$Environment = \"production\",
    [string]$Configuration = \"Release\",
    [switch]$SkipTests = $false,
    [switch]$Force = $false,
    [switch]$Verbose = $false
)

# Script configuration
$ErrorActionPreference = \"Stop\"
if ($Verbose) { $VerbosePreference = \"Continue\" }

# Colors
$ColorInfo = \"Cyan\"
$ColorSuccess = \"Green\"
$ColorWarning = \"Yellow\"
$ColorError = \"Red\"

function Write-Log {
    param([string]$Message, [string]$Level = \"INFO\", [string]$Color = \"White\")
    $timestamp = Get-Date -Format \"yyyy-MM-dd HH:mm:ss\"
    Write-Host \"[$timestamp] [$Level] $Message\" -ForegroundColor $Color
}

function Write-Success { param([string]$Message) Write-Log $Message \"SUCCESS\" $ColorSuccess }
function Write-Warning { param([string]$Message) Write-Log $Message \"WARNING\" $ColorWarning }
function Write-Error { param([string]$Message) Write-Log $Message \"ERROR\" $ColorError }

try {
    Write-Log \"Starting deployment script - Action: $Action, Environment: $Environment\" \"INFO\" $ColorInfo
    
    # Validate prerequisites
    if (-not (Get-Command \"dotnet\" -ErrorAction SilentlyContinue)) {
        throw \".NET SDK not found. Please install .NET 8.0 SDK.\"
    }
    
    if (-not (Test-Path \"LiveCaptionsTranslator.csproj\")) {
        throw \"Project file not found. Please run this script from the project root.\"
    }
    
    # Load version information
    if ($Version) {
        $versionInfo = & \".\\scripts\\build-version.ps1\" -VersionPrefix $Version -BuildConfiguration $Configuration
    } else {
        $versionInfo = & \".\\scripts\\build-version.ps1\" -BuildConfiguration $Configuration
    }
    
    $fullVersion = $versionInfo.InformationalVersion
    Write-Log \"Working with version: $fullVersion\" \"INFO\" $ColorInfo
    
    switch ($Action) {
        \"build\" {
            Write-Log \"Building application...\" \"INFO\" $ColorInfo
            
            # Clean previous builds
            dotnet clean
            
            # Restore packages
            dotnet restore
            
            # Build application
            dotnet build --configuration $Configuration --no-restore
            
            Write-Success \"Build completed successfully\"
        }
        
        \"test\" {
            Write-Log \"Running tests...\" \"INFO\" $ColorInfo
            
            # Run unit tests
            $testResult = dotnet test --configuration $Configuration --logger \"trx\" --results-directory \"TestResults\"
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success \"All tests passed\"
            } else {
                throw \"Tests failed with exit code $LASTEXITCODE\"
            }
        }
        
        \"package\" {
            Write-Log \"Creating deployment package...\" \"INFO\" $ColorInfo
            
            # Build first
            if (-not $SkipTests) {
                & $PSCommandPath -Action \"test\" -Configuration $Configuration -Verbose:$Verbose
            }
            
            & $PSCommandPath -Action \"build\" -Configuration $Configuration -Verbose:$Verbose
            
            # Publish application
            $publishDir = \"publish\\$Environment\"
            dotnet publish --configuration $Configuration --runtime win-x64 --self-contained --output $publishDir
            
            # Create installer
            if (Test-Path \"C:\\Program Files (x86)\\NSIS\\makensis.exe\") {
                Write-Log \"Building installer...\" \"INFO\" $ColorInfo
                & \".\\build-installer.bat\" --config $Configuration --version $($versionInfo.VersionPrefix)
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Success \"Installer created successfully\"
                } else {
                    Write-Warning \"Installer build failed\"
                }
            } else {
                Write-Warning \"NSIS not found, skipping installer creation\"
            }
            
            # Create deployment artifacts
            $artifactsDir = \"artifacts\\$Environment\"
            if (-not (Test-Path $artifactsDir)) {
                New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
            }
            
            # Copy published files
            Copy-Item -Path \"$publishDir\\*\" -Destination $artifactsDir -Recurse -Force
            
            # Copy installer if exists
            $installerFile = Get-ChildItem -Filter \"*Setup.exe\" | Select-Object -First 1
            if ($installerFile) {
                Copy-Item -Path $installerFile.FullName -Destination $artifactsDir
            }
            
            # Copy version info
            if (Test-Path \"version-info.json\") {
                Copy-Item -Path \"version-info.json\" -Destination $artifactsDir
            }
            
            Write-Success \"Deployment package created in $artifactsDir\"
        }
        
        \"deploy\" {
            Write-Log \"Deploying to $Environment environment...\" \"INFO\" $ColorInfo
            
            # Create package first
            & $PSCommandPath -Action \"package\" -Environment $Environment -Configuration $Configuration -SkipTests:$SkipTests -Verbose:$Verbose
            
            # Deploy based on environment
            switch ($Environment) {
                \"staging\" {
                    Write-Log \"Deploying to staging environment\" \"INFO\" $ColorInfo
                    # Implement staging deployment logic
                }
                \"production\" {
                    Write-Log \"Deploying to production environment\" \"INFO\" $ColorInfo
                    
                    if (-not $Force) {
                        $confirm = Read-Host \"Are you sure you want to deploy to PRODUCTION? (yes/no)\"
                        if ($confirm -ne \"yes\") {
                            throw \"Production deployment cancelled by user\"
                        }
                    }
                    
                    # Implement production deployment logic
                    # This could include:
                    # - Uploading to file server
                    # - Creating GitHub release
                    # - Updating download links
                    # - Notifying users
                }
                default {
                    Write-Warning \"Unknown environment: $Environment\"
                }
            }
            
            Write-Success \"Deployment to $Environment completed\"
        }
        
        \"release\" {
            Write-Log \"Creating release for version $fullVersion\" \"INFO\" $ColorInfo
            
            # Validate version is not a dev build
            if ($versionInfo.InformationalVersion -like \"*dev*\") {
                throw \"Cannot create release from development version\"
            }
            
            # Check if tag already exists
            $tagName = \"v$($versionInfo.VersionPrefix)\"
            $existingTag = git tag -l $tagName 2>$null
            if ($existingTag -and -not $Force) {
                throw \"Tag $tagName already exists. Use -Force to overwrite.\"
            }
            
            # Create package
            & $PSCommandPath -Action \"package\" -Environment \"production\" -Configuration \"Release\" -Verbose:$Verbose
            
            # Create git tag
            Write-Log \"Creating git tag $tagName\" \"INFO\" $ColorInfo
            if ($existingTag) {
                git tag -d $tagName
                git push origin --delete $tagName
            }
            git tag -a $tagName -m \"Release version $($versionInfo.VersionPrefix)\"
            git push origin $tagName
            
            # Create release notes
            $releaseNotes = @\"
# LiveCaptions Translator v$($versionInfo.VersionPrefix)

**Release Date:** $(Get-Date -Format 'yyyy-MM-dd')
**Full Version:** $fullVersion

## Changes

<!-- Add release notes here -->

## Download

- Windows Installer: LCT-v$($versionInfo.VersionPrefix)-Setup.exe
- Portable Version: Available in artifacts

## System Requirements

- Windows 10 version 1903 or later
- .NET 8.0 Runtime (included in installer)
- Visual C++ 2015-2022 Redistributable (included in installer)

\"@
            
            $releaseNotesFile = \"RELEASE_NOTES_v$($versionInfo.VersionPrefix).md\"
            Set-Content -Path $releaseNotesFile -Value $releaseNotes
            
            Write-Success \"Release $tagName created successfully\"
            Write-Log \"Release notes saved to: $releaseNotesFile\" \"INFO\" $ColorInfo
            Write-Log \"Next steps:\" \"INFO\" $ColorInfo
            Write-Log \"  1. Edit $releaseNotesFile with actual changes\" \"INFO\" $ColorInfo
            Write-Log \"  2. Create GitHub release from tag $tagName\" \"INFO\" $ColorInfo
            Write-Log \"  3. Upload installer and artifacts\" \"INFO\" $ColorInfo
        }
        
        default {
            throw \"Unknown action: $Action\"
        }
    }
    
    Write-Success \"Deployment script completed successfully\"
    
} catch {
    Write-Error \"Deployment script failed: $($_.Exception.Message)\"
    Write-Host $_.ScriptStackTrace -ForegroundColor $ColorError
    exit 1
}"