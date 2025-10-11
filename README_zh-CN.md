<div align="center">

<img src="src/LiveCaptions-Translator.ico" width="128" height="128" alt="LiveCaptions Translator图标"/>

# LiveCaptions Translator - Dell本地版

### *基于Windows实时字幕的本地AI实时翻译工具*

[![Master Build](https://github.com/SakiRinn/LiveCaptions-Translator/actions/workflows/dotnet-build.yml/badge.svg?branch=master)](https://github.com/SakiRinn/LiveCaptions-Translator/actions/workflows/dotnet-build.yml)
[![GitHub Release](https://img.shields.io/github/v/release/SakiRinn/LiveCaptions-Translator?label=Latest)](https://github.com/SakiRinn/LiveCaptions-Translator/releases/latest)
[![License](https://img.shields.io/github/license/SakiRinn/LiveCaptions-Translator)](https://github.com/SakiRinn/LiveCaptions-Translator/blob/master/LICENSE)
[![Dell Optimized](https://img.shields.io/badge/Dell-Optimized-007DB8?style=flat&logo=dell)](https://www.dell.com)

[English](README.md) | **中文**

</div>

## 概述

**✨ LiveCaptions Translator = Windows实时字幕 + 本地AI翻译 ✨**

这是Dell优化的LiveCaptions Translator本地版本，无需外部API或网络连接即可提供无缝实时语音翻译。它利用Windows内置的实时字幕结合通过Ollama的本地AI模型，实现私密、安全且高效的翻译。

**🚀 快速开始：** 从发布页面下载并一键启动！

**🔒 隐私优先：** 所有翻译都在您的Dell机器上本地处理 - 数据不会离开您的设备。

<div align="center">
  <img src="images/preview.png" alt="LiveCaptions Translator预览" width="90%" />
  <br>
  <em style="font-size:80%">LiveCaptions Translator预览</em>
  <br>
</div>

## 功能特性

- **🔄 无缝集成**

  自动调用Windows实时字幕而无需打开单独窗口。为实时音频/语音翻译提供统一体验。

  首次使用后，Windows实时字幕默认将被隐藏。您可以在设置中再次显示它。

  <div align="center">
    <img src="images/show_livecaptions.png" alt="实时字幕显示/隐藏按钮" width="90%" />
    <br>
    <em style="font-size:80%">实时字幕显示/隐藏按钮</em>
    <br>
  </div>

  通过在Windows实时字幕设置中启用 ***包含麦克风音频*** 选项，您可以实现实时语音翻译！
  > ⚠️ **重要:** 您必须在Windows实时字幕中更改源语言！

- **🤖 本地AI翻译**

  - **Ollama引擎**: 专享使用本地AI模型进行翻译
  - **隐私保护**: 所有处理都在您的设备上进行
  - **多模型支持**: 支持各种语言模型（默认qwen2.5:3b）
  - **Intel IPEX-LLM**: 针对Intel硬件加速优化
  - **无需网络**: 初始设置后完全离线工作

- **🎨 现代化界面**

  易于使用且简洁的Fluent UI与现代Windows美学保持一致。

  它可以根据系统设置自动在浅色和深色主题🌓之间切换。

  **Dell品牌**: 在启动画面中展示Dell标志。

- **🪟 悬浮窗口**

  打开无边框、透明的悬浮窗口显示字幕，提供最沉浸式的体验。这对游戏、视频和直播等场景非常有用！

  您甚至可以使其完全嵌入到屏幕中，成为屏幕的一部分。这意味着它不会影响您的任何操作！这对游戏玩家来说再合适不过了。

  <div align="center">
    <img src="images/overlay_window.png" alt="悬浮窗口" width="80%" />
    <br>
    <em style="font-size:80%">悬浮窗口</em>
    <br>
  </div>

  您可以在任务栏上打开悬浮窗口，以及调整诸如窗口背景和字幕颜色、字体大小和透明度等参数。极高的可配置性使其能够完全符合您的偏好！

  您可以在设置页的 *Overlay Sentences* 选项调整同时显示的句子数量。

- **⚙️ 灵活控制**

  支持窗口置顶和便利的翻译暂停/恢复，并且您可以一键复制文本以便快速分享或保存。

- **📒 历史记录管理**

  记录原文和翻译文本，非常适合会议、讲座和重要讨论。

  您可以将所有记录导出为CSV文件。

  <div align="center">
    <img src="images/history.png" alt="翻译历史" width="90%" />
    <br>
    <em style="font-size:80%">翻译历史</em>
    <br>
  </div>

- **🎞️ 日志卡片**

  最近的转录记录可以显示为日志卡片，这有助于您更好地把握上下文。

  您可以在主页任务栏上启用它，并在设置页的 *Log Cards* 选项调整卡片数量。

  <div align="center">
    <img src="images/log_cards.png" alt="日志卡片" width="90%" />
    <br>
    <em style="font-size:80%">日志卡片</em>
    <br>
  </div>


## 系统要求

<div align="center">

| 要求                                                                                                                    | 详情          |
|-----------------------------------------------------------------------------------------------------------------------|-------------|
| <img src="https://img.shields.io/badge/Windows-11%20(22H2+)-0078D6?style=for-the-badge&logo=windows&logoColor=white"> | 支持实时字幕功能    |
| <img src="https://img.shields.io/badge/.NET-8.0+-512BD4?style=for-the-badge&logo=dotnet&logoColor=white">             | 包含在安装程序中 |
| <img src="https://img.shields.io/badge/Hardware-Intel%20CPU-00A6E6?style=for-the-badge&logo=intel&logoColor=white">     | 推荐用于IPEX优化 |
| <img src="https://img.shields.io/badge/Memory-8GB+%20RAM-FF6B35?style=for-the-badge">                                  | AI模型最佳性能  |
| <img src="https://img.shields.io/badge/Storage-2GB+%20Free-28A745?style=for-the-badge">                               | 应用和模型空间  |

</div>

本工具基于Windows实时字幕，该功能自 **Windows 11 22H2** 起可用。

**.NET 8.0运行时** 已包含在安装程序中，无需单独安装。

> ⚠️ **重要**: 此Dell本地版专为隐私和安全而设计，所有翻译处理都在您的设备上本地进行。

<div align="center">
  <p align="center">
    <a href="https://github.com/SakiRinn/LiveCaptions-Translator/wiki">
      <img src="https://img.shields.io/badge/📚_查看我们的Wiki获取详细信息-2ea44f?style=for-the-badge" alt="查看我们的Wiki">
    </a>
  </p>
</div>

## 入门指南

> ⚠️ **重要:** 首次运行LiveCaptions Translator前，您必须完成以下步骤。
>
> 有关详细信息，请参阅Microsoft的[使用实时字幕](https://support.microsoft.com/zh-cn/windows/使用实时字幕更好地理解音频-b52da59c-14b8-4031-aeeb-f6a47e6055df)指南。

### 步骤1: 验证Windows实时字幕可用性

使用以下任一方法确认您的系统上可用实时字幕：

- 在快速设置中切换 **实时字幕**
- 按 **Win + Ctrl + L**
- 通过 **快速设置** > **辅助功能** > **实时字幕** 访问
- 打开 **开始** > **所有应用** > **辅助功能** > **实时字幕**
- 导航至 **设置** > **辅助功能** > **字幕** 并启用 **实时字幕**

### 步骤2: 配置Windows实时字幕

首次启动时，Windows实时字幕会请求您同意在设备上处理语音数据，并提示您下载用于设备上语音识别的语言文件。

启动Windows实时字幕后，点击 **⚙️齿轮** 图标打开设置菜单，然后选择 **位置** > **覆盖在屏幕上** 。

> ⚠️ **非常重要！** 否则隐藏Windows实时字幕后屏幕会出现显示BUG.

<div align="center">
  <img src="images/speech_recognition.png" alt="语音识别下的项目" width="80%" />
  <br>
  <em style="font-size:80%">需要下载的语音识别组件</em>
  <br>
</div>

配置完成后，关闭Windows实时字幕然后开始使用LiveCaptions Translator吧！🎉

### 步骤3: 启动LiveCaptions Translator

一旦配置完成，关闭Windows实时字幕并开始使用LiveCaptions Translator！🎉

应用程序将自动：
- 下载并安装Ollama（如果不存在）
- 拉取默认翻译模型（qwen2.5:3b）
- 为您的Dell硬件配置最佳设置

## 配置选项

在 **设置** 界面中可以自定义以下选项：

### 显示选项
- **LiveCaptions**: 在主界面中显示/隐藏原始字幕文本
- **Log Cards**: 显示的最近翻译卡片数量
- **Overlay Sentences**: 悬浮模式中显示的句子数量
- **Show Latency**: 显示翻译处理时间

### Ollama配置
- **API端点**: 本地Ollama服务器URL（默认：http://localhost:11434）
- **模型名称**: 用于翻译的AI模型（默认：qwen2.5:3b）
- **系统提示**: 翻译行为的自定义指令
- **温度**: 控制翻译创意性/一致性
- **最大令牌**: 最大响应长度

### 性能调优
- **API间隔**: 翻译请求之间的延迟（平衡速度与资源使用）
- **目标语言**: 翻译的目标语言
- **模型加载**: 自动模型管理和优化

## 架构说明

### 核心组件
- **翻译引擎**: 专用Ollama集成与Intel IPEX-LLM
- **UI框架**: WPF与Fluent UI组件
- **数据层**: SQLite用于历史存储
- **系统集成**: Windows实时字幕自动化
- **模型管理**: 自动下载和优化

### 构建信息
- **版本**: 1.0.1（构建 279）
- **目标框架**: .NET 8.0-windows
- **运行时**: 自包含 win-x64
- **安装程序大小**: ~97MB
- **配置**: 使用ReadyToRun优化的Release版本

## 隐私与安全

✅ **完全本地处理**: 所有翻译都在您的Dell设备上进行  
✅ **无需网络**: 初始设置后离线工作  
✅ **无数据收集**: 您的对话永远不会离开您的机器  
✅ **安全设计**: 无外部API调用或云依赖  
✅ **企业就绪**: 适用于机密商务通信  

## 故障排除

### 常见问题
- **模型下载失败**: 初始设置期间检查网络连接
- **性能问题**: 确保足够的RAM并关闭不必要的应用程序
- **实时字幕不工作**: 验证Windows版本和辅助功能设置
- **翻译延迟**: 在设置中调整API间隔以获得更好的性能

### 支持资源
- 检查应用程序数据文件夹中的日志
- 在任务管理器中验证Ollama服务状态
- 确保正确配置Windows实时字幕
- 联系Dell支持获取硬件特定优化

## 技术说明

- 使用.NET 8.0和WPF-UI框架构建
- 使用Intel IPEX-LLM进行硬件加速
- 支持ARM64架构以支持未来的Dell设备
- 实现SQLite高效本地数据存储
- 具有自动错误恢复和模型管理功能

---

**LiveCaptions Translator - Dell本地版** | 版本 1.0.1 | 构建 279  
版权所有 © 2024 SakiRinn 及其他贡献者 | Dell优化版本
