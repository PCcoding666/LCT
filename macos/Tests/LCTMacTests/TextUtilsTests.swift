
import XCTest
@testable import LCTMac

/// Tests for TextUtils
final class TextUtilsTests: XCTestCase {

    // MARK: - CJK Detection Tests

    func testIsCJK_ChineseCharacter_ReturnsTrue() {
        XCTAssertTrue(TextUtils.isCJK("中"))
        XCTAssertTrue(TextUtils.isCJK("文"))
        XCTAssertTrue(TextUtils.isCJK("国"))
    }

    func testIsCJK_JapaneseHiragana_ReturnsTrue() {
        XCTAssertTrue(TextUtils.isCJK("あ"))
        XCTAssertTrue(TextUtils.isCJK("い"))
    }

    func testIsCJK_JapaneseKatakana_ReturnsTrue() {
        XCTAssertTrue(TextUtils.isCJK("ア"))
        XCTAssertTrue(TextUtils.isCJK("イ"))
    }

    func testIsCJK_KoreanCharacter_ReturnsTrue() {
        XCTAssertTrue(TextUtils.isCJK("한"))
        XCTAssertTrue(TextUtils.isCJK("국"))
    }

    func testIsCJK_EnglishCharacter_ReturnsFalse() {
        XCTAssertFalse(TextUtils.isCJK("a"))
        XCTAssertFalse(TextUtils.isCJK("Z"))
    }

    func testIsCJK_Nil_ReturnsFalse() {
        XCTAssertFalse(TextUtils.isCJK(nil))
    }

    func testContainsCJK_MixedText_ReturnsTrue() {
        XCTAssertTrue(TextUtils.containsCJK("Hello 世界"))
        XCTAssertTrue(TextUtils.containsCJK("Test中文Test"))
    }

    func testContainsCJK_PureEnglish_ReturnsFalse() {
        XCTAssertFalse(TextUtils.containsCJK("Hello World"))
        XCTAssertFalse(TextUtils.containsCJK("123456"))
    }

    func testIsPrimarilyCJK_MostlyCJK_ReturnsTrue() {
        XCTAssertTrue(TextUtils.isPrimarilyCJK("今天天气很好"))
        XCTAssertTrue(TextUtils.isPrimarilyCJK("中文测试 ok"))
    }

    func testIsPrimarilyCJK_MostlyEnglish_ReturnsFalse() {
        XCTAssertFalse(TextUtils.isPrimarilyCJK("Hello World 你好"))
        XCTAssertFalse(TextUtils.isPrimarilyCJK("This is a test"))
    }

    func testIsPrimarilyCJK_EmptyString_ReturnsFalse() {
        XCTAssertFalse(TextUtils.isPrimarilyCJK(""))
        XCTAssertFalse(TextUtils.isPrimarilyCJK("   "))
    }

    // MARK: - Punctuation Tests

    func testHasEndPunctuation_EnglishPeriod_ReturnsTrue() {
        XCTAssertTrue(TextUtils.hasEndPunctuation("Hello world."))
        XCTAssertTrue(TextUtils.hasEndPunctuation("Question?"))
        XCTAssertTrue(TextUtils.hasEndPunctuation("Exclamation!"))
    }

    func testHasEndPunctuation_ChinesePunctuation_ReturnsTrue() {
        XCTAssertTrue(TextUtils.hasEndPunctuation("你好。"))
        XCTAssertTrue(TextUtils.hasEndPunctuation("什么？"))
        XCTAssertTrue(TextUtils.hasEndPunctuation("好的！"))
    }

    func testHasEndPunctuation_NoPunctuation_ReturnsFalse() {
        XCTAssertFalse(TextUtils.hasEndPunctuation("Hello world"))
        XCTAssertFalse(TextUtils.hasEndPunctuation("你好"))
    }

    func testHasEndPunctuation_EmptyString_ReturnsFalse() {
        XCTAssertFalse(TextUtils.hasEndPunctuation(""))
    }

    func testEnsureEndPunctuation_AddsPeriodToEnglish() {
        XCTAssertEqual(TextUtils.ensureEndPunctuation("Hello world"), "Hello world.")
    }

    func testEnsureEndPunctuation_AddsChinesePeriodToCJK() {
        XCTAssertEqual(TextUtils.ensureEndPunctuation("你好"), "你好。")
    }

    func testEnsureEndPunctuation_DoesNotDuplicatePunctuation() {
        XCTAssertEqual(TextUtils.ensureEndPunctuation("Hello world."), "Hello world.")
        XCTAssertEqual(TextUtils.ensureEndPunctuation("你好。"), "你好。")
    }

    func testEnsureEndPunctuation_EmptyString_ReturnsEmpty() {
        XCTAssertEqual(TextUtils.ensureEndPunctuation(""), "")
    }

    func testGetSeparator_ForCJKText_ReturnsChinesePeriod() {
        XCTAssertEqual(TextUtils.getSeparator(for: "今天天气很好"), "。")
    }

    func testGetSeparator_ForEnglishText_ReturnsPeriodSpace() {
        XCTAssertEqual(TextUtils.getSeparator(for: "Hello world"), ". ")
    }

    // MARK: - Text Processing Tests

    func testCleanTranslationOutput_RemovesMarkers() {
        let input = "🔤Hello World🔤"
        let expected = "Hello World"
        XCTAssertEqual(TextUtils.cleanTranslationOutput(input), expected)
    }

    func testCleanTranslationOutput_RemovesPrefixes() {
        XCTAssertEqual(TextUtils.cleanTranslationOutput("Translation: Hello"), "Hello")
        XCTAssertEqual(TextUtils.cleanTranslationOutput("翻译：你好"), "你好")
        XCTAssertEqual(TextUtils.cleanTranslationOutput("译文：世界"), "世界")
    }

    func testCleanTranslationOutput_TrimsWhitespace() {
        XCTAssertEqual(TextUtils.cleanTranslationOutput("  Hello  "), "Hello")
        XCTAssertEqual(TextUtils.cleanTranslationOutput("\n你好\n"), "你好")
    }

    func testFormatForDisplay_ShortText_ReturnsUnchanged() {
        let text = "Short text"
        XCTAssertEqual(TextUtils.formatForDisplay(text), text)
    }

    func testFormatForDisplay_LongText_Truncates() {
        let longText = String(repeating: "a", count: 600)
        let result = TextUtils.formatForDisplay(longText, maxLength: 500)
        XCTAssertTrue(result.count <= 503) // 500 + "..."
    }

    func testConcatenateSentences_EmptyArray_ReturnsEmpty() {
        XCTAssertEqual(TextUtils.concatenateSentences([]), "")
    }

    func testConcatenateSentences_SingleSentence_ReturnsAsIs() {
        XCTAssertEqual(TextUtils.concatenateSentences(["Hello"]), "Hello")
    }

    func testConcatenateSentences_MultipleSentences_AddsSeparators() {
        let result = TextUtils.concatenateSentences(["Hello", "World"])
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
    }

    func testIsCompleteSentence_WithPunctuation_ReturnsTrue() {
        XCTAssertTrue(TextUtils.isCompleteSentence("Hello world."))
        XCTAssertTrue(TextUtils.isCompleteSentence("你好。"))
    }

    func testIsCompleteSentence_WithoutPunctuation_ReturnsFalse() {
        XCTAssertFalse(TextUtils.isCompleteSentence("Hello world"))
        XCTAssertFalse(TextUtils.isCompleteSentence("你好"))
    }

    func testIsCompleteSentence_EmptyString_ReturnsFalse() {
        XCTAssertFalse(TextUtils.isCompleteSentence(""))
        XCTAssertFalse(TextUtils.isCompleteSentence("   "))
    }

    func testExtractLastSentence_SingleSentence_ReturnsIt() {
        XCTAssertEqual(TextUtils.extractLastSentence("Hello world."), "Hello world.")
    }

    func testExtractLastSentence_MultipleSentences_ReturnsLast() {
        let result = TextUtils.extractLastSentence("First sentence. Second sentence.")
        XCTAssertEqual(result, "Second sentence.")
    }

    func testExtractLastSentence_NoPunctuation_ReturnsNil() {
        XCTAssertNil(TextUtils.extractLastSentence("No punctuation here"))
    }

    func testExtractLastSentence_EmptyString_ReturnsNil() {
        XCTAssertNil(TextUtils.extractLastSentence(""))
    }
}
