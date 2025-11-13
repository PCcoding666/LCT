# Create GitHub Release Script
param(
    [string]$Version = "1.0.2"
)

Write-Host "=============================================" -ForegroundColor Green
Write-Host "  GitHub Release Creator for LCT v$Version" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""

# Configuration
$repoOwner = "PCcoding666"
$repoName = "Dell-LiveCaptions-Translator"
$tagName = "v$Version"
$InstallerPath = "scripts\deployment\LCT-v$Version-Setup.exe"

# Check if installer exists
if (-not (Test-Path $InstallerPath)) {
    Write-Host "Error: Installer not found at $InstallerPath" -ForegroundColor Red
    exit 1
}

$fileSize = (Get-Item $InstallerPath).Length / 1MB
$fileSizeMB = [math]::Round($fileSize, 2)

Write-Host "Found installer: $InstallerPath ($fileSizeMB MB)" -ForegroundColor Green
Write-Host ""

# Generate release notes
$buildNumber = "N/A"
if (Test-Path "version-info.json") {
    $versionInfo = Get-Content "version-info.json" | ConvertFrom-Json
    $buildNumber = $versionInfo.BuildNumber
}

$releaseNotes = @"
# LCT (LiveCaptions Translator) v$Version

## What's New

### Features
- History Delete Functionality: Added individual and batch delete options
  - Each history entry now has a delete button
  - Delete all history with confirmation dialog
  - Improved user experience with success notifications

### Improvements
- Database Enhancements: Added ID field support in TranslationHistoryEntry model
- Delete Operations: New DeleteHistoryById method in HistoryLogger
- User Feedback: Added confirmation dialogs to prevent accidental deletions

### Technical Details
- Version: $Version
- Build: $buildNumber
- Configuration: Release
- File Size: $fileSizeMB MB

## Installation

1. Download LCT-v$Version-Setup.exe
2. Run the installer
3. Follow the setup wizard

## System Requirements
- Windows 11 22H2 or later (with Live Captions support)
- .NET 8.0 Runtime (included in installer)
- 8GB+ RAM recommended
- 2GB+ available disk space

**Full Changelog**: https://github.com/$repoOwner/$repoName/compare/v1.0.1...v$Version
"@

# Save release notes
$releaseNotesFile = "release-notes-v$Version.md"
Set-Content -Path $releaseNotesFile -Value $releaseNotes -Encoding UTF8
Write-Host "Release notes saved to: $releaseNotesFile" -ForegroundColor Green
Write-Host ""

# Create and push git tag
Write-Host "Checking git tag..." -ForegroundColor Yellow
$tagExists = git tag -l $tagName
if (-not $tagExists) {
    Write-Host "Creating git tag: $tagName" -ForegroundColor Yellow
    git tag -a $tagName -m "Release version $Version"
    
    Write-Host "Pushing tag to remote..." -ForegroundColor Yellow
    git push origin $tagName
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Tag pushed successfully" -ForegroundColor Green
    } else {
        Write-Host "Failed to push tag. Please push manually: git push origin $tagName" -ForegroundColor Yellow
    }
} else {
    Write-Host "Tag already exists: $tagName" -ForegroundColor Green
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Next Steps" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "To complete the GitHub Release:" -ForegroundColor Cyan
Write-Host "1. Visit: https://github.com/$repoOwner/$repoName/releases/new?tag=$tagName" -ForegroundColor White
Write-Host "2. Set release title: LCT v$Version" -ForegroundColor White
Write-Host "3. Copy release notes from: $releaseNotesFile" -ForegroundColor White
Write-Host "4. Upload installer: $InstallerPath" -ForegroundColor White
Write-Host "5. Click 'Publish release'" -ForegroundColor White
Write-Host ""
