# Complete Fix Script for LiveCaptions-Translator Startup Issues
# This script will fix the Ollama installation and startup problems

Write-Host "=== LiveCaptions-Translator Complete Fix Tool ===" -ForegroundColor Green
Write-Host "This script will fix Ollama installation and startup issues" -ForegroundColor Yellow

# Step 1: Clean up existing processes and caches
Write-Host "`nStep 1: Cleaning up existing processes and caches..." -ForegroundColor Cyan

# Stop all Ollama processes
$ollamaProcesses = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
if ($ollamaProcesses) {
    Write-Host "Stopping $($ollamaProcesses.Count) Ollama processes..." -ForegroundColor Yellow
    $ollamaProcesses | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-Host "✅ Ollama processes stopped" -ForegroundColor Green
} else {
    Write-Host "✅ No Ollama processes running" -ForegroundColor Green
}

# Clear port 11434
$portInfo = netstat -ano | findstr ":11434"
if ($portInfo) {
    Write-Host "Clearing port 11434..." -ForegroundColor Yellow
    $portInfo -split "`n" | ForEach-Object {
        if ($_ -match '\s+(\d+)$') {
            $pid = $matches[1]
            if ($pid -ne "0") {
                try {
                    Stop-Process -Id $pid -Force -ErrorAction Stop
                    Write-Host "Stopped process PID: $pid" -ForegroundColor Green
                } catch {
                    Write-Host "Could not stop process PID: $pid" -ForegroundColor Red
                }
            }
        }
    }
}

# Step 2: Clean application data directories
Write-Host "`nStep 2: Cleaning application data directories..." -ForegroundColor Cyan

$appDataPath = "$env:LOCALAPPDATA\LiveCaptionsTranslator"
$ollamaPath = "$appDataPath\ollama"
$modelsPath = "$appDataPath\models"
$downloadsPath = "$appDataPath\downloads"

Write-Host "Application data path: $appDataPath" -ForegroundColor Gray

if (Test-Path $appDataPath) {
    Write-Host "Found existing application data directory" -ForegroundColor Yellow
    
    $choice = Read-Host "Do you want to completely reset the application data? This will re-download everything (y/N)"
    if ($choice -eq "y" -or $choice -eq "Y") {
        try {
            Remove-Item $appDataPath -Recurse -Force
            Write-Host "✅ Application data directory cleaned" -ForegroundColor Green
        } catch {
            Write-Host "❌ Failed to clean application data: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        # Selective cleanup
        if (Test-Path $ollamaPath) {
            try {
                Remove-Item $ollamaPath -Recurse -Force
                Write-Host "✅ Ollama directory cleaned" -ForegroundColor Green
            } catch {
                Write-Host "⚠️ Could not clean Ollama directory: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        if (Test-Path $downloadsPath) {
            try {
                Remove-Item $downloadsPath -Recurse -Force
                Write-Host "✅ Downloads directory cleaned" -ForegroundColor Green
            } catch {
                Write-Host "⚠️ Could not clean downloads directory: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}

# Step 3: Switch to smaller model for faster startup
Write-Host "`nStep 3: Optimizing model configuration for faster startup..." -ForegroundColor Cyan

$configPath = "setting_new.json"
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath | ConvertFrom-Json
        $currentModel = $config.OllamaConfig.ModelName
        Write-Host "Current model: $currentModel" -ForegroundColor Gray
        
        # Recommend smaller models
        $smallerModels = @(
            @{Name="qwen2.5:1.5b"; Size="1.6GB"; Description="Qwen2.5 1.5B - Fast and efficient"},
            @{Name="llama3.2:1b"; Size="1.3GB"; Description="Llama 3.2 1B - Smallest option"},
            @{Name="qwen2.5:3b"; Size="2.2GB"; Description="Qwen2.5 3B - Good balance"},
            @{Name="llama3.2:3b"; Size="2.3GB"; Description="Llama 3.2 3B - Reliable choice"}
        )
        
        Write-Host "`nAvailable smaller models for faster download:" -ForegroundColor Green
        for ($i = 0; $i -lt $smallerModels.Count; $i++) {
            $model = $smallerModels[$i]
            Write-Host "  $($i+1). $($model.Name) ($($model.Size)) - $($model.Description)" -ForegroundColor White
        }
        Write-Host "  5. Keep current model: $currentModel" -ForegroundColor White
        
        $choice = Read-Host "`nSelect a model (1-5)"
        
        if ($choice -match '^[1-4]$') {
            $selectedModel = $smallerModels[$choice - 1]
            
            # Backup original config
            $backupPath = "${configPath}.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $configPath $backupPath
            Write-Host "Config backup saved: $backupPath" -ForegroundColor Gray
            
            # Update config
            $config.OllamaConfig.ModelName = $selectedModel.Name
            $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
            
            Write-Host "✅ Model changed to: $($selectedModel.Name)" -ForegroundColor Green
            Write-Host "   Expected download size: $($selectedModel.Size)" -ForegroundColor Cyan
        } else {
            Write-Host "Keeping current model: $currentModel" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "❌ Failed to modify config: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "❌ Configuration file not found: $configPath" -ForegroundColor Red
}

# Step 4: Test network connectivity
Write-Host "`nStep 4: Testing network connectivity..." -ForegroundColor Cyan

$testUrls = @(
    "https://ollama.ai",
    "https://github.com/ipex-llm/ipex-llm/releases",
    "https://github.com/ollama/ollama/releases"
)

$networkOk = $true
foreach ($url in $testUrls) {
    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 5 -Method Head
        Write-Host "✅ $url - Connection OK" -ForegroundColor Green
    } catch {
        Write-Host "❌ $url - Connection failed: $($_.Exception.Message)" -ForegroundColor Red
        $networkOk = $false
    }
}

if (-not $networkOk) {
    Write-Host "`n⚠️ Network connectivity issues detected" -ForegroundColor Yellow
    Write-Host "Please check your internet connection or firewall settings" -ForegroundColor Yellow
}

# Step 5: Run the application with enhanced logging
Write-Host "`nStep 5: Preparing to start the application..." -ForegroundColor Cyan

Write-Host "`nFix process completed!" -ForegroundColor Green
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "1. Start LiveCaptions-Translator application" -ForegroundColor Cyan
Write-Host "2. The application will auto-download and install Ollama" -ForegroundColor Cyan
Write-Host "3. Model download will begin automatically" -ForegroundColor Cyan
Write-Host "4. Monitor progress in the splash screen" -ForegroundColor Cyan

Write-Host "`nIf issues persist:" -ForegroundColor Yellow
Write-Host "- Run: .\diagnose-startup-issue-en.ps1" -ForegroundColor Cyan
Write-Host "- Check logs in: $env:LOCALAPPDATA\LiveCaptionsTranslator\logs" -ForegroundColor Cyan
Write-Host "- Consider using a VPN if download fails" -ForegroundColor Cyan

$startChoice = Read-Host "`nWould you like to start the application now? (y/N)"
if ($startChoice -eq "y" -or $startChoice -eq "Y") {
    Write-Host "Starting LiveCaptions-Translator..." -ForegroundColor Green
    
    # Check if exe exists in the project directory
    $exeFiles = Get-ChildItem "*.exe" -ErrorAction SilentlyContinue
    if ($exeFiles) {
        $exeFile = $exeFiles[0]
        Write-Host "Found executable: $($exeFile.Name)" -ForegroundColor Cyan
        Start-Process $exeFile.FullName
    } else {
        Write-Host "No executable found in current directory." -ForegroundColor Yellow
        Write-Host "Please manually start the application." -ForegroundColor Yellow
    }
}

Write-Host "`nScript completed. Good luck!" -ForegroundColor Green