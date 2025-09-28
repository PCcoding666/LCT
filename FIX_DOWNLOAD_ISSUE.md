# 修复 Ollama 下载 404 错误

## 问题描述

应用首次安装时出现 404 (Not Found) 错误，这是因为硬编码的 IPEX-LLM Ollama 下载链接已失效。

```
2025-09-28 20:00:02.362 +08:00 [ERR] Ollama installation check failed.
System.Net.Http.HttpRequestException: Response status code does not indicate success: 404 (Not Found).
```

## 根本原因

1. **下载链接失效**：原有的下载链接 `https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250415-win.zip` 不再存在
2. **版本过旧**：链接中的版本 `2.3.0b20250415` (2025年4月15日) 已经是较旧版本
3. **单一下载源**：只有一个下载源，没有备用方案

## 解决方案

### 已实现的修复

1. **更新下载链接**：
   - 主链接：`ollama-ipex-llm-2.3.0b20250924-win.zip`
   - 备用链接：`ollama-ipex-llm-2.3.0b20250830-win.zip`、`ollama-ipex-llm-2.3.0b20250724-win.zip`

2. **多源下载支持**：应用现在支持多个下载源，如果主链接失败会自动尝试备用链接

3. **自定义下载源**：在设置中添加了 `CustomDownloadUrl` 选项，用户可以配置自己的下载源

4. **增强错误处理**：提供更友好的错误信息和故障排除指导

### 配置自定义下载源

如果默认下载源仍然不可用，用户可以：

1. 手动编辑 `setting.json` 文件
2. 在 `OllamaConfig` 部分添加 `CustomDownloadUrl` 字段：

```json
{
  "OllamaConfig": {
    "CustomDownloadUrl": "https://your-custom-download-url/ollama-windows.zip",
    "ModelName": "qwen2.5:3b",
    "Port": 11434,
    "Host": "127.0.0.1",
    "TimeoutSeconds": 60
  }
}
```

### 如何获取最新下载链接

1. 访问 [IPEX-LLM 发布页面](https://github.com/ipex-llm/ipex-llm/releases)
2. 查找最新的 `ollama-ipex-llm-*-win.zip` 文件
3. 复制下载链接并配置到 `CustomDownloadUrl`

## 故障排除

如果仍然遇到下载问题：

1. **检查网络连接**：确保能够访问 GitHub
2. **尝试不同下载源**：配置自定义下载 URL
3. **手动下载**：从发布页面手动下载文件并放置到 `%LocalAppData%\LiveCaptionsTranslator\downloads\` 目录
4. **联系支持**：如果问题持续存在，请联系开发者获取帮助

## 技术细节

修改的文件：
- `src/utils/OllamaDownloader.cs`：支持多源下载和自定义URL
- `src/utils/ApplicationSetup.cs`：增强错误处理
- `src/models/TranslateAPIConfig.cs`：添加 CustomDownloadUrl 配置选项

下载优先级：
1. 用户自定义的 CustomDownloadUrl（如果配置）
2. 主下载链接（最新版本）
3. 备用下载链接（按时间倒序）