@echo off
:: 将此文件添加到 /scripts/deployment/startup.bat
echo LCT (LiveCaptions Translator) - Local Edition
echo =========================================
echo 正在检查Ollama理路...

REM 检查Ollama服务 - LCT Local Edition 只使用Ollama
tasklist /FI "IMAGENAME eq ollama.exe" | find "ollama.exe" > nul
if errorlevel 1 (
    echo 正在启动Ollama服务...
    start /b "" "%~dp0\..\..\bin\ollama.exe" serve
    timeout /t 5 /nobreak > nul
)

REM 启动主应用
echo 正在启动翻译器...
start "" "%~dp0\..\..\LiveCaptionsTranslator.exe"

exit 