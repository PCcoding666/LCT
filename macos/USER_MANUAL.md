# LCT 使用说明 / User Manual

中文完整说明：[用户指南](../docs/USER_GUIDE.md)。

## English quick start

1. Open LCT and choose **Set Up Captions**.
2. Select system audio, microphone, or both, and the spoken language. Grant speech recognition and the selected source permissions. System-only captions do not require microphone access.
3. Choose **Open Captions**, then **start**. Some languages need an Apple speech resource download first.
4. For optional translation, open **Settings → Local Translation**, download the 1.12 GB model, enable **Translate Captions**, and choose **Done**.

Captions work without a translation model or a separate service. Download and translation failures do not stop original captions. Once the speech resources and translation model are ready, processing takes place locally.

Use ⌘Space to start/stop, ⌘P to pause/resume, ⌘O for the overlay, and the export menu for Markdown, Text, or SRT. History is off by default and can be enabled in **Advanced → History**.

Requires macOS 15 or later. Language availability depends on the OS and installed speech resources. The bundled runtime uses Metal on Apple silicon and CPU on Intel; performance varies by device. For development and release status, see [README](README.md). Report problems at [GitHub Issues](https://github.com/PCcoding666/LCT/issues).
