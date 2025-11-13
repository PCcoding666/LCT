; NSIS Script for LCT (LiveCaptions Translator) with Version Management
; Auto-generated version support

!include "MUI2.nsh"
; Include additional functions
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!insertmacro GetSize

# --- Version and Application Information ---
!define APP_NAME "LCT"
!define COMPANY_NAME "INOVAS TECH PTE.LTD."
; APP_VERSION can be overridden from command line
!ifndef APP_VERSION
  !define APP_VERSION "1.0.0" ; Default version if not provided
!endif
!define EXE_NAME "LiveCaptionsTranslator.exe"
; INSTALLER_NAME can be overridden from command line
!ifndef INSTALLER_NAME
  !define INSTALLER_NAME "LiveCaptionsTranslator-Setup.exe"
!endif

; Override from command line if provided
!ifdef OUTPUT_NAME
  !undef INSTALLER_NAME
  !define INSTALLER_NAME "${OUTPUT_NAME}"
!endif

; Version parsing for Windows version info
!searchparse /noerrors ${APP_VERSION} "" MAJOR_VERSION "." MINOR_VERSION "." PATCH_VERSION "." BUILD_VERSION
!ifndef BUILD_VERSION
  !define BUILD_VERSION "0"
!endif
!ifndef PATCH_VERSION
  !searchparse /noerrors ${APP_VERSION} "" MAJOR_VERSION "." MINOR_VERSION
  !define PATCH_VERSION "0"
!endif

Name "${APP_NAME} (LiveCaptions Translator) v${APP_VERSION}"
OutFile "${INSTALLER_NAME}"
InstallDir "$PROGRAMFILES64\${COMPANY_NAME}\${APP_NAME}"
InstallDirRegKey HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "InstallDir"
RequestExecutionLevel admin

; Version Information
VIProductVersion "${MAJOR_VERSION}.${MINOR_VERSION}.${PATCH_VERSION}.${BUILD_VERSION}"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${COMPANY_NAME}"
VIAddVersionKey "FileDescription" "Real-time speech translation tool based on Windows LiveCaptions"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Copyright © 2024 INOVAS TECH PTE.LTD."
VIAddVersionKey "OriginalFilename" "${INSTALLER_NAME}"

# --- Interface Settings ---
!define MUI_ABORTWARNING
!define MUI_ICON "${PROJECT_ROOT}\images\LCT_logo.ico"
!define MUI_UNICON "${PROJECT_ROOT}\images\LCT_logo.ico"
; Optional: Header and welcome images (commented out if files don't exist)
; !define MUI_HEADERIMAGE
; !define MUI_HEADERIMAGE_BITMAP "${PROJECT_ROOT}\images\installer-header.bmp" ; Optional: 150x57 pixels
; !define MUI_WELCOMEFINISHPAGE_BITMAP "${PROJECT_ROOT}\images\installer-welcome.bmp" ; Optional: 164x314 pixels

# --- Custom Pages ---
!define MUI_WELCOMEPAGE_TITLE "Welcome to LCT (LiveCaptions Translator) Setup"
!define MUI_WELCOMEPAGE_TEXT "This wizard will guide you through the installation of LCT (LiveCaptions Translator).$\r$\n$\r$\nLCT is a professional real-time speech translation solution that works with Windows LiveCaptions to provide live translation of spoken content.$\r$\n$\r$\nClick Next to continue."

!define MUI_FINISHPAGE_TITLE "LCT (LiveCaptions Translator) Installation Complete"
!define MUI_FINISHPAGE_TEXT "LCT (LiveCaptions Translator) has been successfully installed on your computer.$\r$\n$\r$\nClick Finish to close this wizard."
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE_NAME}"
!define MUI_FINISHPAGE_RUN_TEXT "Launch LCT (LiveCaptions Translator) now"

# --- Pages ---
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${PROJECT_ROOT}\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

# --- Uninstaller Pages ---
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

# --- Languages ---
!insertmacro MUI_LANGUAGE "English"

# --- Installation Sections ---
Section "Main Application" SecMain
    SectionIn RO  ; Required section
    
    SetDetailsPrint textonly
    DetailPrint "Installing ${APP_NAME} v${APP_VERSION}..."
    SetDetailsPrint listonly
    
    SetOutPath $INSTDIR
    
    ; Install application files
    DetailPrint "Installing application files..."
    File /r "${PROJECT_ROOT}\bin\Release\net8.0-windows\win-x64\publish\*.*"
    
    ; Store installation information
    WriteRegStr HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "InstallDir" "$INSTDIR"
    WriteRegStr HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "Version" "${APP_VERSION}"
    WriteRegStr HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "InstallDate" "$\"$R0$\""
    WriteRegDWORD HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "VersionMajor" "${MAJOR_VERSION}"
    WriteRegDWORD HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "VersionMinor" "${MINOR_VERSION}"
    WriteRegDWORD HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "VersionPatch" "${PATCH_VERSION}"
    
    ; Create uninstaller
    DetailPrint "Creating uninstaller..."
    WriteUninstaller "$INSTDIR\uninstall.exe"
    
    ; Create shortcuts
    DetailPrint "Creating shortcuts..."
    CreateDirectory "$SMPROGRAMS\${COMPANY_NAME}"
    CreateShortCut "$SMPROGRAMS\${COMPANY_NAME}\LCT (LiveCaptions Translator).lnk" "$INSTDIR\${EXE_NAME}" "" "$INSTDIR\${EXE_NAME}" 0
    CreateShortCut "$SMPROGRAMS\${COMPANY_NAME}\Uninstall LCT.lnk" "$INSTDIR\uninstall.exe" "" "$INSTDIR\uninstall.exe" 0
    
    ; Desktop shortcut (optional)
    CreateShortCut "$DESKTOP\LCT (LiveCaptions Translator).lnk" "$INSTDIR\${EXE_NAME}" "" "$INSTDIR\${EXE_NAME}" 0
    
    ; Register with Windows Add/Remove Programs
    DetailPrint "Registering with Windows Add/Remove Programs..."
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayName" "LCT (LiveCaptions Translator)"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayVersion" "${APP_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "Publisher" "${COMPANY_NAME}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "DisplayIcon" "$INSTDIR\${EXE_NAME}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "URLInfoAbout" "https://aiallyouneed.dev"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "InstallLocation" "$INSTDIR"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "NoRepair" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "VersionMajor" "${MAJOR_VERSION}"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "VersionMinor" "${MINOR_VERSION}"
    
    ; Estimate install size
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    IntFmt $0 "0x%08X" $0
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" "EstimatedSize" "$0"
    
    DetailPrint "Installation completed successfully!"
SectionEnd

Section "Visual C++ Redistributable" SecVCRedist
    SetDetailsPrint textonly
    DetailPrint "Installing Visual C++ Redistributable..."
    SetDetailsPrint listonly
    
    SetOutPath "$TEMP"
    File "${PROJECT_ROOT}\scripts\deployment\VC_redist.x64.exe"
    
    ; Check if already installed
    ClearErrors
    ReadRegDWORD $0 HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64" "Installed"
    IfErrors install_vcredist
    IntCmp $0 1 vcredist_already_installed
    
    install_vcredist:
    DetailPrint "Installing Microsoft Visual C++ 2015-2022 Redistributable (x64)..."
    ExecWait '"$TEMP\VC_redist.x64.exe" /install /passive /norestart' $1
    
    IntCmp $1 0 vcredist_success
    IntCmp $1 1638 vcredist_already_installed ; Already installed
    IntCmp $1 3010 vcredist_success ; Success but reboot required
    
    DetailPrint "Visual C++ Redistributable installation returned code $1"
    Goto vcredist_done
    
    vcredist_already_installed:
    DetailPrint "Visual C++ Redistributable is already installed"
    Goto vcredist_done
    
    vcredist_success:
    DetailPrint "Visual C++ Redistributable installed successfully"
    
    vcredist_done:
    Delete "$TEMP\VC_redist.x64.exe"
SectionEnd

Section "Desktop Integration" SecDesktop
    ; Additional desktop integration features
    DetailPrint "Setting up desktop integration..."
    
    ; File associations (if needed in future)
    ; WriteRegStr HKCR ".lct" "" "LiveCaptionsTranslator.Document"
    
    ; Windows startup (optional)
    ; WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APP_NAME}" "$INSTDIR\${EXE_NAME}"
SectionEnd

# --- Uninstaller Section ---
Section "Uninstall"
    SetDetailsPrint textonly
    DetailPrint "Uninstalling ${APP_NAME}..."
    SetDetailsPrint listonly
    
    ; Stop application if running (commented out - requires nsProcess plugin)
    ; DetailPrint "Stopping ${APP_NAME} if running..."
    ; ${nsProcess::FindProcess} "${EXE_NAME}" $R0
    ; StrCmp $R0 0 0 +3
    ; DetailPrint "${APP_NAME} is running, attempting to close..."
    ; ${nsProcess::CloseProcess} "${EXE_NAME}" $R0
    
    ; Remove files and directories
    DetailPrint "Removing application files..."
    RMDir /r "$INSTDIR"
    
    ; Remove shortcuts
    DetailPrint "Removing shortcuts..."
    Delete "$SMPROGRAMS\${COMPANY_NAME}\LCT (LiveCaptions Translator).lnk"
    Delete "$SMPROGRAMS\${COMPANY_NAME}\Uninstall LCT.lnk"
    RMDir "$SMPROGRAMS\${COMPANY_NAME}"
    Delete "$DESKTOP\LCT (LiveCaptions Translator).lnk"
    
    ; Remove registry entries
    DetailPrint "Removing registry entries..."
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
    DeleteRegKey HKLM "Software\${COMPANY_NAME}\${APP_NAME}"
    DeleteRegKey /ifempty HKLM "Software\${COMPANY_NAME}"
    
    ; Remove user data (optional, ask user)
    MessageBox MB_YESNO "Do you want to remove user settings and data?" /SD IDNO IDNO skip_userdata
    RMDir /r "$APPDATA\LiveCaptions-Translator"
    RMDir /r "$LOCALAPPDATA\LiveCaptions-Translator"
    
    skip_userdata:
    DetailPrint "Uninstallation completed!"
SectionEnd

# --- Component Descriptions ---
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Core application files for LCT (LiveCaptions Translator). This component is required."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecVCRedist} "Microsoft Visual C++ 2015-2022 Redistributable (x64). Required for the AI engine (Ollama). Will be skipped if already installed."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Additional desktop integration features and optional enhancements."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

# --- Functions ---
Function .onInit
    ; Check Windows version
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK "LCT (LiveCaptions Translator) requires Windows 10 or later."
        Abort
    ${EndIf}
    
    ; Check for existing installation
    ReadRegStr $R0 HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "InstallDir"
    StrCmp $R0 "" new_installation
    
    ; Existing installation found
    ReadRegStr $R1 HKLM "Software\${COMPANY_NAME}\${APP_NAME}" "Version"
    MessageBox MB_YESNOCANCEL "LCT (LiveCaptions Translator) $R1 is already installed.\r\n\r\nDo you want to upgrade to version ${APP_VERSION}?" /SD IDYES IDYES continue_install IDNO exit_installer
    Abort
    
    exit_installer:
    Quit
    
    continue_install:
    StrCpy $INSTDIR $R0
    
    new_installation:
FunctionEnd

Function un.onInit
    MessageBox MB_YESNO "Are you sure you want to uninstall LCT (LiveCaptions Translator)?" /SD IDYES IDYES +2
    Abort
FunctionEnd

