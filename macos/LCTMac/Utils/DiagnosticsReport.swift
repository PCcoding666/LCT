import Foundation

/// Builds the diagnostics export. Metadata-only by contract: no raw log lines,
/// no transcripts, no translations, no text-derived data.
enum DiagnosticsReport {
    static func build(
        appVersion: String,
        buildNumber: String,
        osVersion: String,
        microphoneStatus: String,
        speechStatus: String,
        screenRecordingGranted: Bool,
        ollamaURL: String,
        ollamaIsLocal: Bool,
        modelName: String,
        modelType: String,
        sourceLanguage: String,
        targetLanguage: String,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        ollamaStatus: String,
        ollamaVersion: String,
        installedModels: [String],
        historyEnabled: Bool,
        historyEntryCount: Int
    ) -> String {
        let historyLine = historyEnabled
            ? "History: enabled (\(historyEntryCount) entries)"
            : "History: disabled (\(historyEntryCount) entries retained)"

        let lines = [
            "LCT Diagnostics Report (metadata only)",
            "Generated: \(Date().formatted(.iso8601))",
            "This report contains settings and status metadata only.",
            "It never includes transcripts, translations, or log content.",
            "",
            "== App ==",
            "Version: \(appVersion) (\(buildNumber))",
            "macOS: \(osVersion)",
            "",
            "== Permissions ==",
            "Microphone: \(microphoneStatus)",
            "Speech Recognition: \(speechStatus)",
            "Screen Recording: \(screenRecordingGranted ? "granted" : "not granted")",
            "",
            "== Configuration ==",
            "Ollama: \(ollamaURL) (\(ollamaIsLocal ? "local" : "remote"))",
            "Model: \(modelName) [\(modelType)]",
            "Languages: \(sourceLanguage) → \(targetLanguage)",
            "Capture: systemAudio=\(captureSystemAudio) microphone=\(captureMicrophone)",
            historyLine,
            "",
            "== Ollama ==",
            "Status: \(ollamaStatus)",
            "Version: \(ollamaVersion)",
            "Installed models: \(installedModels.isEmpty ? "(none / unreachable)" : installedModels.joined(separator: ", "))",
        ]
        return lines.joined(separator: "\n")
    }
}
