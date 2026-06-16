# LCT (LiveCaptions Translator) - Professional Edition

## Overview

**✨ LCT (LiveCaptions Translator) = Windows Live Captions + Local AI Translation ✨**

A professional real-time speech translation solution that combines Windows' built-in Live Captions with local AI models via Ollama for private, secure, and efficient translation. Developed by Ai-All-You-Need-Platform Pte. Ltd.

**🚀 Quick Start:** Download from releases and launch instantly!

**🔒 Privacy First:** All translation happens locally on your device - no data leaves your machine.

## Key Features

### 🔄 **Seamless Integration**
- Automatically invokes Windows Live Captions without opening a separate window
- Provides unified experience for real-time audio/speech translation
- Live Captions are hidden by default after first use (configurable in settings)
- Enable ***Include microphone audio*** in Windows Live Captions settings for real-time speech translation

### 🤖 **Local AI Translation**
- **Ollama Engine**: Exclusive use of local AI models for translation
- **Privacy Focused**: All processing happens on your device
- **Multiple Models**: Support for various language models (qwen2.5:3b default)
- **Intel IPEX-LLM**: Optimized for Intel hardware acceleration
- **No Internet Required**: Works completely offline after initial setup

### 🎨 **Modern Interface**
- Clean Fluent UI that matches modern Windows aesthetics
- Automatic light/dark theme switching based on system settings
- Professional branding and user experience
- Multiple viewing modes: standard and compact overlay

### 🪟 **Overlay Window**
- Borderless, transparent floating window for immersive experience
- Perfect for gaming, videos, and live streaming
- Fully customizable appearance: background, text color, font size, transparency
- Can be embedded seamlessly into screen without interfering with other operations
- Adjustable sentence count display

### ⚙️ **Flexible Control**
- Window always-on-top functionality
- Convenient translation pause/resume
- One-click text copying for quick sharing
- Comprehensive settings for Ollama configuration

### 📒 **History Management**
- Records both original and translated text
- Perfect for meetings, lectures, and important discussions
- Export all records to CSV format
- Search and filter capabilities

### 🎞️ **Log Cards**
- Recent transcription records displayed as log cards
- Helps maintain context during conversations
- Configurable card count in settings

## System Requirements

| Requirement | Details |
|-------------|----------|
| **Windows** | Windows 11 (22H2+) with Live Captions support |
| **.NET** | .NET 8.0+ Runtime (included in installer) |
| **Hardware** | Intel CPU recommended for IPEX-LLM optimization |
| **Memory** | 8GB+ RAM for optimal AI model performance |
| **Storage** | 2GB+ free space for application and models |

> ⚠️ **Important**: This tool is based on Windows Live Captions, available since **Windows 11 22H2**.

## Getting Started

> ⚠️ **IMPORTANT:** Complete the following setup before running LCT for the first time.
>
> For more details, see Microsoft's guide: [Using live captions to better understand audio](https://support.microsoft.com/en-us/windows/use-live-captions-to-better-understand-audio-b52da59c-14b8-4031-aeeb-f6a47e6055df)

### Step 1: Verify Windows Live Captions Availability

Ensure Live Captions is available on your system through any of these methods:

- Toggle **Live captions** in the Quick Settings panel
- Use the keyboard shortcut **Win + Ctrl + L**
- Navigate to **Quick Settings** > **Accessibility** > **Live captions**
- Access from **Start** > **All apps** > **Accessibility** > **Live captions**
- Go to **Settings** > **Accessibility** > **Captions** and toggle on **Live captions**

### Step 2: Initial Live Captions Configuration

When you first launch Windows Live Captions, it will:
1. Request permission to process voice data locally on your device
2. Prompt you to download the necessary language files for on-device speech recognition

After the initial setup, configure the following settings:
1. Click the **⚙️ gear** icon in Live Captions to open settings
2. In **Change language**, select your **source language** (the language to be recognized)
3. Under **Position**, select **Overlaid on screen**

> ⚠️ **Critical:** The position setting is required to prevent display issues when Live Captions runs in the background.

### Step 3: Enable Microphone Audio (Optional)

To enable real-time translation of your own speech through the microphone:

1. In Live Captions, click the **⚙️ gear** icon
2. Go to **Preferences**
3. Check **Include microphone audio**

This allows LCT to capture and translate both system audio and your microphone input simultaneously.

### Step 4: Launch LCT

After completing the configuration, close Windows Live Captions and start LiveCaptions Translator! 🎉

The application will automatically:
- Download and install Ollama if not present
- Pull the default translation model (qwen2.5:3b)
- Configure optimal settings for your hardware

## Configuration

Customize the following options in the **Settings** view:

### Display Options
- **LiveCaptions**: Show/hide original caption text in Home view
- **Log Cards**: Number of recent translation cards displayed
- **Overlay Sentences**: Number of sentences shown in overlay mode
- **Show Latency**: Display translation processing time

### Ollama Configuration
- **API Endpoint**: Local Ollama server URL (default: http://localhost:11434)
- **Model Name**: AI model for translation (default: qwen2.5:3b)
- **System Prompt**: Custom instructions for translation behavior
- **Temperature**: Control translation creativity/consistency
- **Max Tokens**: Maximum response length

### Performance Tuning
- **API Interval**: Delay between translation requests (balance speed vs. resource usage)
- **Target Language**: Destination language for translations
- **Model Loading**: Automatic model management and optimization

## Architecture

### Core Components
- **Translation Engine**: Exclusive Ollama integration with Intel IPEX-LLM
- **UI Framework**: WPF with Fluent UI components
- **Data Layer**: SQLite for history storage
- **System Integration**: Windows Live Captions automation
- **Model Management**: Automatic download and optimization

### Build Information
- **Version**: 1.0.1 (Build 279)
- **Target Framework**: .NET 8.0-windows
- **Runtime**: Self-contained win-x64
- **Installer Size**: ~97MB
- **Configuration**: Release with ReadyToRun optimization

## Privacy & Security

✅ **Complete Local Processing**: All translation happens on your device  
✅ **No Internet Required**: Works offline after initial setup  
✅ **No Data Collection**: Your conversations never leave your machine  
✅ **Secure by Design**: No external API calls or cloud dependencies  
✅ **Enterprise Ready**: Suitable for confidential business communications  

## Support and Contact

### Company Information
**Ai-All-You-Need-Platform Pte. Ltd.**  
Official Website: [https://aiallyouneed.dev](https://aiallyouneed.dev)

### Troubleshooting

#### Common Issues
- **Model Download Fails**: Check internet connection during initial setup
- **Performance Issues**: Ensure adequate RAM and close unnecessary applications
- **Live Captions Not Working**: Verify Windows version and accessibility settings
- **Translation Delays**: Adjust API interval in settings for better performance

#### Support Resources
- Check logs in application data folder
- Verify Ollama service status in Task Manager
- Ensure Windows Live Captions is properly configured
- Visit our official website for documentation and support

## Technical Notes

- Built with .NET 8.0 and WPF-UI framework
- Uses Intel IPEX-LLM for hardware acceleration
- Supports ARM64 architecture for future compatibility
- Implements SQLite for efficient local data storage
- Features automatic error recovery and model management

---

**Copyright © 2024 Ai-All-You-Need-Platform Pte. Ltd. All rights reserved.**