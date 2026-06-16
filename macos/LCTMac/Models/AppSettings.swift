import Foundation
import AppKit

/// Supported source languages for speech recognition
enum SourceLanguage: String, Codable, CaseIterable, Identifiable {
    case english = "en-US"
    case englishUK = "en-GB"
    case chinese = "zh-CN"
    case chineseTW = "zh-TW"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case spanish = "es-ES"
    case french = "fr-FR"
    case german = "de-DE"
    case russian = "ru-RU"
    case portuguese = "pt-BR"
    case italian = "it-IT"
    case arabic = "ar-SA"
    case hindi = "hi-IN"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English (US)"
        case .englishUK: return "English (UK)"
        case .chinese: return "Chinese (Simplified)"
        case .chineseTW: return "Chinese (Traditional)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .russian: return "Russian"
        case .portuguese: return "Portuguese (Brazil)"
        case .italian: return "Italian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    /// ISO 639-1 language code for TranslateGemma
    var isoCode: String {
        switch self {
        case .english, .englishUK: return "en"
        case .chinese, .chineseTW: return "zh"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .russian: return "ru"
        case .portuguese: return "pt"
        case .italian: return "it"
        case .arabic: return "ar"
        case .hindi: return "hi"
        }
    }
}

/// Supported target languages for translation
enum TargetLanguage: String, Codable, CaseIterable, Identifiable {
    case chinese = "Chinese"
    case english = "English"
    case japanese = "Japanese"
    case korean = "Korean"
    case spanish = "Spanish"
    case french = "French"
    case german = "German"
    case russian = "Russian"
    case arabic = "Arabic"
    case portuguese = "Portuguese"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var nativeName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .russian: return "Русский"
        case .arabic: return "العربية"
        case .portuguese: return "Português"
        }
    }

    /// ISO 639-1 language code for TranslateGemma
    var isoCode: String {
        switch self {
        case .chinese: return "zh"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .russian: return "ru"
        case .arabic: return "ar"
        case .portuguese: return "pt"
        }
    }
}

/// Translation model type
enum TranslationModelType: String, Codable, CaseIterable, Identifiable {
    case standard = "standard"          // Standard chat models
    case translateGemma = "translategemma"  // Google TranslateGemma model

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard (Chat)"
        case .translateGemma: return "TranslateGemma"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Use general chat models with translation prompts"
        case .translateGemma: return "Google's specialized translation model (55 languages)"
        }
    }
}

enum AppSettingsPersistenceError: LocalizedError {
    case saveFailed(Error)
    case loadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let error):
            return "Settings save failed: \(error.localizedDescription)"
        case .loadFailed(let error):
            return "Settings load failed. Defaults were restored: \(error.localizedDescription)"
        }
    }
}

/// Application settings model
struct AppSettings: Codable, Equatable {
    // MARK: - Audio Settings
    var captureSystemAudio: Bool = true
    var captureMicrophone: Bool = true

    // MARK: - Speech Recognition Settings
    var sourceLanguage: SourceLanguage = .english

    // MARK: - Ollama Settings
    var ollamaHost: String = "localhost"
    var ollamaPort: Int = 11434
    var ollamaModel: String = "qwen3.5:4b-mlx"
    var ollamaTimeout: Int = 30
    var ollamaTemperature: Double = 0.3

    // MARK: - Translation Settings
    var targetLanguage: TargetLanguage = .chinese
    var translationModelType: TranslationModelType = .standard
    var contextAware: Bool = true
    var maxContextEntries: Int = 5
    var customPrompt: String = ""
    /// Translate the in-progress draft (before a sentence finalizes) for lower
    /// perceived latency. Draft translations are transient and shown in the live
    /// area only — they never enter history or translation context.
    var liveDraftTranslation: Bool = true

    // MARK: - History Settings
    var historyRetentionDays: Int = 30
    var historyMaxEntries: Int = 5000

    // MARK: - UI Settings
    var overlayOpacity: Double = 0.85
    var overlayFontSize: Double = 14.0
    var showLatency: Bool = true
    var maxDisplayCards: Int = 5

    // MARK: - Overlay Advanced Settings
    var overlayPositionX: Double = 0.0
    var overlayPositionY: Double = 0.0
    var overlayWidth: Double = 400.0
    var overlayHeight: Double = 200.0
    var overlayClickThrough: Bool = false
    var overlayStayOnTop: Bool = true

    // MARK: - Computed Properties

    var ollamaURL: String {
        "http://\(ollamaHost):\(ollamaPort)"
    }

    var ollamaAPIEndpoint: String {
        "\(ollamaURL)/api/chat"
    }

    var isLocalOllama: Bool {
        let host = ollamaHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
    }

    // MARK: - Persistence

    private static let settingsKey = "LCTMacSettings"
    private static let setupCompleteKey = "LCTMacSetupComplete"
    nonisolated(unsafe) private static var lastPersistenceError: String?

    /// Check if initial setup has been completed
    static var hasCompletedSetup: Bool {
        UserDefaults.standard.bool(forKey: setupCompleteKey)
    }

    /// Mark initial setup as complete
    static func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: setupCompleteKey)
    }

    /// Reset setup flag (for testing)
    static func resetSetupFlag() {
        UserDefaults.standard.removeObject(forKey: setupCompleteKey)
    }

    /// Save settings to UserDefaults
    @discardableResult
    func save() -> Bool {
        do {
            let encoded = try JSONEncoder().encode(self)
            UserDefaults.standard.set(encoded, forKey: Self.settingsKey)
            Self.lastPersistenceError = nil
            return true
        } catch {
            let message = AppSettingsPersistenceError.saveFailed(error).localizedDescription
            Self.lastPersistenceError = message
            appLog("[AppSettings] \(message)")
            return false
        }
    }

    /// Load settings from UserDefaults
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else {
            lastPersistenceError = nil
            return AppSettings()
        }

        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            lastPersistenceError = nil
            return settings
        } catch {
            let message = AppSettingsPersistenceError.loadFailed(error).localizedDescription
            lastPersistenceError = message
            appLog("[AppSettings] \(message)")
            return AppSettings()
        }
    }

    /// Consume the latest load/save persistence error for UI presentation.
    static func consumeLastPersistenceError() -> String? {
        let message = lastPersistenceError
        lastPersistenceError = nil
        return message
    }

    /// Reset to default settings
    static func reset() -> AppSettings {
        let defaultSettings = AppSettings()
        defaultSettings.save()
        return defaultSettings
    }

}

// MARK: - Hex Color Extension

extension NSColor {
    /// Create NSColor from hex string
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        let r, g, b, a: Double

        if length == 6 {
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else if length == 8 {
            r = Double((rgb & 0xFF000000) >> 24) / 255.0
            g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            b = Double((rgb & 0x0000FF00) >> 8) / 255.0
            a = Double(rgb & 0x000000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// Convert NSColor to hex string
    func toHexString() -> String {
        guard let components = cgColor.components, components.count >= 3 else {
            return "#FFFFFF"
        }

        let r = Int(round(components[0] * 255))
        let g = Int(round(components[1] * 255))
        let b = Int(round(components[2] * 255))

        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Translation Prompt Template

extension AppSettings {
    /// Default translation prompt
    static let defaultPrompt = """
        You are a professional simultaneous interpreter. Translate the text enclosed in 🔤 markers to {TARGET_LANGUAGE}.

        CRITICAL RULES:
        1. Output ONLY the translated text, never the original text
        2. Handle incomplete sentences naturally and professionally
        3. Preserve technical terms, company names, and proper nouns accurately
        4. Maintain appropriate tone and formality
        5. For unclear speech, provide the most likely interpretation

        OUTPUT FORMAT: Single line translation only, remove all 🔤 markers, no explanations.
        """

    /// Get the system prompt for Ollama translation
    var translationPrompt: String {
        let template = customPrompt.isEmpty ? Self.defaultPrompt : customPrompt
        return template.replacingOccurrences(of: "{TARGET_LANGUAGE}", with: targetLanguage.displayName)
    }
}
