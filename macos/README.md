# LCT for macOS

LCT 是原生实时字幕与本地翻译应用。先完成所选音源和语音识别授权，即可使用原文字幕；不需要安装 Ollama、启动服务或配置端口。

## 使用

1. 打开 LCT，在向导中选择系统音频、麦克风或两者。系统音频模式不要求麦克风授权。
2. 选择实际说话的语言并授权语音识别。缺少 Apple 语音资源时，按应用提示准备该语言资源。
3. 点击 **start**，播放视频或说话。原文字幕、暂停/恢复、停止和导出均不依赖翻译模型。
4. 如需翻译，打开 **Settings → Local Translation** 下载模型，再开启 **Translate Captions** 并保存设置。准备期间可继续原文字幕。

翻译运行时随应用交付，使用进程内 llama.cpp；模型为 Qwen2.5-1.5B-Instruct Q4_K_M，下载约 **1.12 GB**，需要额外内存。权重保存在本机 LCT 的 Application Support 目录，下载完成并校验后才能加载。下载可取消或重试。模型和语音资源准备好后，识别与翻译可在离线状态运行。

这不是云 API，也不会把音频或字幕发给模型下载站点。下载权重需要网络；首次准备 Apple 语音资源也可能需要网络。历史记录默认关闭。

## 系统与构建

macOS 15+、Swift 6+；完整双通道识别推荐 macOS 26 和 Xcode 26。旧系统使用 SFSpeechRecognizer，双路识别能力有限。运行时包含 Apple silicon 与 Intel slice，Intel 的实机性能和兼容性须单独验证。

```bash
cd macos
./Scripts/dev-run.sh
```

`dev-run.sh` 构建、签名并启动 `.app`，使用稳定的签名身份保持权限一致。不要使用 `swift run` 或直接启动 `.build/.../LCTMac`。

```bash
./Scripts/run_tests.sh        # Debug / Release / warnings-as-errors / XCTest
./Scripts/dev-run.sh --no-launch
```

详细验收见 [TESTING.md](TESTING.md)，签名、公证与发布见 [RELEASE.md](RELEASE.md)。PR 和主线提交只构建、测试；签名公证 DMG 交付须手动触发。开发签名包不等于已公证的正式下载包。

Windows 版本保存在[归档标签](../docs/WINDOWS_ARCHIVE.md)。
