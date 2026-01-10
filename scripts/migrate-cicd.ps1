# CI/CD Migration Script
# This script helps migrate from old workflows to new optimized CI/CD pipeline

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("backup", "activate", "test", "rollback", "cleanup")]
    [string]$Action = "backup",
    
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Colors
function Write-Info { param([string]$msg) Write-Host $msg -ForegroundColor Cyan }
function Write-Success { param([string]$msg) Write-Host $msg -ForegroundColor Green }
function Write-Warning { param([string]$msg) Write-Host $msg -ForegroundColor Yellow }
function Write-Error { param([string]$msg) Write-Host $msg -ForegroundColor Red }

Write-Host ""
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "  CI/CD Migration Tool" -ForegroundColor Magenta
Write-Host "  Action: $Action" -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host ""

# Paths
$workflowDir = ".github\workflows"
$oldWorkflows = @(
    "build-and-release.yml",
    "dotnet-build.yml"
)
$newWorkflows = @(
    "ci-cd.yml",
    "pr-check.yml",
    "dependency-update.yml"
)

function Test-Prerequisites {
    Write-Info "Checking prerequisites..."
    
    # Check if in project root
    if (-not (Test-Path "LiveCaptionsTranslator.csproj")) {
        Write-Error "Please run this script from the project root directory"
        exit 1
    }
    
    # Check if git is available
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Git is not installed or not in PATH"
        exit 1
    }
    
    # Check git status
    $gitStatus = git status --porcelain
    if ($gitStatus -and -not $Force) {
        Write-Warning "You have uncommitted changes. Use -Force to proceed anyway."
        Write-Host $gitStatus
        exit 1
    }
    
    Write-Success "Prerequisites check passed"
}

function Backup-OldWorkflows {
    Write-Info "Backing up old workflows..."
    
    foreach ($workflow in $oldWorkflows) {
        $path = Join-Path $workflowDir $workflow
        $backupPath = "$path.bak"
        
        if (Test-Path $path) {
            if ($DryRun) {
                Write-Host "[DRY RUN] Would backup: $path -> $backupPath" -ForegroundColor DarkGray
            } else {
                Copy-Item $path $backupPath -Force
                Write-Success "✓ Backed up: $workflow"
            }
        } else {
            Write-Warning "Workflow not found: $workflow"
        }
    }
    
    Write-Success "Backup completed"
}

function Test-NewWorkflows {
    Write-Info "Validating new workflows..."
    
    $allExist = $true
    foreach ($workflow in $newWorkflows) {
        $path = Join-Path $workflowDir $workflow
        
        if (Test-Path $path) {
            Write-Success "✓ Found: $workflow"
            
            # Basic YAML validation
            $content = Get-Content $path -Raw
            if ($content -match "name:" -and $content -match "on:") {
                Write-Host "  Valid YAML structure" -ForegroundColor DarkGray
            } else {
                Write-Error "  Invalid YAML structure"
                $allExist = $false
            }
        } else {
            Write-Error "✗ Missing: $workflow"
            $allExist = $false
        }
    }
    
    if ($allExist) {
        Write-Success "All new workflows validated"
    } else {
        Write-Error "Some workflows are missing or invalid"
        exit 1
    }
}

function Activate-NewWorkflows {
    Write-Info "Activating new workflows..."
    
    # Disable old workflows
    foreach ($workflow in $oldWorkflows) {
        $path = Join-Path $workflowDir $workflow
        $disabledPath = "$path.disabled"
        
        if (Test-Path $path) {
            if ($DryRun) {
                Write-Host "[DRY RUN] Would disable: $path" -ForegroundColor DarkGray
            } else {
                Rename-Item $path $disabledPath -Force
                Write-Success "✓ Disabled: $workflow"
            }
        }
    }
    
    # Commit changes
    if (-not $DryRun) {
        Write-Info "Committing changes..."
        git add "$workflowDir/*"
        $commitMsg = @"
feat: Migrate to optimized CI/CD pipeline

- Replace dual workflows with unified ci-cd.yml
- Add fast PR validation workflow
- Add automated dependency update checks
- Improve build speed with caching and parallelization
- Fix NSIS installation reliability
- Add automated release creation
"@
        git commit -m $commitMsg
        
        Write-Success "Changes committed"
        
        Write-Host ""
        Write-Warning "Next steps:"
        Write-Host "1. Review the commit with: git show HEAD" -ForegroundColor White
        Write-Host "2. Push to test branch: git checkout -b ci-cd-test && git push origin ci-cd-test" -ForegroundColor White
        Write-Host "3. Create PR to validate new workflows" -ForegroundColor White
        Write-Host "4. After validation, merge to main" -ForegroundColor White
    }
    
    Write-Success "Activation completed"
}

function Test-WorkflowTrigger {
    Write-Info "Testing workflow trigger..."
    
    Write-Host ""
    Write-Host "To test the new workflows:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Create a test branch:" -ForegroundColor White
    Write-Host "   git checkout -b test-cicd" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "2. Push to trigger workflows:" -ForegroundColor White
    Write-Host "   git push origin test-cicd" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "3. Monitor at:" -ForegroundColor White
    Write-Host "   https://github.com/$(git config --get remote.origin.url | ForEach-Object { $_ -replace '.*github.com[:/]', '' -replace '\.git$', '' })/actions" -ForegroundColor Blue
    Write-Host ""
    Write-Host "4. Test release creation:" -ForegroundColor White
    Write-Host "   git tag v1.0.3-test && git push origin v1.0.3-test" -ForegroundColor DarkGray
    Write-Host ""
}

function Rollback-Migration {
    Write-Info "Rolling back migration..."
    
    foreach ($workflow in $oldWorkflows) {
        $disabledPath = Join-Path $workflowDir "$workflow.disabled"
        $path = Join-Path $workflowDir $workflow
        
        if (Test-Path $disabledPath) {
            if ($DryRun) {
                Write-Host "[DRY RUN] Would restore: $disabledPath -> $path" -ForegroundColor DarkGray
            } else {
                Rename-Item $disabledPath $path -Force
                Write-Success "✓ Restored: $workflow"
            }
        }
    }
    
    if (-not $DryRun) {
        Write-Info "Committing rollback..."
        git add "$workflowDir/*"
        git commit -m "revert: Rollback CI/CD migration"
        Write-Success "Rollback completed and committed"
    }
}

function Cleanup-OldFiles {
    Write-Info "Cleaning up old files..."
    
    $filesToRemove = @()
    
    # Old workflow backups
    foreach ($workflow in $oldWorkflows) {
        $backupPath = Join-Path $workflowDir "$workflow.bak"
        $disabledPath = Join-Path $workflowDir "$workflow.disabled"
        
        if (Test-Path $backupPath) { $filesToRemove += $backupPath }
        if (Test-Path $disabledPath) { $filesToRemove += $disabledPath }
    }
    
    if ($filesToRemove.Count -eq 0) {
        Write-Info "No files to clean up"
        return
    }
    
    Write-Host ""
    Write-Host "Files to be removed:" -ForegroundColor Yellow
    $filesToRemove | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
    Write-Host ""
    
    if (-not $Force -and -not $DryRun) {
        $confirm = Read-Host "Proceed with cleanup? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Warning "Cleanup cancelled"
            return
        }
    }
    
    foreach ($file in $filesToRemove) {
        if ($DryRun) {
            Write-Host "[DRY RUN] Would remove: $file" -ForegroundColor DarkGray
        } else {
            Remove-Item $file -Force
            Write-Success "✓ Removed: $(Split-Path $file -Leaf)"
        }
    }
    
    if (-not $DryRun) {
        git add "$workflowDir/*"
        git commit -m "chore: Clean up deprecated workflow files"
        Write-Success "Cleanup completed and committed"
    }
}

# Main execution
try {
    Test-Prerequisites
    
    switch ($Action) {
        "backup" {
            Backup-OldWorkflows
            Write-Host ""
            Write-Success "Backup completed. Run with -Action activate to proceed."
        }
        
        "activate" {
            Test-NewWorkflows
            Activate-NewWorkflows
        }
        
        "test" {
            Test-NewWorkflows
            Test-WorkflowTrigger
        }
        
        "rollback" {
            Rollback-Migration
        }
        
        "cleanup" {
            Cleanup-OldFiles
        }
    }
    
    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Magenta
    Write-Host "  Migration action '$Action' completed!" -ForegroundColor Magenta
    Write-Host "=================================================" -ForegroundColor Magenta
    Write-Host ""
    
} catch {
    Write-Error "Migration failed: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
