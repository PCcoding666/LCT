# Version Builder PowerShell Script
# This script generates version information and updates AssemblyInfo.cs

param(
    [string]$ProjectRoot = ".",
    [string]$VersionPrefix = "1.0.1",
    [string]$VersionSuffix = "",
    [string]$BuildConfiguration = "Release",
    [switch]$UseGitInfo = $true
)

# Ensure we're in the correct directory
Set-Location $ProjectRoot

Write-Host "Version Builder starting..." -ForegroundColor Green
Write-Host "Project Root: $ProjectRoot" -ForegroundColor Gray
Write-Host "Version Prefix: $VersionPrefix" -ForegroundColor Gray
Write-Host "Version Suffix: $VersionSuffix" -ForegroundColor Gray
Write-Host "Build Configuration: $BuildConfiguration" -ForegroundColor Gray

# Git information gathering
$gitCommitHash = "unknown"
$gitBranch = "unknown"
$gitCommitCount = 0

if ($UseGitInfo -and (Test-Path ".git")) {
    try {
        # Get commit hash
        $gitCommitHash = (git rev-parse HEAD 2>$null).Trim()
        if (-not $gitCommitHash) { $gitCommitHash = "unknown" }
        
        # Get branch name
        $gitBranch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
        if (-not $gitBranch) { $gitBranch = "unknown" }
        
        # Get commit count for build number
        $gitCommitCountStr = (git rev-list --count HEAD 2>$null).Trim()
        if ($gitCommitCountStr -and $gitCommitCountStr -match '^\d+$') {
            $gitCommitCount = [int]$gitCommitCountStr
        }
        
        Write-Host "Git Commit: $gitCommitHash" -ForegroundColor Gray
        Write-Host "Git Branch: $gitBranch" -ForegroundColor Gray
        Write-Host "Git Commit Count: $gitCommitCount" -ForegroundColor Gray
    }
    catch {
        Write-Warning "Failed to get Git information: $($_.Exception.Message)"
    }
} else {
    Write-Host "Git information disabled or .git directory not found" -ForegroundColor Yellow
}

# Generate version numbers
$buildNumber = $gitCommitCount
if ($buildNumber -eq 0) {
    $buildNumber = [int]((Get-Date).ToString("yyyyMMdd"))
}

# Parse version prefix
$versionParts = $VersionPrefix.Split('.')
if ($versionParts.Length -lt 3) {
    Write-Error "Version prefix must be in format Major.Minor.Patch (e.g., 1.0.0)"
    exit 1
}

$majorVersion = $versionParts[0]
$minorVersion = $versionParts[1]
$patchVersion = $versionParts[2]

# Determine version suffix based on branch and configuration
if ($BuildConfiguration -eq "Release") {
    if ($gitBranch -eq "main" -or $gitBranch -eq "master") {
        $VersionSuffix = ""  # Release version
    } elseif ($gitBranch -like "release/*") {
        $VersionSuffix = "rc"  # Release candidate
    } elseif ($gitBranch -like "hotfix/*") {
        $VersionSuffix = "hotfix"
    } else {
        $VersionSuffix = "beta"  # Beta version for other branches
    }
}

# Build version strings
$assemblyVersion = "$majorVersion.$minorVersion.$patchVersion.0"
$fileVersion = "$majorVersion.$minorVersion.$patchVersion.$buildNumber"

if ($VersionSuffix) {
    $informationalVersion = "$VersionPrefix-$VersionSuffix+$buildNumber"
} else {
    $informationalVersion = "$VersionPrefix+$buildNumber"
}

$buildTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "Generated Versions:" -ForegroundColor Green
Write-Host "  Assembly Version: $assemblyVersion" -ForegroundColor White
Write-Host "  File Version: $fileVersion" -ForegroundColor White
Write-Host "  Informational Version: $informationalVersion" -ForegroundColor White
Write-Host "  Build Timestamp: $buildTimestamp" -ForegroundColor White

# Update AssemblyInfo.cs
$assemblyInfoPath = "src\AssemblyInfo.cs"
if (-not (Test-Path $assemblyInfoPath)) {
    Write-Error "AssemblyInfo.cs not found at $assemblyInfoPath"
    exit 1
}

Write-Host "Updating AssemblyInfo.cs..." -ForegroundColor Yellow

# Read current content
$content = Get-Content $assemblyInfoPath -Raw

# Replace version attributes (using single quotes for regex patterns for clarity)
$content = $content -replace '\[assembly: AssemblyVersion\(".*?"\)\]', "[assembly: AssemblyVersion(""$assemblyVersion"")]"
$content = $content -replace '\[assembly: AssemblyFileVersion\(".*?"\)\]', "[assembly: AssemblyFileVersion(""$fileVersion"")]"
$content = $content -replace '\[assembly: AssemblyInformationalVersion\(".*?"\)\]', "[assembly: AssemblyInformationalVersion(""$informationalVersion"")]"

# Replace metadata attributes
$content = $content -replace '\[assembly: AssemblyMetadata\("GitCommitHash", ".*?"\)\]', "[assembly: AssemblyMetadata(""GitCommitHash"", ""$gitCommitHash"")]"
$content = $content -replace '\[assembly: AssemblyMetadata\("GitBranch", ".*?"\)\]', "[assembly: AssemblyMetadata(""GitBranch"", ""$gitBranch"")]"
$content = $content -replace '\[assembly: AssemblyMetadata\("BuildTimestamp", ".*?"\)\]', "[assembly: AssemblyMetadata(""BuildTimestamp"", ""$buildTimestamp"")]"
$content = $content -replace '\[assembly: AssemblyMetadata\("BuildConfiguration", ".*?"\)\]', "[assembly: AssemblyMetadata(""BuildConfiguration"", ""$BuildConfiguration"")]"

# Write updated content
Set-Content $assemblyInfoPath $content -Encoding UTF8

Write-Host "AssemblyInfo.cs updated successfully!" -ForegroundColor Green

# Export version information for build scripts
$versionInfo = @{
    AssemblyVersion = $assemblyVersion
    FileVersion = $fileVersion
    InformationalVersion = $informationalVersion
    VersionPrefix = $VersionPrefix
    VersionSuffix = $VersionSuffix
    BuildNumber = $buildNumber
    GitCommitHash = $gitCommitHash
    GitBranch = $gitBranch
    BuildTimestamp = $buildTimestamp
    BuildConfiguration = $BuildConfiguration
}

# Save version info to JSON for other tools
$versionInfoJson = $versionInfo | ConvertTo-Json -Depth 2
$versionInfoPath = "version-info.json"
Set-Content $versionInfoPath $versionInfoJson -Encoding UTF8

Write-Host "Version information saved to $versionInfoPath" -ForegroundColor Green

# Set environment variables for MSBuild
[Environment]::SetEnvironmentVariable("AssemblyVersion", $assemblyVersion, "Process")
[Environment]::SetEnvironmentVariable("FileVersion", $fileVersion, "Process")
[Environment]::SetEnvironmentVariable("InformationalVersion", $informationalVersion, "Process")
[Environment]::SetEnvironmentVariable("VersionPrefix", $VersionPrefix, "Process")
[Environment]::SetEnvironmentVariable("VersionSuffix", $VersionSuffix, "Process")

Write-Host "Environment variables set for MSBuild" -ForegroundColor Green
Write-Host "Version Builder completed successfully!" -ForegroundColor Green

# Return version information
return $versionInfo