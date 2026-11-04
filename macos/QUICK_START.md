# LCT 快速开始

1. 打开 LCT，选择要听的音源。看视频选 **System audio**；只需要听自己的声音时选择 **Microphone**。
2. 选择说话的语言，完成语音识别与所选音源的授权。无需先准备翻译模型。
3. 点击 **Open Captions**，再点 **start**。播放视频或说话，原文出现在主窗口。
4. 需要翻译时，在 **Settings → Local Translation** 下载约 1.12 GB 的模型，开启 **Translate Captions** 后点 **Done**。
5. 可暂停/恢复、停止、打开悬浮窗，或从分享按钮导出原文和已有译文。

下载、加载或翻译失败不会让原文字幕失效。模型与 Apple 语音资源就绪后可离线使用。无需 Ollama、外部后台服务或 API Key。

从源码开发请使用 `cd macos && ./Scripts/dev-run.sh`。安装分发包与开发签名包的区别见 [RELEASE.md](RELEASE.md)。
