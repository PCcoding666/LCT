import Foundation

/// Speech recognition engine type
enum SpeechEngine: String, Codable, CaseIterable, Identifiable {
    case whisper = "whisper"
    case speechAnalyzer = "speechAnalyzer"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .whisper:
            return "Whisper + Pyannote (Speaker Diarization)"
        case .speechAnalyzer:
            return "Apple SpeechAnalyzer (macOS 26+)"
        }
    }
    
    var description: String {
        switch self {
        case .whisper:
            return "Open source, supports speaker diarization, requires Python"
        case .speechAnalyzer:
            return "Native Apple API, faster but requires macOS 26+"
        }
    }
}

/// Whisper model size options
enum WhisperModelSize: String, Codable, CaseIterable, Identifiable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case large = "large"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .tiny: return "Tiny (39MB)"
        case .base: return "Base (74MB) - Recommended"
        case .small: return "Small (244MB)"
        case .medium: return "Medium (769MB)"
        case .large: return "Large (1.5GB)"
        }
    }
    
    var estimatedMemoryGB: Double {
        switch self {
        case .tiny: return 1.0
        case .base: return 1.0
        case .small: return 2.0
        case .medium: return 5.0
        case .large: return 10.0
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
}

/// Application settings model
struct AppSettings: Codable, Equatable {
    // MARK: - Audio Settings
    var captureSystemAudio: Bool = true
    var captureMicrophone: Bool = true
    
    // MARK: - Speech Recognition Settings
    var preferredEngine: SpeechEngine = .whisper
    var whisperModelSize: WhisperModelSize = .base
    var enableDiarization: Bool = true
    
    // MARK: - Ollama Settings
    var ollamaHost: String = "localhost"
    var ollamaPort: Int = 11434
    var ollamaModel: String = "qwen2.5:3b"
    var ollamaTimeout: Int = 30
    var ollamaTemperature: Double = 0.3
    
    // MARK: - Translation Settings
    var targetLanguage: TargetLanguage = .chinese
    var contextAware: Bool = true
    var maxContextEntries: Int = 5
    
    // MARK: - UI Settings
    var showOverlay: Bool = true
    var overlayOpacity: Double = 0.85
    var overlayFontSize: Double = 14.0
    var showLatency: Bool = true
    var maxDisplayCards: Int = 5
    
    // MARK: - Advanced Settings
    var pythonPath: String = "/usr/bin/python3"
    var huggingFaceToken: String = ""
    
    // MARK: - Computed Properties
    
    var ollamaURL: String {
        "http://\(ollamaHost):\(ollamaPort)"
    }
    
    var ollamaAPIEndpoint: String {
        "\(ollamaURL)/api/chat"
    }
    
    // MARK: - Persistence
    
    private static let settingsKey = "LCTMacSettings"
    
    /// Save settings to UserDefaults
    func save() {
        if let encoded = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(encoded, forKey: Self.settingsKey)
        }
    }
    
    /// Load settings from UserDefaults
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }
    
    /// Reset to default settings
    static func reset() -> AppSettings {
        let defaultSettings = AppSettings()
        defaultSettings.save()
        return defaultSettings
    }
}

// MARK: - Translation Prompt Template

extension AppSettings {
    /// Get the system prompt for Ollama translation
    var translationPrompt: String {
        """
        You are a professional translator. Translate the following text to \(targetLanguage.displayName).
        
        Rules:
        1. Only output the translation, no explanations
        2. Maintain the original meaning and tone
        3. Keep proper nouns unchanged when appropriate
        4. Handle informal speech naturally
        5. If the text is already in \(targetLanguage.displayName), output it unchanged
        
        Translate:
        """
    }
}
