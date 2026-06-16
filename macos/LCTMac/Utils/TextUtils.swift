import Foundation

/// Text utility functions for caption processing
/// Similar to Windows version's TextUtil.cs
enum TextUtils {
    // MARK: - Punctuation
    
    /// End-of-sentence punctuation marks
    static let endOfSentencePunctuation: Set<Character> = [
        ".", "!", "?",
        "\u{3002}", "\u{FF01}", "\u{FF1F}",  // 。！？
        "\u{FF0E}", "\u{FF61}",               // ．｡
        "\u{2026}", "\u{2025}",               // … ‥
    ]
    
    /// All punctuation marks
    static let allPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "\"",
        "\u{3002}", "\u{FF0C}", "\u{FF01}", "\u{FF1F}", "\u{FF1B}", "\u{FF1A}",  // 。，！？；：
        "\u{3001}",                                                              // 、
        "\u{FF0E}", "\u{FF61}", "\u{FF64}",                                      // ．｡､
        "\u{2026}", "\u{2025}", "\u{2014}", "\u{2013}",                          // … ‥ — –
    ]
    
    // MARK: - CJK Detection
    
    /// Check if a character is a CJK character
    static func isCJK(_ char: Character?) -> Bool {
        guard let char = char else { return false }
        
        for scalar in char.unicodeScalars {
            let value = scalar.value
            
            // CJK Unified Ideographs
            if (0x4E00...0x9FFF).contains(value) { return true }
            // CJK Extension A
            if (0x3400...0x4DBF).contains(value) { return true }
            // CJK Extension B
            if (0x20000...0x2A6DF).contains(value) { return true }
            // CJK Compatibility Ideographs
            if (0xF900...0xFAFF).contains(value) { return true }
            // Hiragana
            if (0x3040...0x309F).contains(value) { return true }
            // Katakana
            if (0x30A0...0x30FF).contains(value) { return true }
            // Hangul Syllables
            if (0xAC00...0xD7AF).contains(value) { return true }
            // Hangul Jamo
            if (0x1100...0x11FF).contains(value) { return true }
        }
        
        return false
    }
    
    /// Check if a string contains CJK characters
    static func containsCJK(_ text: String) -> Bool {
        text.contains { isCJK($0) }
    }
    
    /// Check if a string is primarily CJK
    static func isPrimarilyCJK(_ text: String) -> Bool {
        let cjkCount = text.filter { isCJK($0) }.count
        let totalChars = text.filter { !$0.isWhitespace }.count
        guard totalChars > 0 else { return false }
        return Double(cjkCount) / Double(totalChars) > 0.5
    }
    
    // MARK: - Punctuation Processing
    
    /// Check if a string ends with sentence-ending punctuation
    static func hasEndPunctuation(_ text: String) -> Bool {
        guard let lastChar = text.last else { return false }
        return endOfSentencePunctuation.contains(lastChar)
    }
    
    /// Add appropriate end punctuation if missing
    static func ensureEndPunctuation(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        guard !hasEndPunctuation(text) else { return text }
        
        if let lastChar = text.last, isCJK(lastChar) {
            return text + "\u{3002}"  // 。
        } else {
            return text + "."
        }
    }
    
    /// Get appropriate sentence separator based on text content
    static func getSeparator(for text: String) -> String {
        if isPrimarilyCJK(text) {
            return "\u{3002}"  // 。
        } else {
            return ". "
        }
    }
    
    // MARK: - Text Processing
    
    /// Clean up translation output
    /// Removes markers and extra whitespace
    static func cleanTranslationOutput(_ text: String) -> String {
        var result = text
        
        // Remove markers if present
        result = result.replacingOccurrences(of: "\u{1F524}", with: "")  // 🔤
        
        // Remove common prefixes that models sometimes add
        let prefixesToRemove = [
            "Translation:",
            "翻译：",
            "译文：",
            "Here is the translation:",
            "The translation is:",
        ]
        
        for prefix in prefixesToRemove {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count))
            }
        }
        
        // Trim whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result
    }
    
    /// Format text for display (handles long text)
    static func formatForDisplay(_ text: String, maxLength: Int = 500) -> String {
        guard text.count > maxLength else { return text }
        
        let truncated = String(text.prefix(maxLength))
        
        // Try to truncate at a sentence boundary
        if let lastSentenceEnd = truncated.lastIndex(where: { endOfSentencePunctuation.contains($0) }) {
            return String(truncated[...lastSentenceEnd])
        }
        
        // Or at a word boundary
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }
        
        return truncated + "..."
    }
    
    /// Concatenate sentences with proper punctuation
    static func concatenateSentences(_ sentences: [String]) -> String {
        guard !sentences.isEmpty else { return "" }
        
        return sentences.reduce("") { accumulated, current in
            guard !current.isEmpty else { return accumulated }
            
            var result = accumulated
            
            if !result.isEmpty {
                // Add separator if needed
                if !hasEndPunctuation(result) {
                    result += getSeparator(for: result)
                } else if !isCJK(result.last) {
                    result += " "
                }
            }
            
            return result + current
        }
    }
    
    /// Check if text appears to be a complete sentence
    static func isCompleteSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return hasEndPunctuation(trimmed)
    }
    
    /// Extract the last complete sentence from text
    static func extractLastSentence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // Find sentence boundaries
        var lastBoundary: String.Index?
        var secondLastBoundary: String.Index?
        
        for i in trimmed.indices {
            if endOfSentencePunctuation.contains(trimmed[i]) {
                secondLastBoundary = lastBoundary
                lastBoundary = i
            }
        }
        
        if let last = lastBoundary {
            let startIndex = secondLastBoundary.map { trimmed.index(after: $0) } ?? trimmed.startIndex
            return String(trimmed[startIndex...last]).trimmingCharacters(in: .whitespaces)
        }
        
        return nil
    }
}