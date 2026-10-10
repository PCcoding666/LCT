#!/bin/bash
# 诊断 macOS 权限问题（麦克风 / 语音识别 / 屏幕录制回退）

echo "🔍 LCT macOS 权限诊断"
echo "===================="
echo ""

echo "ℹ️  权限模型说明:"
echo "  - 系统音频：通过 Core Audio 进程截取（process tap）采集，不需要任何权限。"
echo "  - 麦克风 / 语音识别：需要在系统设置中授予。"
echo "  - 屏幕录制：仅当 Core Audio tap 创建失败、回退到 ScreenCaptureKit 时才需要。"
echo ""

# 系统信息
echo "📱 系统信息:"
sw_vers
echo ""

# 检查应用签名
echo "🔐 应用签名信息:"
APP_PATH="$HOME/MyProject/LCT/macos/.build/debug/LCTMac"
if [ -f "$APP_PATH" ]; then
    codesign -dv --verbose=4 "$APP_PATH" 2>&1 | head -20
else
    echo "找不到应用: $APP_PATH"
    echo "尝试其他路径..."
    find "$HOME/MyProject/LCT/macos/.build" -name "LCTMac" -type f 2>/dev/null | head -5
fi
echo ""

# 检查 TCC 数据库
echo "🔒 TCC 权限数据库检查:"
echo "(注意: 这需要关闭 SIP 或使用完全磁盘访问权限才能读取)"
echo ""

# 用户 TCC 数据库
USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [ -f "$USER_TCC" ]; then
    echo "用户 TCC 数据库存在: $USER_TCC"
    echo ""
    echo "麦克风权限条目:"
    sqlite3 "$USER_TCC" "SELECT client, auth_value, auth_reason FROM access WHERE service='kTCCServiceMicrophone'" 2>/dev/null || echo "无法读取 (可能需要完全磁盘访问权限)"
    echo ""
    echo "语音识别权限条目:"
    sqlite3 "$USER_TCC" "SELECT client, auth_value, auth_reason FROM access WHERE service='kTCCServiceSpeechRecognition'" 2>/dev/null || echo "无法读取 (可能需要完全磁盘访问权限)"
    echo ""
    echo "屏幕录制权限条目 (仅回退路径需要):"
    sqlite3 "$USER_TCC" "SELECT client, auth_value, auth_reason FROM access WHERE service='kTCCServiceScreenCapture'" 2>/dev/null || echo "无法读取 (可能需要完全磁盘访问权限)"
else
    echo "用户 TCC 数据库不存在"
fi
echo ""

# 检查当前运行的进程
echo "📋 当前运行的 LCT 相关进程:"
ps aux | grep -i "LCTMac\|swift" | grep -v grep
echo ""

# 建议
echo "💡 诊断建议:"
echo "============"
echo ""
echo "1. 系统音频没有声音？先看日志确认走的是哪条路径:"
echo "   grep 'System audio running on' ~/Library/Logs/LCTMac.log"
echo "   - 'Core Audio tap'：正常路径，无需任何权限。"
echo "   - 'ScreenCaptureKit fallback'：tap 创建失败，此时才需要屏幕录制权限；"
echo "     日志里会有 'Core Audio tap failed (<步骤> (OSStatus <码>))'。"
echo ""
echo "2. 麦克风没有声音：重置麦克风权限后重试:"
echo "   tccutil reset Microphone"
echo ""
echo "3. 识别不出文字：重置语音识别权限后重试:"
echo "   tccutil reset SpeechRecognition"
echo ""
echo "4. 仅当确认需要回退路径时，才重置屏幕录制权限:"
echo "   tccutil reset ScreenCapture"
echo ""
echo "5. 如果使用 Xcode 运行，确保 Xcode 本身也有麦克风和语音识别权限"
echo ""

# 检查 Xcode 权限
echo "🔧 检查 Xcode 运行时权限:"
if pgrep -x "Xcode" > /dev/null; then
    echo "Xcode 正在运行"
else
    echo "Xcode 未运行"
fi

# 实时日志
echo ""
echo "📝 实时监控权限请求 (按 Ctrl+C 停止):"
echo "log stream --predicate 'subsystem == \"com.apple.TCC\"' --level debug"
echo ""
echo "运行上面的命令可以看到实时的 TCC 权限请求日志"
