# LCT (LiveCaptions Translator) Windows 版

完全在本机运行的实时字幕与翻译。LCT 监听电脑正在播放的声音和麦克风，用
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) 在端侧识别语音，再通过
[Ollama](https://ollama.com) 用本地模型翻译。不依赖云服务，不需要账号，也不再需要
Windows 实时字幕（Live Captions）。

**快速开始：** 从[最新 Release](https://github.com/PCcoding666/LCT/releases/latest)
下载 `LCT-vX.Y.Z-Setup.exe` 运行即可。每个 Release 还附带便携版（x64 / ARM64，
含或不含 .NET 运行时）和 SHA-256 校验文件。程序暂未代码签名，SmartScreen 可能提示，
请选择 **更多信息 ▸ 仍要运行**。

> 2.0 是同名的全新应用，取代了 1.x 的实时字幕抓取方案。变更见
> [CHANGELOG.md](CHANGELOG.md)，实现原理见 [docs/dev/ARCHITECTURE.md](docs/dev/ARCHITECTURE.md)。

## 功能

- **两路独立采集。** 系统音频（视频、通话、会议等电脑播放的一切）和麦克风，各自可设识别语言；
  在状态栏的语言标签里即可热切换，只重启受影响的通道。
- **端侧语音识别。** whisper.cpp ggml 模型（tiny → large-v3-turbo），按需下载一次。支持 14 种识别语言。
- **本地流式翻译。** Ollama 对话模型（推荐 Qwen3.5，支持 TranslateGemma），说话过程中就开始翻译草稿，
  带上下文、可编辑提示词，并根据 CPU / GPU / 内存推荐模型。
- **终端 HUD 界面。** 录制计时、`SYS ZH · MIC EN → JA` 语言标签、模型与 Ollama 状态灯、延迟、
  双通道电平表、每条字幕的 SYS/MIC 徽标和时间戳，以及真正的暂停/恢复。
- **悬浮窗、托盘、全局热键。** 置顶悬浮字幕窗（位置、尺寸、透明度、字号、点击穿透均可调）、托盘图标，
  全局热键 `Ctrl+Alt+S` 开始/停止、`Ctrl+Alt+P` 暂停、`Ctrl+Alt+O` 悬浮窗。
- **导出与历史。** 当前会话可导出 Markdown / TXT / SRT。历史默认关闭；开启后存于本机 SQLite，
  可设保留天数和最大条数，支持搜索、删除单条、清空和导出 CSV。
- **守护 Ollama。** LCT 优先使用你已安装的 Ollama，绝不杀掉你自己启动的进程；只在没有服务响应时
  启动 `ollama serve`，运行中服务挂掉会退避重启（最多 3 次），模型被卸载会自动重载，所有请求都带
  `num_ctx`，让 4B 模型稳定在 3 GB 左右。

## 系统要求

| | |
|---|---|
| **Windows** | Windows 10 1809 及以上，或 Windows 11（x64 / ARM64） |
| **翻译** | [Ollama for Windows](https://ollama.com/download/windows)，或可通过 HTTPS 访问的远程 Ollama |
| **内存** | 至少 8 GB；运行 4B 翻译模型建议 16 GB 或 6 GB+ 显存的 GPU |
| **磁盘** | 翻译模型 2–4 GB，语音模型 150–500 MB |
| **网络** | 仅首次运行下载模型时需要 |

## 首次运行

向导会引导完成全部配置：

1. **音频与语言** — 开关系统音频 / 麦克风，选择麦克风设备、说话语言和目标语言。
2. **Ollama** — 先探测正在运行的服务，再查找已安装的 `ollama.exe`。都没有时提供官网下载、
   远程服务器（仅 HTTPS、需显式开启），以及 Intel GPU 机器可选的 IPEX-LLM 便携版。
3. **翻译模型** — 下载按硬件推荐的模型（带进度、取消和磁盘空间检查），也可改选其它模型。
4. **语音模型** — 下载 whisper 模型（默认 `small`，低配机器为 `base`）。

然后点 **start**（或 `Ctrl+Alt+S`），播放任意音频即可。

## 设置

所有设置都在 **⚙ Settings** 中，并保存于 `%LOCALAPPDATA%\LCT\settings.json`：

- 音频采集：通道开关、麦克风设备。
- 语言：系统音频语言、麦克风语言（或"与系统音频相同"）、目标语言。
- 语音识别：whisper 模型（各模型大小与下载）。
- 翻译模型：已安装模型、推荐、应用内下载、常驻时长（5 分钟 … 直到退出）、退出时卸载。
- Ollama 连接：主机、端口、远程开关（仅 HTTPS）、超时、`num_ctx`。
- 翻译调优：模型类型、温度、草稿实时翻译、上下文感知及条数、自定义提示词
  （`{TARGET_LANGUAGE}` 占位、重置、预览）。
- 显示与悬浮窗：延迟显示、最大卡片数、悬浮窗透明度 / 字号 / 置顶 / 点击穿透。
- 历史：开关、保留天数、最大条数。
- 快捷键与托盘：全局热键、关闭窗口后留在托盘。
- 诊断：导出仅含设置与状态的报告（不含任何转录内容），打开日志目录。

日志位于 `%LOCALAPPDATA%\LCT\logs\`；语音模型位于 `%LOCALAPPDATA%\LCT\models\whisper\`，
翻译模型由 Ollama 自行管理。

## 常见问题

- **提示"有声音但识别不到内容"** — 该通道的识别语言很可能与实际语言不符，点状态栏的语言标签更换。
- **麦克风完全静音** — 检查设置里选择的设备，以及 Windows ▸ 隐私 ▸ 麦克风（需允许桌面应用）。
- **Ollama 状态灯为红色** — 点击它即可启动 Ollama；未安装时提示会给出下载页面。
- **模型未安装** — 提示里可直接下载，或执行 `ollama pull qwen3.5:4b`。
- **纯 CPU 翻译太慢** — 在设置里改用 `qwen3.5:2b` / `qwen3.5:0.8b`，或把语音模型换成 `base`。

## 构建

```bash
cd windows
dotnet test Tests/LCT.Tests/LCT.Tests.csproj
dotnet build LiveCaptionsTranslator.csproj
```

`LCT.Core`（不含 WPF 的全部逻辑）及其测试可在任意系统构建；WPF 应用在 Windows 上构建，
其它系统加 `-p:EnableWindowsTargeting=true`。发布由 `.github/workflows/windows-build.yml`
完成，见 [docs/dev/RELEASE.md](docs/dev/RELEASE.md)。

## 隐私

音频不会离开本机。语音识别在进程内完成；翻译只发送到你配置的 Ollama 端点（默认本机；
远程需显式开启且仅 HTTPS）。历史默认关闭；诊断导出只包含设置与状态。

## 许可

见 [LICENSE](../LICENSE)。由 Ai-All-You-Need-Platform Pte. Ltd. 开发。
