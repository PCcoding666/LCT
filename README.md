# LiveCaptions Translator - Dell Local Edition

## Overview

**✨ LiveCaptions Translator = Windows Live Captions + Local AI Translation ✨**

This is Dell's optimized local edition of LiveCaptions Translator, providing seamless real-time speech translation without requiring external APIs or internet connectivity. It leverages Windows' built-in Live Captions combined with local AI models via Ollama for private, secure, and efficient translation.

**🚀 Quick Start:** Download from releases and launch instantly!

**🔒 Privacy First:** All translation happens locally on your Dell machine - no data leaves your device.

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
- **Dell Branding**: Features Dell logo in splash screen
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

## Quick Setup Guide

> ⚠️ **Important**: You must complete these steps before first running LiveCaptions Translator.

### Step 1: Verify Windows Live Captions Availability

Confirm Live Captions is available on your system using any of these methods:
- Toggle **Live captions** in Quick Settings
- Press **Win + Ctrl + L**
- Access via **Quick Settings** > **Accessibility** > **Live captions**
- Open **Start** > **All apps** > **Accessibility** > **Live captions**
- Navigate to **Settings** > **Accessibility** > **Captions** and enable **Live captions**

### Step 2: Configure Windows Live Captions

On first launch, Windows Live Captions will:
1. Request consent to process speech data on your device
2. Prompt you to download language files for on-device speech recognition

After starting Windows Live Captions:
1. Click the **⚙️gear** icon to open settings
2. Select **Position** > **Overlay on screen**

> ⚠️ **Critical!** This prevents display bugs when Live Captions is hidden.

### Step 3: Launch LiveCaptions Translator

Once configured, close Windows Live Captions and start using LiveCaptions Translator! 🎉

The application will automatically:
- Download and install Ollama if not present
- Pull the default translation model (qwen2.5:3b)
- Configure optimal settings for your Dell hardware

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

✅ **Complete Local Processing**: All translation happens on your Dell device  
✅ **No Internet Required**: Works offline after initial setup  
✅ **No Data Collection**: Your conversations never leave your machine  
✅ **Secure by Design**: No external API calls or cloud dependencies  
✅ **Enterprise Ready**: Suitable for confidential business communications  

## Troubleshooting

### Common Issues
- **Model Download Fails**: Check internet connection during initial setup
- **Performance Issues**: Ensure adequate RAM and close unnecessary applications
- **Live Captions Not Working**: Verify Windows version and accessibility settings
- **Translation Delays**: Adjust API interval in settings for better performance

### Support Resources
- Check logs in application data folder
- Verify Ollama service status in Task Manager
- Ensure Windows Live Captions is properly configured
- Contact Dell support for hardware-specific optimizations

## Technical Notes

- Built with .NET 8.0 and WPF-UI framework
- Uses Intel IPEX-LLM for hardware acceleration
- Supports ARM64 architecture for future Dell devices
- Implements SQLite for efficient local data storage
- Features automatic error recovery and model management