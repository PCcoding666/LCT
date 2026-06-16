# 快速修复Ollama启动问题
# 这个脚本会尝试多种方法解决启动问题

Write-Host "=== LiveCaptions-Translator 启动修复工具 ===" -ForegroundColor Green
Write-Host "正在尝试修复Ollama启动问题..." -ForegroundColor Yellow

# 函数：停止所有Ollama进程
function Stop-OllamaProcesses {
    Write-Host "`n步骤1: 停止现有Ollama进程..." -ForegroundColor Yellow
    
    $processes = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
    if ($processes) {
        Write-Host "发现 $($processes.Count) 个Ollama进程，正在停止..." -ForegroundColor Cyan
        $processes | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force
                Write-Host "已停止进程 PID: $($_.Id)" -ForegroundColor Green
            } catch {
                Write-Host "停止进程 PID: $($_.Id) 失败: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Host "✅ 没有运行中的Ollama进程" -ForegroundColor Green
    }
}

# 函数：清理端口占用
function Clear-Port11434 {
    Write-Host "`n步骤2: 清理端口11434占用..." -ForegroundColor Yellow
    
    $portInfo = netstat -ano | findstr ":11434"
    if ($portInfo) {
        Write-Host "端口11434被占用，尝试释放..." -ForegroundColor Cyan
        
        # 提取PID并终止进程
        $portInfo -split "`n" | ForEach-Object {
            if ($_ -match '\s+(\d+)$') {
                $pid = $matches[1]
                if ($pid -ne "0") {
                    try {
                        Stop-Process -Id $pid -Force -ErrorAction Stop
                        Write-Host "已停止占用端口的进程 PID: $pid" -ForegroundColor Green
                    } catch {
                        Write-Host "无法停止进程 PID: $pid - $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }
        Start-Sleep -Seconds 1
    } else {
        Write-Host "✅ 端口11434空闲" -ForegroundColor Green
    }
}

# 函数：修改配置为更小的模型
function Switch-ToSmallerModel {
    param([string]$ConfigPath = "setting_new.json")
    
    Write-Host "`n步骤3: 检查和优化模型配置..." -ForegroundColor Yellow
    
    if (Test-Path $ConfigPath) {
        try {
            $config = Get-Content $ConfigPath | ConvertFrom-Json
            $currentModel = $config.OllamaConfig.ModelName
            Write-Host "当前配置的模型: $currentModel" -ForegroundColor Cyan
            
            # 推荐更小的模型列表（按文件大小排序）
            $alternativeModels = @(
                @{Name="llama3.2:1b"; Size="1.3GB"; Description="Meta Llama 3.2 1B - 最小模型，快速下载"},
                @{Name="qwen2.5:1.5b"; Size="1.6GB"; Description="Qwen2.5 1.5B - 轻量级，良好性能"},
                @{Name="qwen2.5:3b"; Size="2.2GB"; Description="Qwen2.5 3B - 平衡性能和大小"},
                @{Name="llama3.2:3b"; Size="2.3GB"; Description="Meta Llama 3.2 3B - 稳定可靠"}
            )
            
            Write-Host "`n推荐的替代模型（更快下载）:" -ForegroundColor Green
            for ($i = 0; $i -lt $alternativeModels.Count; $i++) {
                $model = $alternativeModels[$i]
                Write-Host "  $($i+1). $($model.Name) ($($model.Size)) - $($model.Description)" -ForegroundColor White
            }
            
            Write-Host "`n选择操作:" -ForegroundColor Yellow
            Write-Host "1-4: 切换到对应的小模型" -ForegroundColor Cyan
            Write-Host "5: 保持当前模型，尝试重新下载" -ForegroundColor Cyan
            Write-Host "6: 跳过，手动处理" -ForegroundColor Cyan
            
            $choice = Read-Host "请输入选择 (1-6)"
            
            if ($choice -match '^[1-4]$') {
                $selectedModel = $alternativeModels[$choice - 1]
                $config.OllamaConfig.ModelName = $selectedModel.Name
                
                # 备份原配置
                Copy-Item $ConfigPath "${ConfigPath}.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                
                # 保存新配置
                $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
                Write-Host "✅ 已切换到模型: $($selectedModel.Name)" -ForegroundColor Green
                Write-Host "   预计下载大小: $($selectedModel.Size)" -ForegroundColor Cyan
                return $true
            } elseif ($choice -eq "5") {
                Write-Host "保持当前模型: $currentModel" -ForegroundColor Cyan
                return $false
            } else {
                Write-Host "跳过模型配置修改" -ForegroundColor Yellow
                return $false
            }
        } catch {
            Write-Host "❌ 修改配置文件失败: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    } else {
        Write-Host "❌ 配置文件不存在: $ConfigPath" -ForegroundColor Red
        return $false
    }
}

# 函数：清理模型缓存
function Clear-ModelCache {
    Write-Host "`n步骤4: 清理模型缓存..." -ForegroundColor Yellow
    
    $modelPath = "models"
    if (Test-Path $modelPath) {
        Write-Host "发现模型目录: $modelPath" -ForegroundColor Cyan
        
        $choice = Read-Host "是否清理模型缓存？这将删除已下载的模型文件 (y/N)"
        if ($choice -eq "y" -or $choice -eq "Y") {
            try {
                Remove-Item $modelPath -Recurse -Force
                Write-Host "✅ 模型缓存已清理" -ForegroundColor Green
            } catch {
                Write-Host "❌ 清理模型缓存失败: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "跳过模型缓存清理" -ForegroundColor Yellow
        }
    } else {
        Write-Host "模型目录不存在，无需清理" -ForegroundColor Green
    }
}

# 函数：测试网络连接
function Test-NetworkConnection {
    Write-Host "`n步骤5: 测试网络连接..." -ForegroundColor Yellow
    
    $testUrls = @(
        "https://ollama.ai",
        "https://registry.ollama.ai",
        "https://github.com"
    )
    
    foreach ($url in $testUrls) {
        try {
            $response = Invoke-WebRequest -Uri $url -TimeoutSec 5 -Method Head
            Write-Host "✅ $url - 连接正常" -ForegroundColor Green
        } catch {
            Write-Host "❌ $url - 连接失败: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# 主执行流程
try {
    # 执行修复步骤
    Stop-OllamaProcesses
    Clear-Port11434
    $modelChanged = Switch-ToSmallerModel
    Clear-ModelCache
    Test-NetworkConnection
    
    Write-Host "`n=== 修复完成 ===" -ForegroundColor Green
    Write-Host "修复操作已完成。" -ForegroundColor White
    
    if ($modelChanged) {
        Write-Host "✅ 已切换到更小的模型，应该能更快下载" -ForegroundColor Green
    }
    
    Write-Host "`n下一步操作:" -ForegroundColor Yellow
    Write-Host "1. 重新启动 LiveCaptions-Translator 应用" -ForegroundColor Cyan
    Write-Host "2. 如果仍有问题，运行: .\diagnose-startup-issue.ps1" -ForegroundColor Cyan
    Write-Host "3. 查看日志文件获取详细错误信息" -ForegroundColor Cyan
    
} catch {
    Write-Host "`n❌ 修复过程中出现错误: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "建议手动检查问题或联系技术支持" -ForegroundColor Yellow
}

Write-Host "`n按任意键退出..." -ForegroundColor Gray
Read-Host