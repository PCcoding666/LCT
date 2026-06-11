import Foundation

/// Represents a translation entry with source and translated text
struct TranslationEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let speaker: String?
    let targetLanguage: String
    let timestamp: Date
    let latencyMs: Int

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        speaker: String? = nil,
        targetLanguage: String,
        timestamp: Date = Date(),
        latencyMs: Int = 0
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.speaker = speaker
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.latencyMs = latencyMs
    }

    /// Formatted latency for display
    var formattedLatency: String {
        "\(latencyMs) ms"
    }

    /// Formatted timestamp for display
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}

/// Translation history container
struct TranslationHistory: Codable {
    var entries: [TranslationEntry]

    init(entries: [TranslationEntry] = []) {
        self.entries = entries
    }

    /// Add a new entry to history
    mutating func add(_ entry: TranslationEntry) {
        entries.append(entry)
    }

    /// Get entries for a specific date range
    func entries(from startDate: Date, to endDate: Date) -> [TranslationEntry] {
        entries.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Search entries by text
    func search(_ query: String) -> [TranslationEntry] {
        let lowercasedQuery = query.lowercased()
        return entries.filter {
            $0.sourceText.lowercased().contains(lowercasedQuery) ||
            $0.translatedText.lowercased().contains(lowercasedQuery)
        }
    }

    /// Export to CSV format
    func exportToCSV() -> String {
        var csv = "ID,Source Text,Translated Text,Speaker,Target Language,Timestamp,Latency (ms)\n"
        for entry in entries {
            let row = [
                csvEscape(entry.id.uuidString),
                csvEscape(entry.sourceText),
                csvEscape(entry.translatedText),
                csvEscape(entry.speaker ?? ""),
                csvEscape(entry.targetLanguage),
                csvEscape(entry.formattedTimestamp),
                String(entry.latencyMs)
            ].joined(separator: ",")
            csv += "\(row)\n"
        }
        return csv
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
