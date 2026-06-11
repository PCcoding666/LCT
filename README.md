# LiveCaptions Translator (LCT) for macOS 🎙️✨

LiveCaptions Translator (LCT) 是一款专为 macOS 设计的原生级实时语音识别与 AI 翻译桌面工具。它通过无缝结合苹果原生的 `SFSpeechRecognizer` 框架与本地化部署的 LLM（Ollama大模型），提供真正的“零延迟感知”与“隐私安全”的实时跨语言字幕与口语润色服务。

## 🌟 核心特性 (Features)

- **原生级体验**：完全使用 Swift & SwiftUI 编写，极低的内存与 CPU 占用。
- **毛玻璃悬浮窗 (Glassmorphism HUD)**：沉浸式窄边框字幕条，采用 `.ultraThinMaterial` 毛玻璃材质，与系统无缝融合。
- **渐进式交互 (Progressive Disclosure)**：悬停时优雅淡入控制栏，移开后恢复纯净阅读体验。
- **双路流式翻译管道 (Translation Pipeline)**：独创的 `CaptionSegmenter` 文本切分器，实现本地 ASR “边听边修补” 与后台 “单次提问双重输出（原句去噪改写 + 目标语言翻译）” 完美结合。
- **全面本地化支持**：直接对接本地 Ollama 服务（默认推荐模型 `qwen3.5:4b-mlx`），让你的数据不出本机，保证极致的隐私和离线可用性。
- **全自动 CI/CD 流程**：已配置完整的 GitHub Actions 工作流，代码合并自动拉起 macOS Runner 完成 `.app` 编译与压缩归档分发。

## 📁 本地代码架构 (Architecture)

我们的项目将复杂逻辑分离到高内聚的模型中：
- **`LCTMacApp.swift`**：程序入口，管理欢迎向导和主窗口样式。
- **`MainView.swift`**：核心视图，采用基于 ZStack 和 `ScrollView` 的非完全透明悬浮面板设计，包含自动滚动的流式翻译卡片。
- **`TranscriptionVM.swift`**：控制大局的 ViewModel，负责协调语音录制、断句切片、请求翻译和数据同步。
- **`Utils/CaptionSegmenter.swift`**：负责把源源不断的实时 ASR 草稿流文本（Interim Text）基于停顿和标点进行切段（Segment）定型。
- **`Models/TranslationSegment.swift`**：每一个定型的段落对应一个 `TranslationSegment` 卡片，追踪自己处于识别中、翻译中或已完成状态。
- **`Services/OllamaService.swift`**：与本地大模型交互的网络层，解析特殊的指令模板进行翻译。

## 📜 历史变更概要 (Changelog & Commits)

最近的重大架构演进与特性更新：
* `c402aca` - 优化：默认关闭 Ollama 大模型的思考过程 (`think: false`)，降低首字延迟。
* `de99eea` & `ee42dde` - CI/CD：新增并修复了基于 Swift 6.0 的 `macOS` GitHub Actions 构建和打包流程。
* `fa328de` - 特性：实现了真正的流式 Transcript Stream，由单一全量字符串重构为分段式管道 (`Segmented Translation Pipeline`)。
* `a47a5e6` - 架构：采用 Overlay-first 架构重新设计，并加入 CaptionSegment 状态机。
* `094ba7c` - 特性：彻底移除基于 Python 的桥接代码，全盘换成性能更加优越的 Swift Native 原生组件。
* `8d2fec6` - 架构：精简代码库，移除过时的 Windows 分支依赖，专注于打造 macOS 最佳体验。

## 🚀 开发者构建指南

本项目需要 **Xcode 16 / Swift 6.0** 环境：

```bash
# 进入项目目录
cd macos
# 启动 Release 编译
swift build -c release
# 运行编译后的程序
./.build/release/LCTMac
```

(注：你也可以直接利用已经配置好的 GitHub Actions 自动获取每日构建的 `LCTMac-macOS.zip` 包)
