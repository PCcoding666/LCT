import Foundation
import Combine

/// Caption model for managing original and translated text
/// Similar to Windows version's Caption.cs
@MainActor
class Caption: ObservableObject {
    // MARK: - Singleton
    private static var _instance: Caption?
    
    static var shared: Caption {
        if _instance == nil {
            _instance = Caption()
        }
        return _instance!
    }
    
    // MARK: - Published Properties
    
    /// Original caption text (full text)
    @Published var originalCaption: String = ""
    
    /// Translated caption text (full text)
    @Published var translatedCaption: String = ""
    
    /// Display version of original caption (may be truncated)
    @Published var displayOriginalCaption: String = ""
    
    /// Display version of translated caption
    @Published var displayTranslatedCaption: String = ""
    
    /// Overlay version of original caption
    @Published var overlayOriginalCaption: String = ""
    
    /// Overlay version of translated caption
    @Published var overlayTranslatedCaption: String = ""
    
    // MARK: - Context Management
    
    /// Recent translation history for context-aware translation
    private(set) var contexts: [TranslationEntry] = []
    
    /// Maximum context entries to keep
    var maxContextEntries: Int = 6
    
    /// Get contexts in reverse order (most recent first) for display
    var displayContexts: [TranslationEntry] {
        contexts.reversed()
    }
    
    // MARK: - Computed Properties
    
    /// Get previous captions concatenated (for context display)
    func getPreviousCaption(count: Int) -> String {
        guard count > 0 else { return "" }
        
        let entries = Array(displayContexts.prefix(count).reversed())
        guard !entries.isEmpty else { return "" }
        
        var result = entries
            .map { $0.sourceText }
            .reduce("") { accumulated, current in
                var acc = accumulated
                if !acc.isEmpty {
                    // Add appropriate punctuation based on language
                    if !TextUtils.hasEndPunctuation(acc) {
                        acc += TextUtils.isCJK(acc.last) ? "。" : ". "
                    }
                }
                return acc + current
            }
        
        // Ensure ends with punctuation
        if !result.isEmpty && !TextUtils.hasEndPunctuation(result) {
            result += TextUtils.isCJK(result.last) ? "。" : "."
        }
        
        // Add space for non-CJK text
        if !result.isEmpty, let lastChar = result.last, !TextUtils.isCJK(lastChar) {
            result += " "
        }
        
        return result
    }
    
    /// Get previous translations concatenated (for overlay display)
    func getPreviousTranslation(count: Int) -> String {
        guard count > 0 else { return "" }
        
        let entries = Array(displayContexts.prefix(count).reversed())
        guard !entries.isEmpty else { return "" }
        
        var result = entries
            .map { entry -> String in
                // Skip error messages
                if entry.translatedText.contains("[ERROR]") || entry.translatedText.contains("[WARNING]") {
                    return ""
                }
                return entry.translatedText
            }
            .filter { !$0.isEmpty }
            .reduce("") { accumulated, current in
                var acc = accumulated
                if !acc.isEmpty {
                    if !TextUtils.hasEndPunctuation(acc) {
                        acc += TextUtils.isCJK(acc.last) ? "。" : ". "
                    }
                }
                return acc + current
            }
        
        // Ensure ends with punctuation
        if !result.isEmpty && !TextUtils.hasEndPunctuation(result) {
            result += TextUtils.isCJK(result.last) ? "。" : "."
        }
        
        // Add space for non-CJK text
        if !result.isEmpty, let lastChar = result.last, !TextUtils.isCJK(lastChar) {
            result += " "
        }
        
        return result
    }
    
    // MARK: - Methods
    
    /// Update the original caption
    func updateOriginal(_ text: String) {
        originalCaption = text
        displayOriginalCaption = text
        overlayOriginalCaption = text
    }
    
    /// Update the translated caption
    func updateTranslation(_ text: String) {
        translatedCaption = text
        displayTranslatedCaption = text
        overlayTranslatedCaption = text
    }
    
    /// Add a completed translation to context
    func addToContext(_ entry: TranslationEntry) {
        contexts.append(entry)
        
        // Keep context size limited
        while contexts.count > maxContextEntries {
            contexts.removeFirst()
        }
    }

    /// Remove context entries that were created from rolled-back ASR text.
    func removeContextEntries(withIds ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        contexts.removeAll { ids.contains($0.id) }
    }
    
    /// Get context entries for translation (oldest first)
    func getContextForTranslation() -> [TranslationEntry] {
        return contexts
    }
    
    /// Clear all captions and context
    func clear() {
        originalCaption = ""
        translatedCaption = ""
        displayOriginalCaption = ""
        displayTranslatedCaption = ""
        overlayOriginalCaption = ""
        overlayTranslatedCaption = ""
        contexts.removeAll()
    }
    
    /// Reset singleton (for testing)
    static func reset() {
        _instance = nil
    }
}
