#!/bin/bash
# 构建并签名 LCTMac 应用
# 这个脚本会使用本地开发者签名来签名应用，使其能获得屏幕录制权限

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🔨 构建 LCTMac..."
cd "$PROJECT_DIR"

# 构建应用
swift build -c debug

# 获取构建产物路径
BUILD_PATH="$PROJECT_DIR/.build/debug/LCTMac"

if [ ! -f "$BUILD_PATH" ]; then
    BUILD_PATH="$PROJECT_DIR/.build/arm64-apple-macosx/debug/LCTMac"
fi

if [ ! -f "$BUILD_PATH" ]; then
    echo "❌ 找不到构建产物"
    exit 1
fi

echo "📦 应用路径: $BUILD_PATH"

# 查找可用的签名身份
echo ""
echo "🔍 查找可用的代码签名身份..."
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk -F'"' '{print $2}')

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID" | head -1 | awk -F'"' '{print $2}')
fi

if [ -z "$IDENTITY" ]; then
    echo "⚠️  未找到开发者证书，使用 adhoc 签名"
    echo "   要获得屏幕录制权限，建议使用 Xcode 运行应用"
    echo ""
    echo "🔐 使用 adhoc 签名并添加 entitlements..."
    codesign --force --sign - \
        --entitlements "$PROJECT_DIR/LCTMac/LCTMac.entitlements" \
        --options runtime \
        "$BUILD_PATH"
else
    echo "✅ 找到签名身份: $IDENTITY"
    echo ""
    echo "🔐 签名应用..."
    codesign --force --sign "$IDENTITY" \
        --entitlements "$PROJECT_DIR/LCTMac/LCTMac.entitlements" \
        --options runtime \
        "$BUILD_PATH"
fi

echo ""
echo "📋 验证签名..."
codesign -dv "$BUILD_PATH" 2>&1

echo ""
echo "✅ 构建和签名完成！"
echo ""
echo "🚀 运行应用:"
echo "   $BUILD_PATH"
echo ""
echo "⚠️  首次运行时，请在系统弹出的对话框中允许屏幕录制权限"
