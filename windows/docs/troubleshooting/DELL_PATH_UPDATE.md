# Dell Installation Path Update Summary

## Overview
Updated the application installation path and branding from:
- **Old**: `C:\Program Files\SakiRinn and Contributors\LiveCaptions Translator`
- **New**: `C:\Program Files\Dell\DellLiveCaptionsTranslator-v1.0.1`

## Modified Files

### 1. Installation Configuration
**File**: `scripts/deployment/installer.nsi`
- Changed `COMPANY_NAME` from "SakiRinn and Contributors" to "Dell"
- Changed `APP_NAME` from "LiveCaptions Translator" to "DellLiveCaptionsTranslator-v1.0.1"
- Updated copyright from "Copyright © 2024 SakiRinn and other contributors" to "Copyright © 2024 Dell Technologies"
- New installation path: `C:\Program Files\Dell\DellLiveCaptionsTranslator-v1.0.1`

### 2. Assembly Information
**File**: `src/AssemblyInfo.cs`
- Updated `AssemblyTitle` to "DellLiveCaptionsTranslator"
- Updated `AssemblyDescription` to "Dell Real-time Speech Translation Tool based on Windows LiveCaptions"
- Updated `AssemblyCompany` to "Dell Technologies"
- Updated `AssemblyProduct` to "DellLiveCaptionsTranslator"
- Updated `AssemblyCopyright` to "Copyright © 2024 Dell Technologies"

### 3. Application Version Info
**File**: `src/utils/AppVersionInfo.cs`
- Updated fallback copyright to "Copyright © 2024 Dell Technologies"
- Updated fallback company to "Dell Technologies"
- Updated fallback product to "DellLiveCaptionsTranslator"
- Updated fallback title to "DellLiveCaptionsTranslator"

### 4. Settings Path
**File**: `src/models/Setting.cs`
- Changed settings directory from "Dell LiveCaptions Translator" to "DellLiveCaptionsTranslator"
- New path: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\setting.json`

### 5. Application Data Path
**File**: `src/utils/ApplicationSetup.cs`
- Changed app data directory from "LiveCaptionsTranslator" to "DellLiveCaptionsTranslator"
- New path: `%LOCALAPPDATA%\DellLiveCaptionsTranslator`

### 6. Application Logging
**File**: `src/App.xaml.cs`
- Changed mutex name from "LiveCaptionsTranslator-..." to "DellLiveCaptionsTranslator-..."
- Changed log directory from "LiveCaptionsTranslator" to "DellLiveCaptionsTranslator"
- New log path: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\logs\log-.txt`

### 7. Translator First Run Flag
**File**: `src/Translator.cs`
- Changed first run flag path from "LiveCaptionsTranslator" to "DellLiveCaptionsTranslator"
- New path: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\first_run.flag`

### 8. HTTP User Agent
**File**: `src/utils/OllamaDownloader.cs`
- Changed User-Agent from "LiveCaptionsTranslator" to "DellLiveCaptionsTranslator"

### 9. Startup Registry (Already Correct)
**File**: `src/windows/EnterpriseWelcomeWindow.xaml.cs`
- Already uses "DellLiveCaptionsTranslator" for registry key

## Impact Summary

### Installation
- **Installation Directory**: `C:\Program Files\Dell\DellLiveCaptionsTranslator-v1.0.1`
- **Company Folder**: Dell (instead of SakiRinn and Contributors)
- **Start Menu**: Programs will appear under "Dell" folder

### User Data Paths
All user data paths have been updated to use "DellLiveCaptionsTranslator":
- Settings: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\setting.json`
- Logs: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\logs\`
- Ollama: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\ollama\`
- Models: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\models\`
- Downloads: `%LOCALAPPDATA%\DellLiveCaptionsTranslator\downloads\`

### Branding
- All references to "SakiRinn and Contributors" changed to "Dell Technologies"
- All product names changed to "DellLiveCaptionsTranslator"
- Copyright updated to Dell Technologies

## Build Output
The installer filename will be generated as:
- Format: `DellLiveCaptionsTranslator-v{VERSION}-Setup.exe`
- Example: `DellLiveCaptionsTranslator-v1.0.1-Setup.exe`

## Migration Notes

**Important**: Existing users will need to:
1. Uninstall the old version from the old path
2. Install the new version to the new Dell path
3. User settings and data will NOT be automatically migrated (different app data folder)

If you need to preserve user settings, you should:
1. Export settings from `%LOCALAPPDATA%\LiveCaptionsTranslator\`
2. Import to `%LOCALAPPDATA%\DellLiveCaptionsTranslator\` after installation

## Next Steps

To build the installer with the new configuration:
```batch
build-installer.bat --version 1.0.1
```

This will create:
- Installer: `scripts\deployment\DellLiveCaptionsTranslator-v1.0.1-Setup.exe`
- Installation path: `C:\Program Files\Dell\DellLiveCaptionsTranslator-v1.0.1`
