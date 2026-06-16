# Create Version Release Script
# 创建版本发布的脚本

param(
    [string]$VersionType = "patch", # major, minor, patch
    [string]$Message = "",
    [switch]$Push = $false
)

Write-Host "Creating version release..." -ForegroundColor Green

# Get current version from version-info.json
if (Test-Path "version-info.json") {
    $versionInfo = Get-Content "version-info.json" | ConvertFrom-Json
    $currentVersion = $versionInfo.VersionPrefix
    Write-Host "Current version: $currentVersion" -ForegroundColor Cyan
} else {
    Write-Host "version-info.json not found, using default 1.0.0" -ForegroundColor Yellow
    $currentVersion = "1.0.0"
}

# Parse current version
$versionParts = $currentVersion.Split('.')
$major = [int]$versionParts[0]
$minor = [int]$versionParts[1]
$patch = [int]$versionParts[2]

# Calculate new version
switch ($VersionType) {
    "major" {
        $major++
        $minor = 0
        $patch = 0
    }
    "minor" {
        $minor++
        $patch = 0
    }
    "patch" {
        $patch++
    }
    default {
        Write-Error "Invalid version type: $VersionType. Use major, minor, or patch."
        exit 1
    }
}

$newVersion = "$major.$minor.$patch"
Write-Host "New version: $newVersion" -ForegroundColor Green

# Update version files
Write-Host "Updating version information..." -ForegroundColor Yellow
& "scripts\build-version.ps1" -VersionPrefix $newVersion -BuildConfiguration "Release"

# Create git commit
$commitMessage = if ($Message) { $Message } else { "Release version $newVersion" }
Write-Host "Creating git commit: $commitMessage" -ForegroundColor Yellow

git add .
git commit -m $commitMessage

# Create git tag
$tagName = "v$newVersion"
Write-Host "Creating git tag: $tagName" -ForegroundColor Yellow
git tag -a $tagName -m "Release version $newVersion"

if ($Push) {
    Write-Host "Pushing to remote..." -ForegroundColor Yellow
    git push origin master
    git push origin $tagName
    Write-Host "Pushed to remote repository" -ForegroundColor Green
} else {
    Write-Host "To push the release, run:" -ForegroundColor Cyan
    Write-Host "  git push origin master" -ForegroundColor White
    Write-Host "  git push origin $tagName" -ForegroundColor White
}

Write-Host "Version release $newVersion created successfully!" -ForegroundColor Green