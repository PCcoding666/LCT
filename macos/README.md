# LCT - LiveCaptions Translator for macOS

<div align="center">

![LCT Logo](https://via.placeholder.com/150x150.png?text=LCT)

**实时语音识别与翻译工具**

[![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-brightgreen)](https://github.com/PCcoding666/LCT/releases)

[特性](#-特性) • [安装](#-安装) • [快速开始](#-快速开始) • [文档](#-文档) • [贡献](#-贡献)

</div>

---

## 🌟 特性

### 核心功能

- 🎤 **实时语音识别**
  - 使用 Apple SFSpeechRecognizer，准确率高
  - 支持 14 种语言识别
  - 自动标点和分段

- 🌍 **智能 AI 翻译**
  - 集成 Ollama 本地 AI 引擎
  - 支持 10 种目标语言翻译
  - 完全本地化处理，保护隐私

- 📊 **双窗口显示**
  - 主窗口：完整的转录历史和翻译
  - 悬浮窗口：轻量级实时字幕

- 📝 **历史记录管理**
  - SQLite 数据库存储
  - 全文搜索功能
  - CSV 格式导出

- 🎨 **高度可定制**
  - 灵活的界面设置
  - 自定义翻译提示词
  - 可调整的上下文感知

### 技术亮点

- ✨ SwiftUI 原生界面
- 🚀 Apple Silicon 优化
- 🔒 完全本地处理，保护隐私
- ⚡ 低延迟实时翻译
- 🎯 上下文感知翻译

---

## 📋 系统要求

- **macOS**: 12.0 (Monterey) 或更高版本
- **处理器**: Apple Silicon (M1/M2/M3) 或 Intel Core i5+
- **内存**: 8 GB RAM（推荐 16 GB）
- **存储**: 至少 2 GB 可用空间

---

## 📦 安装

### 方法 1: 下载安装包（推荐）

1. 从 [Releases](https://github.com/PCcoding666/LCT/releases) 页面下载最新的 `.dmg` 文件
2. 双击打开 `.dmg` 文件
3. 拖拽 LCT 到"应用程序"文件夹
4. 首次运行时按照向导完成设置

### 方法 2: 从源码编译

```bash
# 克隆仓库
git clone https://github.com/PCcoding666/LCT.git
cd LCT/macos

# 使用 Swift Package Manager 构建
swift build -c release

# 或使用 Xcode 打开项目
open Package.swift
```

### 依赖项

LCT 需要 **Ollama** 作为 AI 翻译引擎：

```bash
# 使用 Homebrew 安装
brew install ollama

# 启动 Ollama 服务
ollama serve
```

或访问 [Ollama 官网](https://ollama.ai) 下载安装包。

---

## 🚀 快速开始

### 1. 首次设置

启动 LCT 后，按照向导完成：

1. **授予权限**
   - 麦克风权限（捕获语音）
   - 屏幕录制权限（捕获系统音频）
   - 语音识别权限（使用 Apple 的语音识别）

2. **安装 Ollama**（如果尚未安装）
   - 点击"Install Ollama"一键安装

3. **下载 AI 模型**
   - 选择推荐的 `qwen2.5:3b` 模型
   - 或选择其他模型（llama3.2, gemma2 等）

### 2. 基本使用

```
1. 点击 "Start" 开始捕获音频
2. 说话或播放音频内容
3. 实时查看识别和翻译结果
4. 点击 "Stop" 停止捕获
```

### 3. 调整设置

- 按 `⌘ + ,` 打开设置
- 选择源语言（要识别的语言）
- 选择目标语言（要翻译成的语言）
- 调整其他偏好设置

---

## 📖 文档

- 📘 [完整用户指南](USER_GUIDE.md) - 详细的功能说明和使用教程
- 🚀 [快速开始指南](QUICK_START.md) - 5 分钟快速上手
- 🔧 [改进计划](IMPROVEMENT_PLAN.md) - 项目改进计划和技术细节
- 🐛 [问题报告](https://github.com/PCcoding666/LCT/issues) - 报告 Bug 或提出建议

---

## 💡 使用场景

### 在线会议翻译
实时翻译 Zoom、Teams、Google Meet 等视频会议内容
```
源语言: English → 目标语言: Chinese
✅ 启用系统音频捕获
```

### 视频字幕翻译
为 YouTube、Netflix 等视频提供实时翻译字幕
```
悬浮窗口模式 + 半透明背景
```

### 语言学习助手
练习外语时获得实时翻译反馈
```
✅ 启用麦克风捕获
保留历史记录用于复习
```

### 跨语言沟通
商务会议中的实时翻译助手
```
上下文感知翻译 + 自定义商务提示词
```

---

## ⌨️ 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘ + Space` | 开始/停止捕获 |
| `⌘ + P` | 暂停/继续 |
| `⌘ + O` | 切换悬浮窗口 |
| `⌘ + ⇧ + C` | 复制翻译 |
| `⌘ + ⇧ + H` | 查看历史记录 |
| `⌘ + ,` | 打开设置 |

---

## 🏗️ 项目结构

```
LCT/macos/
├── LCTMac/
│   ├── App/                    # 应用入口
│   │   ├── LCTMacApp.swift    # 主应用
│   │   └── AppDelegate.swift   # 应用代理
│   ├── Models/                 # 数据模型
│   │   ├── AppSettings.swift  # 设置模型
│   │   ├── Caption.swift      # 字幕模型
│   │   ├── Speaker.swift      # 说话人模型
│   │   └── ...
│   ├── Services/              # 业务服务
│   │   ├── AudioCaptureService.swift      # 音频捕获
│   │   ├── SpeechAnalyzerService.swift    # 语音识别
│   │   ├── OllamaService.swift           # AI 翻译
│   │   ├── TranslationQueue.swift        # 翻译队列
│   │   ├── HistoryService.swift          # 历史记录
│   │   └── ...
│   ├── ViewModels/            # 视图模型
│   │   └── TranscriptionVM.swift
│   ├── Views/                 # 界面视图
│   │   ├── MainView.swift     # 主窗口
│   │   ├── OverlayView.swift  # 悬浮窗口
│   │   ├── SettingsView.swift # 设置窗口
│   │   ├── HistoryView.swift  # 历史窗口
│   │   └── WelcomeView.swift  # 欢迎向导
│   └── Utils/                 # 工具类
│       └── TextUtils.swift
├── Scripts/                   # 脚本
│   └── setup.sh
├── Package.swift              # SPM 配置
└── README.md                  # 本文件
```

---

## 🛠️ 技术栈

- **语言**: Swift 5.9+
- **UI 框架**: SwiftUI
- **语音识别**: Apple SFSpeechRecognizer
- **AI 引擎**: Ollama (qwen2.5, llama3.2, gemma2)
- **音频处理**: AVFoundation, ScreenCaptureKit
- **数据库**: SQLite (SQLite.swift)
- **包管理**: Swift Package Manager

---

## 🎯 路线图

### v1.0.0 ✅ (当前版本)
- ✅ 实时语音识别
- ✅ AI 翻译
- ✅ 双窗口显示
- ✅ 历史记录管理
- ✅ 首次使用向导

### v1.1.0 (计划中)
- [ ] 说话人识别和标注
- [ ] 更多 AI 模型支持
- [ ] 翻译质量评分
- [ ] 深色模式优化

### v1.2.0 (计划中)
- [ ] 批量翻译模式
- [ ] 自动检测源语言
- [ ] 插件系统
- [ ] 更多导出格式

### v2.0.0 (未来)
- [ ] 多平台支持（iOS、iPad）
- [ ] 云同步功能
- [ ] 协作翻译
- [ ] API 接口

---

## 🤝 贡献

欢迎贡献！我们需要：

- 🐛 Bug 报告
- 💡 新功能建议
- 📝 文档改进
- 🌍 多语言翻译
- 💻 代码贡献

### 贡献步骤

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

### 开发环境设置

```bash
# 克隆仓库
git clone https://github.com/PCcoding666/LCT.git
cd LCT/macos

# 安装依赖
swift package resolve

# 运行测试
swift test

# 构建项目
swift build
```

---

## 📄 许可证

本项目使用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

---

## 🙏 致谢

特别感谢以下项目和技术：

- [Apple SFSpeech Framework](https://developer.apple.com/documentation/speech) - 语音识别
- [Ollama](https://ollama.ai) - 本地 AI 引擎
- [SQLite.swift](https://github.com/stephencelis/SQLite.swift) - SQLite 封装
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) - 屏幕捕获

---

## 📞 联系方式

- **GitHub Issues**: [提交问题](https://github.com/PCcoding666/LCT/issues)
- **GitHub Discussions**: [参与讨论](https://github.com/PCcoding666/LCT/discussions)

---

## ⭐ Star History

如果这个项目对你有帮助，请给一个 ⭐️ Star！

[![Star History Chart](https://api.star-history.com/svg?repos=PCcoding666/LCT&type=Date)](https://star-history.com/#PCcoding666/LCT&Date)

---

<div align="center">

**用 ❤️ 打造 | Made with ❤️**

[⬆ 回到顶部](#lct---livecaptions-translator-for-macos)

</div>
