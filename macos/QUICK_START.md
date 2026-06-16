# LCT macOS 快速开始指南

**5 分钟快速上手 LiveCaptions Translator**

---

## 📦 安装（只需 3 步）

### 1️⃣ 下载 LCT
从 [Releases](https://github.com/your-repo/LCT/releases) 下载最新的 `.dmg` 文件

### 2️⃣ 安装应用
- 双击 `.dmg` 文件
- 拖拽 LCT 到"应用程序"文件夹
- 从启动台打开 LCT

### 3️⃣ 首次设置
应用会自动引导你完成：
- ✅ 授予必要权限（麦克风、屏幕录制、语音识别）
- ✅ 安装 Ollama（AI 翻译引擎）
- ✅ 下载默认 AI 模型（qwen3.5:4b-mlx，约 2.5GB）

💡 **提示**：整个过程需要 5-10 分钟，取决于网络速度

---

## 🚀 基本使用

### 开始翻译
1. 点击左上角的 **"Start"** 按钮（或按 `⌘ + Space`）
2. 开始播放音频或说话
3. 字幕和翻译会实时显示

### 停止翻译
- 再次点击 **"Stop"** 按钮（或按 `⌘ + Space`）

### 查看悬浮窗口
- 悬浮窗口会自动显示在屏幕上方
- 可以拖动到任意位置
- 按 `⌘ + O` 可以切换显示/隐藏

### 复制翻译
- 点击翻译文本旁的复制按钮
- 或按 `⌘ + ⇧ + C`

---

## ⚙️ 常用设置

### 打开设置
- 点击主窗口的 **"设置"** 按钮
- 或按 `⌘ + ,`

### 必改设置

#### 1. 选择识别语言
```
设置 > Speech Recognition > Source Language
```
选择你要识别的语音语言（如"中文"识别中文讲话）

#### 2. 选择翻译语言
```
设置 > Translation > Target Language
```
选择要翻译成的语言（如"English"翻译成英文）

#### 3. 调整悬浮窗口
```
设置 > Display > Overlay Opacity
```
调整悬浮窗口的透明度（0.7-0.9 比较合适）

---

## 🎯 使用场景

### 场景 1：翻译在线会议
1. **设置**：
   - ✅ 启用"Capture System Audio"（捕获会议音频）
   - ✅ 源语言设为会议使用的语言
   - ✅ 目标语言设为你想翻译成的语言

2. **使用**：
   - 进入会议前点击"Start"
   - 悬浮窗口会显示实时翻译
   - 可以把悬浮窗口放在会议窗口旁边

### 场景 2：翻译视频内容
1. **设置**：
   - ✅ 启用"Capture System Audio"
   - ✅ 选择视频的语言作为源语言

2. **使用**：
   - 播放视频前点击"Start"
   - 字幕会自动出现

### 场景 3：翻译自己的讲话
1. **设置**：
   - ✅ 启用"Capture Microphone"
   - ✅ 禁用"Capture System Audio"（避免干扰）
   - ✅ 源语言设为你说话的语言

2. **使用**：
   - 点击"Start"后开始说话
   - 可以用于练习外语或准备演讲

---

## 🔑 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘ + Space` | 开始/停止 |
| `⌘ + P` | 暂停/继续 |
| `⌘ + O` | 显示/隐藏悬浮窗口 |
| `⌘ + ⇧ + C` | 复制翻译 |
| `⌘ + ⇧ + H` | 查看历史记录 |
| `⌘ + ,` | 打开设置 |

---

## ❓ 常见问题

### Q: 为什么没有声音被识别？
**A**: 检查：
- ✅ 是否点击了"Start"按钮
- ✅ 音频电平指示器是否有波动
- ✅ 是否选择了正确的源语言
- ✅ 是否授予了相应权限

### Q: 识别了但没有翻译？
**A**: 检查：
- ✅ Ollama 是否在运行：打开终端运行 `ollama serve`
- ✅ AI 模型是否已下载：运行 `ollama list`
- ✅ 查看主窗口是否有错误提示

### Q: 翻译速度太慢？
**A**: 优化：
- 使用更小的模型（如 `gemma2:2b`）
- 在设置中降低"Max Context Entries"
- 降低 Temperature 到 0.2

### Q: 悬浮窗口不见了？
**A**: 按 `⌘ + O` 重新显示

---

## 🎨 推荐设置

### 日常会议翻译
```
✅ Capture System Audio: ON
❌ Capture Microphone: OFF
📝 Source Language: English (US)
🌍 Target Language: Chinese
🎯 Context-Aware: ON
⚡ Temperature: 0.3
```

### 视频字幕翻译
```
✅ Capture System Audio: ON
❌ Capture Microphone: OFF
📺 Overlay Window: ON
🔍 Show Latency: OFF（避免干扰）
```

### 语言学习助手
```
✅ Capture Microphone: ON
✅ Capture System Audio: ON
📚 Max Context Entries: 7
💾 保留历史记录用于复习
```

---

## 🔧 故障排除

### 重启 Ollama
```bash
# 停止
killall ollama

# 启动
ollama serve
```

### 重新授予权限
1. 系统设置 > 隐私与安全性
2. 点击"麦克风"或"屏幕录制"
3. 取消勾选 LCT，再重新勾选
4. 重启 LCT

### 清除缓存
```bash
# 清除历史记录
rm ~/Library/Application\ Support/LCT/history.sqlite

# 重启应用
```

---

## 📚 进一步学习

- 📖 [完整用户文档](USER_GUIDE.md)
- 🔧 [技术改进计划](IMPROVEMENT_PLAN.md)
- 🐛 [报告问题](https://github.com/your-repo/LCT/issues)

---

**祝你使用愉快！🎉**

有任何问题，欢迎在 GitHub 上提 Issue！
