# Test Model Setting Display
# 测试模型设置显示是否正确

Write-Host "Testing model setting display..." -ForegroundColor Green

# 1. Check current configuration
if (Test-Path "setting_new.json") {
    $config = Get-Content "setting_new.json" | ConvertFrom-Json
    $modelName = $config.OllamaConfig.ModelName
    Write-Host "Current configured model: $modelName" -ForegroundColor Cyan
} else {
    Write-Host "Configuration file not found!" -ForegroundColor Red
    exit 1
}

# 2. Check if model is in recommended list
$recommendedModels = @{
    "qwen3:4b-instruct-2507-q4_K_M" = "Qwen3 4B Instruct (Default, High Performance)"
    "qwen3:4b-instruct" = "Qwen3 4B Instruct (Standard)"
    "qwen2.5:0.5b" = "Qwen2.5 0.5B (Lightest, Fastest)"
    "qwen2.5:1.5b" = "Qwen2.5 1.5B (Light, Fast)"
    "qwen2.5:3b" = "Qwen2.5 3B (Legacy, Balanced)"
    "qwen2.5:7b" = "Qwen2.5 7B (High Quality, Slower)"
    "llama3.2:1b" = "Llama 3.2 1B (Alternative Light Option)"
    "llama3.2:3b" = "Llama 3.2 3B (Alternative Balanced Option)"
}

if ($recommendedModels.ContainsKey($modelName)) {
    $description = $recommendedModels[$modelName]
    Write-Host "✅ Model is in recommended list: $description" -ForegroundColor Green
} else {
    Write-Host "⚠️ Model is not in recommended list (custom model)" -ForegroundColor Yellow
}

# 3. Check code modifications
Write-Host ""
Write-Host "Checking code modifications..." -ForegroundColor Yellow

$settingWindowFile = "src\windows\SettingWindow.xaml.cs"
if (Test-Path $settingWindowFile) {
    $content = Get-Content $settingWindowFile -Raw
    
    if ($content -match "RefreshModelSelector") {
        Write-Host "✅ RefreshModelSelector method found" -ForegroundColor Green
    } else {
        Write-Host "❌ RefreshModelSelector method not found" -ForegroundColor Red
    }
    
    if ($content -match "InitializeModelSelector.*Current model") {
        Write-Host "✅ Enhanced InitializeModelSelector found" -ForegroundColor Green
    } else {
        Write-Host "❌ Enhanced InitializeModelSelector not found" -ForegroundColor Red
    }
    
    if ($content -match "Activated.*RefreshModelSelector|RefreshModelSelector.*Activated" -or ($content -match "Activated" -and $content -match "RefreshModelSelector")) {
        Write-Host "✅ Activated event handler found" -ForegroundColor Green
    } else {
        Write-Host "❌ Activated event handler not found" -ForegroundColor Red
    }
} else {
    Write-Host "❌ SettingWindow.xaml.cs not found" -ForegroundColor Red
}

# 4. Check XAML binding
$xamlFile = "src\windows\SettingWindow.xaml"
if (Test-Path $xamlFile) {
    $xamlContent = Get-Content $xamlFile -Raw
    
    if ($xamlContent -match "Text=.*Binding OllamaConfig.ModelName") {
        Write-Host "✅ Text binding found in XAML" -ForegroundColor Green
    } else {
        Write-Host "❌ Text binding not found in XAML" -ForegroundColor Red
    }
    
    if ($xamlContent -match "SelectedValue=.*Binding OllamaConfig.ModelName") {
        Write-Host "✅ SelectedValue binding found in XAML" -ForegroundColor Green
    } else {
        Write-Host "❌ SelectedValue binding not found in XAML" -ForegroundColor Red
    }
} else {
    Write-Host "❌ SettingWindow.xaml not found" -ForegroundColor Red
}

Write-Host ""
Write-Host "Model setting display test completed!" -ForegroundColor Green
Write-Host ""
Write-Host "Expected behavior:" -ForegroundColor Cyan
Write-Host "- ComboBox should show: '$($recommendedModels[$modelName])'" -ForegroundColor White
Write-Host "- Selected value should be: '$modelName'" -ForegroundColor White
Write-Host "- Both text and selection should update correctly" -ForegroundColor White