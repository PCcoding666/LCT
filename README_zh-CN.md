# DellLiveCaptionsTranslator - Professional Edition

### *Professional Real-time AI Translation Tool Based on Windows Live Captions*

[English](README.md) | **中文**

## Overview

**✨ DellLiveCaptionsTranslator = Windows Live Captions + Local AI Translation ✨**

A professional real-time speech translation solution developed by Ai-All-You-Need-Platform Pte. Ltd. No external APIs or internet connectivity required for seamless real-time speech translation. It leverages Windows' built-in Live Captions combined with local AI models via Ollama for private, secure, and efficient translation.

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

> ⚠️ **Important**: You must complete these steps before first running DellLiveCaptionsTranslator.

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

### Step 3: Launch DellLiveCaptionsTranslator

Once configured, close Windows Live Captions and start using DellLiveCaptionsTranslator! 🎉

The application will automatically:
- Download and install Ollama if not present
- Pull the default translation model (qwen2.5:3b)
- Configure optimal settings for your hardware

## Support and Contact

### Company Information
**Ai-All-You-Need-Platform Pte. Ltd.**  
Official Website: [https://aiallyouneed.dev](https://aiallyouneed.dev)

### Privacy & Security

✅ **Complete Local Processing**: All translation happens on your device  
✅ **No Internet Required**: Works offline after initial setup  
✅ **No Data Collection**: Your conversations never leave your machine  
✅ **Secure by Design**: No external API calls or cloud dependencies  
✅ **Enterprise Ready**: Suitable for confidential business communications  

---

**Copyright © 2024 Ai-All-You-Need-Platform Pte. Ltd. All rights reserved.**