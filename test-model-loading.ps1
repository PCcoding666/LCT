# 测试模型加载逻辑修复
# 验证应用程序是否正确使用配置中的 qwen3:4b-instruct-2507-q4_K_M 模型

Write-Host "🔍 测试模型加载逻辑修复..." -ForegroundColor Green
Write-Host ""

# 1. 检查配置文件中的模型名
Write-Host "1. 检查配置文件中的模型设置..." -ForegroundColor Yellow
$configFile = "setting_new.json"
if (Test-Path $configFile) {
    $config = Get-Content $configFile | ConvertFrom-Json
    $configuredModel = $config.OllamaConfig.ModelName
    Write-Host "   配置文件中的模型名: $configuredModel" -ForegroundColor Cyan
    
    if ($configuredModel -eq "qwen3:4b-instruct-2507-q4_K_M") {
        Write-Host "   ✅ 配置文件正确设置为 qwen3:4b-instruct-2507-q4_K_M" -ForegroundColor Green
    } else {
        Write-Host "   ❌ 配置文件模型名不正确: $configuredModel" -ForegroundColor Red
        Write-Host "   预期: qwen3:4b-instruct-2507-q4_K_M" -ForegroundColor Red
    }
} else {
    Write-Host "   ❌ 找不到配置文件 $configFile" -ForegroundColor Red
    exit 1
}

Write-Host ""

# 2. 检查代码修复
Write-Host "2. 验证代码修复..." -ForegroundColor Yellow

# 检查 StartupManager.cs 是否移除了硬编码常量
$startupManager = "src\utils\StartupManager.cs"
if (Test-Path $startupManager) {
    $content = Get-Content $startupManager -Raw
    if ($content -notmatch 'private const string DEFAULT_MODEL = "qwen3:4b-instruct-2507-q4_K_M"') {
        Write-Host "   ✅ StartupManager.cs 已移除硬编码模型常量" -ForegroundColor Green
    } else {
        Write-Host "   ❌ StartupManager.cs 仍包含硬编码模型常量" -ForegroundColor Red
    }
    
    if ($content -match 'GetConfiguredModelName\(\)') {
        Write-Host "   ✅ StartupManager.cs 已使用配置获取方法" -ForegroundColor Green
    } else {
        Write-Host "   ❌ StartupManager.cs 未使用配置获取方法" -ForegroundColor Red
    }
} else {
    Write-Host "   ❌ 找不到 $startupManager" -ForegroundColor Red
}

# 检查 OllamaGuardian.cs 是否移除了硬编码常量
$ollamaGuardian = "src\utils\OllamaGuardian.cs"
if (Test-Path $ollamaGuardian) {
    $content = Get-Content $ollamaGuardian -Raw
    if ($content -notmatch 'private const string MODEL_NAME = "qwen3:4b-instruct-2507-q4_K_M"') {
        Write-Host "   ✅ OllamaGuardian.cs 已移除硬编码模型常量" -ForegroundColor Green
    } else {
        Write-Host "   ❌ OllamaGuardian.cs 仍包含硬编码模型常量" -ForegroundColor Red
    }
    
    if ($content -match 'GetConfiguredModelName\(\)') {
        Write-Host "   ✅ OllamaGuardian.cs 已使用配置获取方法" -ForegroundColor Green
    } else {
        Write-Host "   ❌ OllamaGuardian.cs 未使用配置获取方法" -ForegroundColor Red
    }
} else {
    Write-Host "   ❌ 找不到 $ollamaGuardian" -ForegroundColor Red
}

# 检查 TranslateAPI.cs 是否正确使用配置
$translateAPI = "src\utils\TranslateAPI.cs"
if (Test-Path $translateAPI) {
    $content = Get-Content $translateAPI -Raw
    if ($content -match 'model = config\.ModelName') {
        Write-Host "   ✅ TranslateAPI.cs 正确使用配置中的模型名" -ForegroundColor Green
    } else {
        Write-Host "   ❌ TranslateAPI.cs 未正确使用配置中的模型名" -ForegroundColor Red
    }
} else {
    Write-Host "   ❌ 找不到 $translateAPI" -ForegroundColor Red
}

Write-Host ""

# 3. 建议的测试步骤
Write-Host "3. 建议的测试步骤:" -ForegroundColor Yellow
Write-Host "   1. 重新启动应用程序" -ForegroundColor Cyan
Write-Host "   2. 观察启动日志，确认使用的模型名为 qwen3:4b-instruct-2507-q4_K_M" -ForegroundColor Cyan
Write-Host "   3. 检查 Ollama 服务是否下载了正确的模型" -ForegroundColor Cyan
Write-Host "   4. 进行翻译测试，确保翻译功能正常工作" -ForegroundColor Cyan

Write-Host ""

# 4. 清理旧模型的建议
Write-Host "4. 如果仍有问题，建议清理旧模型:" -ForegroundColor Yellow
Write-Host "   执行命令: .\clean-old-model.ps1" -ForegroundColor Cyan
Write-Host "   然后重新启动应用以触发正确的模型下载" -ForegroundColor Cyan

Write-Host ""
Write-Host "Model loading logic repair verification completed!" -ForegroundColor Green