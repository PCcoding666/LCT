import Foundation

/// Severity of a user-facing notice. Drives icon, color, and auto-dismiss.
enum NoticeSeverity: Equatable {
    case info     // transient progress / FYI, auto-dismisses
    case warning  // non-blocking issue the user should know about
    case error    // something failed; usually actionable
}

/// A discrete remediation the user can take from a notice. Represented as data
/// (not closures) so AppNotice stays Equatable and the ViewModel owns behavior.
enum NoticeAction: Equatable, Identifiable {
    case openScreenRecordingSettings
    case openMicrophoneSettings
    case openSpeechRecognitionSettings
    case startOllama
    case openAppSettings
    case retryCapture

    var id: String {
        switch self {
        case .openScreenRecordingSettings: return "openScreenRecordingSettings"
        case .openMicrophoneSettings: return "openMicrophoneSettings"
        case .openSpeechRecognitionSettings: return "openSpeechRecognitionSettings"
        case .startOllama: return "startOllama"
        case .openAppSettings: return "openAppSettings"
        case .retryCapture: return "retryCapture"
        }
    }

    var label: String {
        switch self {
        case .openScreenRecordingSettings,
             .openMicrophoneSettings,
             .openSpeechRecognitionSettings:
            return "Open System Settings"
        case .startOllama: return "Start Ollama"
        case .openAppSettings: return "Settings"
        case .retryCapture: return "Retry"
        }
    }
}

/// A structured, user-facing notice. Replaces ad-hoc error strings so the UI can
/// style by severity and surface remediation buttons instead of guessing.
struct AppNotice: Equatable, Identifiable {
    let id = UUID()
    var severity: NoticeSeverity
    var message: String
    var actions: [NoticeAction]
    var autoDismiss: Bool

    init(severity: NoticeSeverity, message: String, actions: [NoticeAction] = [], autoDismiss: Bool = false) {
        self.severity = severity
        self.message = message
        self.actions = actions
        self.autoDismiss = autoDismiss
    }

    // MARK: - Convenience builders

    static func info(_ message: String) -> AppNotice {
        AppNotice(severity: .info, message: message, autoDismiss: true)
    }

    static func warning(_ message: String, autoDismiss: Bool = true) -> AppNotice {
        AppNotice(severity: .warning, message: message, autoDismiss: autoDismiss)
    }

    static func error(_ message: String, actions: [NoticeAction] = []) -> AppNotice {
        AppNotice(severity: .error, message: message, actions: actions)
    }
}
