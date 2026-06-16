#!/bin/bash
# 诊断 macOS 屏幕录制权限问题

echo "🔍 LCT macOS 权限诊断"
echo "===================="
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
    echo "屏幕录制权限条目:"
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
echo "1. 重置所有屏幕录制权限:"
echo "   tccutil reset ScreenCapture"
echo ""
echo "2. 重新运行应用，当系统弹出权限请求时点击'允许'"
echo ""
echo "3. 如果权限请求没有弹出，手动添加:"
echo "   打开 系统设置 > 隐私与安全性 > 屏幕与系统音频录制"
echo "   点击 + 添加应用"
echo ""
echo "4. 如果使用 Xcode 运行，确保 Xcode 也有屏幕录制权限"
echo ""
echo "5. 如果权限已添加但仍不工作:"
echo "   - 先关闭权限开关"
echo "   - 完全退出应用 (Cmd+Q)"
echo "   - 重新打开权限开关"
echo "   - 重新启动应用"
echo ""
echo "6. 最后手段 - 删除旧的权限条目并重新授权:"
echo "   tccutil reset ScreenCapture com.apple.dt.Xcode"
echo "   tccutil reset ScreenCapture"
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
