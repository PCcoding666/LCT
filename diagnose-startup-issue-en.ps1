# Ollama Startup Issue Diagnostic Script
# Diagnose model download and startup issues

Write-Host "=== Ollama Startup Issue Diagnostic Tool ===" -ForegroundColor Green
Write-Host "Current time: $(Get-Date)" -ForegroundColor Gray

# 1. Check Ollama process status
Write-Host "`n1. Checking Ollama process status..." -ForegroundColor Yellow
$ollamaProcesses = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
if ($ollamaProcesses) {
    Write-Host "Found running Ollama processes:" -ForegroundColor Red
    $ollamaProcesses | Format-Table Id, ProcessName, StartTime, WorkingSet -AutoSize
    Write-Host "Suggestion: Stop these processes first, then restart the application" -ForegroundColor Yellow
} else {
    Write-Host "✅ No running Ollama processes" -ForegroundColor Green
}

# 2. Check port 11434 usage
Write-Host "`n2. Checking port 11434 usage..." -ForegroundColor Yellow
$portCheck = netstat -ano | findstr ":11434"
if ($portCheck) {
    Write-Host "Port 11434 is in use:" -ForegroundColor Red
    Write-Host $portCheck
} else {
    Write-Host "✅ Port 11434 is free" -ForegroundColor Green
}

# 3. Check configuration file
Write-Host "`n3. Checking configuration file..." -ForegroundColor Yellow
$configPath = "setting_new.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
    $modelName = $config.OllamaConfig.ModelName
    Write-Host "Configured model name: $modelName" -ForegroundColor Cyan
    
    # Check model size (estimated)
    if ($modelName -like "*4b*") {
        Write-Host "⚠️ This is a 4B parameter model, approximately 3-4GB download required" -ForegroundColor Yellow
    } elseif ($modelName -like "*7b*") {
        Write-Host "⚠️ This is a 7B parameter model, approximately 5-7GB download required" -ForegroundColor Yellow
    }
} else {
    Write-Host "❌ Configuration file not found: $configPath" -ForegroundColor Red
}

# 4. Test network connectivity
Write-Host "`n4. Testing network connectivity..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "https://ollama.ai" -TimeoutSec 5 -Method Head
    Write-Host "✅ Network connection OK (ollama.ai accessible)" -ForegroundColor Green
} catch {
    Write-Host "❌ Network connection issue: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Suggestion: Check network connection or use proxy" -ForegroundColor Yellow
}

# 5. Check Ollama installation
Write-Host "`n5. Checking Ollama installation..." -ForegroundColor Yellow
$ollamaPath = Join-Path $PWD "ollama"
if (Test-Path $ollamaPath) {
    Write-Host "✅ Ollama directory exists: $ollamaPath" -ForegroundColor Green
    
    $ollamaExe = Join-Path $ollamaPath "ollama.exe"
    if (Test-Path $ollamaExe) {
        Write-Host "✅ Ollama executable exists" -ForegroundColor Green
        
        # Check version
        try {
            $version = & $ollamaExe --version 2>$null
            Write-Host "Ollama version: $version" -ForegroundColor Cyan
        } catch {
            Write-Host "⚠️ Cannot get Ollama version info" -ForegroundColor Yellow
        }
    } else {
        Write-Host "❌ Ollama executable not found" -ForegroundColor Red
    }
} else {
    Write-Host "❌ Ollama directory not found" -ForegroundColor Red
}

# 6. Check model directory
Write-Host "`n6. Checking model directory..." -ForegroundColor Yellow
$modelPath = Join-Path $PWD "models"
if (Test-Path $modelPath) {
    Write-Host "✅ Model directory exists: $modelPath" -ForegroundColor Green
    
    # Check downloaded models
    $modelFiles = Get-ChildItem $modelPath -Recurse -File | Where-Object { $_.Extension -in @('.bin', '.safetensors', '.gguf') }
    if ($modelFiles) {
        Write-Host "Downloaded model files:" -ForegroundColor Cyan
        $modelFiles | ForEach-Object {
            $sizeMB = [math]::Round($_.Length / 1MB, 2)
            Write-Host "  - $($_.Name) ($($sizeMB)MB)" -ForegroundColor White
        }
    } else {
        Write-Host "⚠️ No model files found, may need to download" -ForegroundColor Yellow
    }
} else {
    Write-Host "❌ Model directory not found" -ForegroundColor Red
}

# 7. Check recent logs
Write-Host "`n7. Checking recent logs..." -ForegroundColor Yellow
$logFiles = Get-ChildItem "logs" -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
if ($logFiles) {
    Write-Host "Recent log files:" -ForegroundColor Cyan
    foreach ($log in $logFiles) {
        Write-Host "  - $($log.Name) (Last modified: $($log.LastWriteTime))" -ForegroundColor White
        
        # Check for error information
        $errorLines = Get-Content $log.FullName | Select-String -Pattern "ERROR|FATAL|Exception" | Select-Object -Last 3
        if ($errorLines) {
            Write-Host "    Recent errors:" -ForegroundColor Red
            $errorLines | ForEach-Object { Write-Host "      $($_.Line)" -ForegroundColor Red }
        }
    }
} else {
    Write-Host "⚠️ No log files found" -ForegroundColor Yellow
}

# 8. Provide solution suggestions
Write-Host "`n=== Solution Suggestions ===" -ForegroundColor Green
Write-Host "Based on the check results above, try the following in order:" -ForegroundColor White
Write-Host "1. If Ollama processes are running, execute: .\clean-old-model.ps1" -ForegroundColor Cyan
Write-Host "2. Check network connection, ensure ollama.ai is accessible" -ForegroundColor Cyan
Write-Host "3. Try using a different model, modify ModelName in setting_new.json" -ForegroundColor Cyan
Write-Host "4. If network is slow, consider manual model download or use proxy" -ForegroundColor Cyan
Write-Host "5. Check complete log files for more error details" -ForegroundColor Cyan

Write-Host "`nDiagnostic complete. Press any key to exit..." -ForegroundColor Gray
Read-Host