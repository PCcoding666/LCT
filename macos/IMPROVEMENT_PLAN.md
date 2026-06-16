# LCT macOS 详细改进计划

## 目标
将 macOS 版本的 LCT 打造成与 Windows 版本功能对等的实时字幕翻译应用，使用 Apple SFSpeechRecognizer 作为语音识别引擎，Ollama 作为本地翻译引擎。

---

## 一、架构对比与改进策略

### 当前架构问题

| 组件 | Windows 端 | macOS 当前实现 | 问题 |
|------|-----------|---------------|------|
| 语音识别 | Windows Live Captions (系统级) | SFSpeechRecognizer + Whisper (混合) | 方向分散，需要专注 SFSpeechRecognizer |
| 翻译服务 | Ollama (完整集成) | Ollama (基本实现) | 缺少模型管理和翻译队列 |
| 历史记录 | SQLite + DataMigration | SQLite (基本实现) | 缺少 CSV 导出 |
| UI 窗口 | Main + Overlay + Settings + Splash | Main + Overlay + Settings | 缺少启动画面 |

### 目标架构

```
┌─────────────────────────────────────────────────────────────────┐
│                          LCT macOS                               │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐ │
│  │  AudioCapture   │───>│ SFSpeechRecognizer│───>│  Caption    │ │
│  │  (System/Mic)   │    │   (语音转文字)     │    │  Model      │ │
│  └─────────────────┘    └─────────────────┘    └──────┬──────┘ │
│                                                        │         │
│  ┌─────────────────┐    ┌─────────────────┐           │         │
│  │  Translation    │<───│ TranslationQueue│<──────────┘         │
│  │  (Ollama)       │    │   (防抖/队列)     │                     │
│  └────────┬────────┘    └─────────────────┘                     │
│           │                                                      │
│           v                                                      │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐ │
│  │  History        │    │  MainView       │    │ OverlayView │ │
│  │  (SQLite)       │    │  (主窗口)        │    │ (浮动窗口)   │ │
│  └─────────────────┘    └─────────────────┘    └─────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## 二、改进计划（按优先级排序）

### 阶段一：核心功能完善 (高优先级) ✅ 已完成

#### 1.1 专注 SFSpeechRecognizer 实现 ✅
**目标**: 移除 Whisper 相关代码，专注优化 Apple 原生语音识别

**已完成**:
- [x] 移除 `WhisperBridgeService.swift`
- [x] 移除 `WhisperEngine/` Python 目录
- [x] 优化 `SpeechAnalyzerService.swift`:
  - 添加多语言支持
  - 添加语言动态切换
  - 改进部分结果处理逻辑
  - 添加识别置信度计算
  - 添加连续识别支持
- [x] 更新 `AppSettings.swift`:
  - 移除 Whisper 相关设置
  - 添加 SourceLanguage 源语言选择
  - 添加 customPrompt 自定义 Prompt 支持

**修改/新建文件**:
```
Services/SpeechAnalyzerService.swift  - 重写优化 ✅
Services/WhisperBridgeService.swift   - 已删除 ✅
Models/AppSettings.swift              - 已简化 ✅
Views/SettingsView.swift              - 已更新 UI ✅
```

#### 1.2 翻译队列系统 ✅
**目标**: 实现类似 Windows 端的 `TranslationTaskQueue`

**已完成**:
- [x] 创建 `TranslationQueue.swift`:
  - 防抖机制（避免频繁翻译）
  - 任务取消机制
  - 优先级处理
  - 失败重试（指数退避）
- [x] 更新 `TranscriptionVM.swift`:
  - 集成翻译队列
  - 改进文本同步逻辑

**新建文件**:
```
Services/TranslationQueue.swift       - 已创建 ✅
```

#### 1.3 Caption 模型完善 ✅
**目标**: 实现类似 Windows 端的 `Caption` 模型，管理原文/译文和上下文

**已完成**:
- [x] 创建 `Caption.swift` 模型:
  - 原文显示文本
  - 译文显示文本
  - 历史上下文队列
  - 上下文管理方法
- [x] 创建 `TextUtils.swift` 工具类:
  - 标点符号处理
  - CJK 字符检测
  - 句末标点添加
  - 翻译输出清理

**新建文件**:
```
Models/Caption.swift                  - 已创建 ✅
Utils/TextUtils.swift                 - 已创建 ✅
```

---

### 阶段二：Ollama 集成增强 (中优先级) ✅ 已完成

#### 2.1 Ollama 服务管理 ✅
**目标**: 自动检测和管理 Ollama 服务状态

**已完成**:
- [x] 创建 `OllamaGuardian.swift`:
  - 检测 Ollama 是否安装
  - 检测 Ollama 服务状态
  - 自动启动 Ollama 服务
  - 监控服务健康状态
  - 获取 Ollama 版本
- [x] 创建 `OllamaModelManager.swift`:
  - 列出已安装模型
  - 下载推荐模型（带进度）
  - 模型预热/卸载
  - 删除模型
- [x] 更新 UI:
  - 添加 Ollama 状态指示器
  - 添加首次运行引导

**新建文件**:
```
Services/OllamaGuardian.swift         - 已创建 ✅
Services/OllamaModelManager.swift     - 已创建 ✅
Views/WelcomeView.swift               - 已创建 ✅
```

#### 2.2 翻译 Prompt 优化 ✅
**目标**: 提供与 Windows 端一致的翻译质量

**已完成**:
- [x] 更新默认翻译 Prompt（专业同声传译风格）
- [x] 添加可自定义 Prompt 设置
- [x] 添加 Prompt 编辑器 UI

**修改文件**:
```
Models/AppSettings.swift              - 已添加 customPrompt ✅
Views/SettingsView.swift              - 已添加 Prompt 编辑器 ✅
```

---

### 阶段三：UI/UX 改进 (中优先级)

#### 3.1 Overlay 窗口增强
**目标**: 实现与 Windows 端一致的浮动窗口体验

**任务列表**:
- [ ] 增强 `OverlayView.swift`:
  - 可调整大小
  - 可拖拽移动
  - 记忆窗口位置
  - 背景颜色/透明度自定义
  - 字体颜色自定义
  - 显示句数控制
- [ ] 创建 `OverlayWindowController.swift` 改进:
  - 置顶功能
  - 点击穿透选项
  - 多显示器支持

**修改文件**:
```
Views/OverlayView.swift               - 增强
Views/OverlayWindowController.swift   - 新建/改进
Models/AppSettings.swift              - 添加 Overlay 设置
```

#### 3.2 主窗口改进
**目标**: 提供更好的用户体验

**任务列表**:
- [ ] 添加 Log Cards 功能:
  - 显示最近的识别/翻译记录
  - 可配置显示数量
  - 支持复制
- [ ] 改进工具栏:
  - 添加一键复制
  - 添加暂停/恢复按钮
  - 添加清除按钮
- [ ] 状态栏改进:
  - 显示延迟
  - 显示 Ollama 状态
  - 显示识别语言

**修改文件**:
```
Views/MainView.swift                  - 改进
Views/Components/LogCard.swift        - 新建
Views/Components/StatusBar.swift      - 新建
```

#### 3.3 菜单栏集成
**目标**: 添加系统菜单栏图标和快捷操作

**任务列表**:
- [ ] 创建菜单栏图标
- [ ] 添加快捷菜单:
  - 开始/停止
  - 暂停/恢复
  - 显示/隐藏 Overlay
  - 打开设置
  - 退出应用
- [ ] 添加全局快捷键支持

**新建文件**:
```
App/MenuBarController.swift           - 新建
```

---

### 阶段四：历史记录与数据管理 (低优先级)

#### 4.1 历史记录增强
**目标**: 完善历史记录功能

**任务列表**:
- [ ] 增强 `HistoryService.swift`:
  - 添加搜索功能
  - 添加日期过滤
  - 添加批量删除
- [ ] 添加 CSV 导出功能
- [ ] 添加数据迁移支持
- [ ] 改进 `HistoryView.swift`:
  - 添加搜索栏
  - 添加日期选择器
  - 添加导出按钮
  - 改进列表性能

**修改文件**:
```
Services/HistoryService.swift         - 增强
Views/HistoryView.swift               - 改进
```

#### 4.2 设置持久化改进
**目标**: 使用 JSON 文件存储设置，便于备份和同步

**任务列表**:
- [ ] 将设置从 UserDefaults 迁移到 JSON 文件
- [ ] 添加设置导入/导出
- [ ] 添加设置重置功能

**修改文件**:
```
Models/AppSettings.swift              - 改进持久化
```

---

### 阶段五：高级功能 (低优先级)

#### 5.1 应用更新检查
**任务列表**:
- [ ] 创建 `UpdateService.swift`:
  - 检查 GitHub releases
  - 显示更新对话框
  - 下载更新

#### 5.2 启动引导
**任务列表**:
- [ ] 创建 `SplashView.swift`:
  - 显示启动画面
  - 检查权限
  - 检查 Ollama 状态
  - 首次运行引导

---

## 三、文件结构规划

```
LCTMac/
├── App/
│   ├── AppDelegate.swift
│   ├── LCTMacApp.swift
│   └── MenuBarController.swift        # 新建
├── Models/
│   ├── AppSettings.swift              # 修改
│   ├── Caption.swift                  # 新建
│   ├── Speaker.swift
│   ├── TranscriptionResult.swift
│   └── TranslationEntry.swift
├── Services/
│   ├── AudioCaptureService.swift
│   ├── HistoryService.swift           # 增强
│   ├── OllamaService.swift            # 增强
│   ├── OllamaGuardian.swift           # 新建
│   ├── OllamaModelManager.swift       # 新建
│   ├── SpeechAnalyzerService.swift    # 重写
│   ├── TranslationQueue.swift         # 新建
│   └── UpdateService.swift            # 新建
├── Utils/
│   └── TextUtils.swift                # 新建
├── ViewModels/
│   └── TranscriptionVM.swift          # 改进
├── Views/
│   ├── Components/
│   │   ├── LogCard.swift              # 新建
│   │   └── StatusBar.swift            # 新建
│   ├── HistoryView.swift              # 改进
│   ├── MainView.swift                 # 改进
│   ├── OverlayView.swift              # 增强
│   ├── SettingsView.swift             # 更新
│   ├── SplashView.swift               # 新建
│   └── WelcomeView.swift              # 新建
└── Resources/
    └── Localizable.strings            # 新建（国际化）
```

---

## 四、时间估算

| 阶段 | 预估时间 | 优先级 |
|------|---------|--------|
| 阶段一：核心功能完善 | 2-3 天 | 高 |
| 阶段二：Ollama 集成增强 | 1-2 天 | 中 |
| 阶段三：UI/UX 改进 | 2-3 天 | 中 |
| 阶段四：历史记录与数据管理 | 1 天 | 低 |
| 阶段五：高级功能 | 1-2 天 | 低 |
| **总计** | **7-11 天** | - |

---

## 五、立即可开始的任务

### 优先级 1: 清理代码和专注 SFSpeechRecognizer
1. 删除 Whisper 相关代码
2. 优化 SpeechAnalyzerService
3. 简化 AppSettings

### 优先级 2: 实现翻译队列
1. 创建 TranslationQueue
2. 添加防抖机制
3. 集成到 ViewModel

### 优先级 3: 改进 Overlay
1. 添加拖拽/调整大小
2. 添加设置持久化
3. 改进视觉效果

---

## 六、依赖项

### 现有依赖
- SQLite.swift (历史记录)

### 建议添加
- 无需额外依赖，使用 Apple 原生框架即可

---

## 七、权限需求

确保 `Info.plist` 和 `entitlements` 包含：
- `NSMicrophoneUsageDescription` - 麦克风权限
- `NSSpeechRecognitionUsageDescription` - 语音识别权限
- `NSAppleEventsUsageDescription` - Apple Events 权限（如果需要）
- `com.apple.security.audio.capture` - 音频捕获

---

**文档版本**: 1.0  
**创建日期**: 2026-02-03  
**作者**: AI Assistant
