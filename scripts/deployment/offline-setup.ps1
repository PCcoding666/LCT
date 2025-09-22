# 将此文件添加到 /scripts/deployment/offline-setup.ps1
param (
    [string]$OfflineResourcesPath = ".\offline-resources"
)

$ErrorActionPreference = "Stop"
Write-Host "Dell LiveCaptions Translator (Local Edition) 离线资源配置" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan

# 检查离线资源目录是否存在
if (!(Test-Path $OfflineResourcesPath)) {
    Write-Host "错误：离线资源目录不存在: $OfflineResourcesPath" -ForegroundColor Red
    Exit 1
}

# 获取应用数据目录路径 - Dell Local Edition
$appDataPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, "Dell LiveCaptions Translator")
$ollamaPath = [System.IO.Path]::Combine($appDataPath, "ollama")
$modelPath = [System.IO.Path]::Combine($appDataPath, "models")

# 创建必要的目录
Write-Host "创建应用目录结构..." -ForegroundColor Green
if (!(Test-Path $appDataPath)) { New-Item -ItemType Directory -Path $appDataPath -Force | Out-Null }
if (!(Test-Path $ollamaPath)) { New-Item -ItemType Directory -Path $ollamaPath -Force | Out-Null }
if (!(Test-Path $modelPath)) { New-Item -ItemType Directory -Path $modelPath -Force | Out-Null }

# 复制Ollama可执行文件
$ollamaSourcePath = [System.IO.Path]::Combine($OfflineResourcesPath, "ollama")
if (Test-Path $ollamaSourcePath) {
    Write-Host "复制Ollama可执行文件..." -ForegroundColor Green
    Copy-Item -Path "$ollamaSourcePath\*" -Destination $ollamaPath -Force -Recurse
    
    # 写入版本记录文件
    Set-Content -Path ([System.IO.Path]::Combine($ollamaPath, ".version")) -Value "ollama-ipex-llm-2.3.0b20250415-win" -Force
}

# 复制预下载的模型文件
$modelSourcePath = [System.IO.Path]::Combine($OfflineResourcesPath, "models")
if (Test-Path $modelSourcePath) {
    Write-Host "复制预下载的模型文件..." -ForegroundColor Green
    Copy-Item -Path "$modelSourcePath\*" -Destination $modelPath -Force -Recurse
}

Write-Host "离线资源配置完成！" -ForegroundColor Green 