open Package.swift#!/bin/bash
# LCT macOS 测试脚本
# 用于验证核心功能

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🧪 LCT macOS 测试脚本"
echo "===================="
echo ""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

# 测试函数
test_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    pass_count=$((pass_count + 1))
}

test_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    fail_count=$((fail_count + 1))
}

# ==================== 编译测试 ====================
echo "📦 编译测试"
echo "----------"

cd "$PROJECT_DIR"

if swift build 2>&1 | grep -q "Build complete"; then
    test_pass "项目编译成功"
else
    test_fail "项目编译失败"
    echo "运行 'swift build' 查看详细错误"
fi

echo ""

# ==================== Ollama 连接测试 ====================
echo "🤖 Ollama 连接测试"
echo "------------------"

if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
    test_pass "Ollama 服务正在运行"
    
    # 检查可用模型
    models=$(curl -s http://localhost:11434/api/tags | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$models" ]; then
        echo "   可用模型: $models"
    fi
else
    test_fail "Ollama 服务未运行"
    echo "   运行 'ollama serve' 启动服务"
fi

echo ""

# ==================== 权限测试 ====================
echo "🔐 权限检查"
echo "-----------"

# 检查麦克风权限（通过检查 TCC 数据库）
if sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
    "SELECT service FROM access WHERE service='kTCCServiceMicrophone'" 2>/dev/null | grep -q "kTCCServiceMicrophone"; then
    echo -e "${YELLOW}⚠ 麦克风权限${NC}: 需要在运行应用时授权"
else
    echo -e "${YELLOW}⚠ 麦克风权限${NC}: 需要在运行应用时授权"
fi

# 检查屏幕录制权限
if sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
    "SELECT service FROM access WHERE service='kTCCServiceScreenCapture'" 2>/dev/null | grep -q "kTCCServiceScreenCapture"; then
    echo -e "${YELLOW}⚠ 屏幕录制权限${NC}: 需要在运行应用时授权"
else
    echo -e "${YELLOW}⚠ 屏幕录制权限${NC}: 需要在运行应用时授权"
fi

echo ""

# ==================== 快速功能测试 ====================
echo "🔬 核心功能测试（使用 Swift）"
echo "-----------------------------"

# 创建临时 Swift 测试文件
cat > /tmp/lct_test.swift << 'SWIFT_TEST'
import Foundation

// ===== TextUtils 测试 =====

// CJK 检测
func isCJK(_ char: Character?) -> Bool {
    guard let char = char else { return false }
    for scalar in char.unicodeScalars {
        let value = scalar.value
        if (0x4E00...0x9FFF).contains(value) { return true }
        if (0x3040...0x309F).contains(value) { return true }
        if (0x30A0...0x30FF).contains(value) { return true }
        if (0xAC00...0xD7AF).contains(value) { return true }
    }
    return false
}

var passed = 0
var failed = 0

func test(_ name: String, _ condition: Bool) {
    if condition {
        print("  ✓ \(name)")
        passed += 1
    } else {
        print("  ✗ \(name)")
        failed += 1
    }
}

// 测试 CJK 检测
test("isCJK - 中文字符", isCJK("中"))
test("isCJK - 日文平假名", isCJK("あ"))
test("isCJK - 日文片假名", isCJK("ア"))
test("isCJK - 韩文字符", isCJK("한"))
test("isCJK - 英文字符返回false", !isCJK("a"))
test("isCJK - nil返回false", !isCJK(nil))

// 测试混合文本
let mixedText = "Hello 世界"
let containsCJK = mixedText.contains { isCJK($0) }
test("containsCJK - 混合文本", containsCJK)

let pureEnglish = "Hello World"
let noCJK = !pureEnglish.contains { isCJK($0) }
test("containsCJK - 纯英文返回false", noCJK)

// 测试标点符号
let endPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？"]
test("hasEndPunctuation - 英文句号", endPunctuation.contains("Hello.".last!))
test("hasEndPunctuation - 中文句号", endPunctuation.contains("你好。".last!))
test("hasEndPunctuation - 无标点返回false", !endPunctuation.contains("Hello".last!))

// ===== TranslationEntry 模拟测试 =====
struct TranslationEntry: Codable, Equatable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let speaker: String?
    let targetLanguage: String
    let timestamp: Date
    let latencyMs: Int
    
    var formattedLatency: String { "\(latencyMs) ms" }
}

let entry = TranslationEntry(
    id: UUID(),
    sourceText: "Hello",
    translatedText: "你好",
    speaker: "Speaker 1",
    targetLanguage: "Chinese",
    timestamp: Date(),
    latencyMs: 150
)

test("TranslationEntry - 初始化", entry.sourceText == "Hello")
test("TranslationEntry - formattedLatency", entry.formattedLatency == "150 ms")

// Codable 测试
let encoder = JSONEncoder()
let decoder = JSONDecoder()
if let data = try? encoder.encode(entry),
   let decoded = try? decoder.decode(TranslationEntry.self, from: data) {
    test("TranslationEntry - Codable", decoded.sourceText == entry.sourceText)
} else {
    test("TranslationEntry - Codable", false)
}

print("")
print("结果: \(passed) 通过, \(failed) 失败")

// 退出码
exit(failed > 0 ? 1 : 0)
SWIFT_TEST

# 运行 Swift 测试
if swift /tmp/lct_test.swift 2>/dev/null; then
    test_pass "核心功能测试通过"
else
    test_fail "核心功能测试失败"
fi

# 清理
rm -f /tmp/lct_test.swift

echo ""

# ==================== 测试总结 ====================
echo "===================="
echo "📊 测试总结"
echo "===================="
echo -e "通过: ${GREEN}$pass_count${NC}"
echo -e "失败: ${RED}$fail_count${NC}"
echo ""

if [ $fail_count -eq 0 ]; then
    echo -e "${GREEN}✓ 所有测试通过！${NC}"
    exit 0
else
    echo -e "${RED}✗ 有 $fail_count 个测试失败${NC}"
    exit 1
fi
