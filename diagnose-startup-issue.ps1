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

# 2. 检查端口占用
Write-Host "`n2. 检查端口11434占用情况..." -ForegroundColor Yellow
$portCheck = netstat -ano | findstr ":11434"
if ($portCheck) {
    Write-Host "端口11434被占用:" -ForegroundColor Red
    Write-Host $portCheck
} else {
    Write-Host "✅ 端口11434空闲" -ForegroundColor Green
}

# 3. 检查配置文件
Write-Host "`n3. 检查配置文件..." -ForegroundColor Yellow
$configPath = "setting_new.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
    $modelName = $config.OllamaConfig.ModelName
    Write-Host "配置的模型名称: $modelName" -ForegroundColor Cyan
    
    # 检查模型大小（估算）
    if ($modelName -like "*4b*") {
        Write-Host "⚠️ 这是4B参数模型，大约需要下载3-4GB" -ForegroundColor Yellow
    } elseif ($modelName -like "*7b*") {
        Write-Host "⚠️ 这是7B参数模型，大约需要下载5-7GB" -ForegroundColor Yellow
    }
} else {
    Write-Host "❌ 配置文件不存在: $configPath" -ForegroundColor Red
}

# 4. 测试网络连接
Write-Host "`n4. 测试网络连接..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "https://ollama.ai" -TimeoutSec 5 -Method Head
    Write-Host "✅ 网络连接正常 (ollama.ai可访问)" -ForegroundColor Green
} catch {
    Write-Host "❌ 网络连接问题: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "建议: 检查网络连接或使用代理" -ForegroundColor Yellow
}

# 5. 检查Ollama安装
Write-Host "`n5. 检查Ollama安装..." -ForegroundColor Yellow
$ollamaPath = Join-Path $PWD "ollama"
if (Test-Path $ollamaPath) {
    Write-Host "✅ Ollama目录存在: $ollamaPath" -ForegroundColor Green
    
    $ollamaExe = Join-Path $ollamaPath "ollama.exe"
    if (Test-Path $ollamaExe) {
        Write-Host "✅ Ollama可执行文件存在" -ForegroundColor Green
        
        # 检查版本
        try {
            $version = & $ollamaExe --version 2>$null
            Write-Host "Ollama版本: $version" -ForegroundColor Cyan
        } catch {
            Write-Host "⚠️ 无法获取Ollama版本信息" -ForegroundColor Yellow
        }
    } else {
        Write-Host "❌ Ollama可执行文件不存在" -ForegroundColor Red
    }
} else {
    Write-Host "❌ Ollama目录不存在" -ForegroundColor Red
}

# 6. 检查模型目录
Write-Host "`n6. 检查模型目录..." -ForegroundColor Yellow
$modelPath = Join-Path $PWD "models"
if (Test-Path $modelPath) {
    Write-Host "✅ 模型目录存在: $modelPath" -ForegroundColor Green
    
    # 检查已下载的模型
    $modelFiles = Get-ChildItem $modelPath -Recurse -File | Where-Object { $_.Extension -in @('.bin', '.safetensors', '.gguf') }
    if ($modelFiles) {
        Write-Host "已下载的模型文件:" -ForegroundColor Cyan
        $modelFiles | ForEach-Object {
            $sizeMB = [math]::Round($_.Length / 1MB, 2)
            Write-Host "  - $($_.Name) ($($sizeMB)MB)" -ForegroundColor White
        }
    } else {
        Write-Host "No model files found, may need to download" -ForegroundColor Yellow
    }
} else {
    Write-Host "❌ 模型目录不存在" -ForegroundColor Red
}

# 7. 检查日志文件
Write-Host "`n7. 检查最近的日志..." -ForegroundColor Yellow
$logFiles = Get-ChildItem "logs" -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
if ($logFiles) {
    Write-Host "最近的日志文件:" -ForegroundColor Cyan
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
    Write-Host "No log files found" -ForegroundColor Yellow
}

# 8. 提供解决建议
Write-Host "`n=== 解决建议 ===" -ForegroundColor Green
Write-Host "根据上述检查结果，推荐按以下顺序尝试解决:" -ForegroundColor White
Write-Host "1. 如果有Ollama进程在运行，执行: .\clean-old-model.ps1" -ForegroundColor Cyan
Write-Host "2. 检查网络连接，确保可以访问 ollama.ai" -ForegroundColor Cyan
Write-Host "3. 尝试使用其他模型，修改 setting_new.json 中的 ModelName" -ForegroundColor Cyan
Write-Host "4. 如果网络较慢，考虑手动下载模型或使用代理" -ForegroundColor Cyan
Write-Host "5. 查看完整日志文件获取更多错误信息" -ForegroundColor Cyan

Write-Host "`n诊断完成。按任意键退出..." -ForegroundColor Gray
Read-Host