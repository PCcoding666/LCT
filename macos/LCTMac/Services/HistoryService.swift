import Foundation
import SQLite

/// Service for persisting translation history to SQLite
class HistoryService {
    private var db: Connection?
    private let translationsTable = Table("translations")
    
    // Table columns
    private let id = Expression<String>("id")
    private let sourceText = Expression<String>("source_text")
    private let translatedText = Expression<String>("translated_text")
    private let speaker = Expression<String?>("speaker")
    private let targetLanguage = Expression<String>("target_language")
    private let timestamp = Expression<Date>("timestamp")
    private let latencyMs = Expression<Int>("latency_ms")
    
    // MARK: - Initialization
    
    init() {
        do {
            db = try createConnection()
            try createTables()
        } catch {
            print("Failed to initialize HistoryService: \(error)")
        }
    }
    
    private func createConnection() throws -> Connection {
        let path = getDBPath()
        
        // Ensure directory exists
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        
        return try Connection(path)
    }
    
    private func getDBPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("LCT")
        return appDirectory.appendingPathComponent("history.sqlite").path
    }
    
    private func createTables() throws {
        guard let db = db else { return }
        
        try db.run(translationsTable.create(ifNotExists: true) { t in
            t.column(id, primaryKey: true)
            t.column(sourceText)
            t.column(translatedText)
            t.column(speaker)
            t.column(targetLanguage)
            t.column(timestamp)
            t.column(latencyMs)
        })
        
        // Create index for faster queries
        try db.run(translationsTable.createIndex(timestamp, ifNotExists: true))
    }
    
    // MARK: - CRUD Operations
    
    /// Log a new translation
    func logTranslation(_ entry: TranslationEntry) throws {
        guard let db = db else { return }
        
        try db.run(translationsTable.insert(
            id <- entry.id.uuidString,
            sourceText <- entry.sourceText,
            translatedText <- entry.translatedText,
            speaker <- entry.speaker,
            targetLanguage <- entry.targetLanguage,
            timestamp <- entry.timestamp,
            latencyMs <- entry.latencyMs
        ))
    }
    
    /// Load all translations
    func loadAllTranslations() throws -> [TranslationEntry] {
        guard let db = db else { return [] }
        
        var entries: [TranslationEntry] = []
        
        for row in try db.prepare(translationsTable.order(timestamp.desc)) {
            let entry = TranslationEntry(
                id: UUID(uuidString: row[id]) ?? UUID(),
                sourceText: row[sourceText],
                translatedText: row[translatedText],
                speaker: row[speaker],
                targetLanguage: row[targetLanguage],
                timestamp: row[timestamp],
                latencyMs: row[latencyMs]
            )
            entries.append(entry)
        }
        
        return entries
    }
    
    /// Load recent translations
    func loadRecentTranslations(limit: Int = 100) throws -> [TranslationEntry] {
        guard let db = db else { return [] }
        
        var entries: [TranslationEntry] = []
        
        let query = translationsTable
            .order(timestamp.desc)
            .limit(limit)
        
        for row in try db.prepare(query) {
            let entry = TranslationEntry(
                id: UUID(uuidString: row[id]) ?? UUID(),
                sourceText: row[sourceText],
                translatedText: row[translatedText],
                speaker: row[speaker],
                targetLanguage: row[targetLanguage],
                timestamp: row[timestamp],
                latencyMs: row[latencyMs]
            )
            entries.append(entry)
        }
        
        return entries
    }
    
    /// Load translations within date range
    func loadTranslations(from startDate: Date, to endDate: Date) throws -> [TranslationEntry] {
        guard let db = db else { return [] }
        
        var entries: [TranslationEntry] = []
        
        let query = translationsTable
            .filter(timestamp >= startDate && timestamp <= endDate)
            .order(timestamp.desc)
        
        for row in try db.prepare(query) {
            let entry = TranslationEntry(
                id: UUID(uuidString: row[id]) ?? UUID(),
                sourceText: row[sourceText],
                translatedText: row[translatedText],
                speaker: row[speaker],
                targetLanguage: row[targetLanguage],
                timestamp: row[timestamp],
                latencyMs: row[latencyMs]
            )
            entries.append(entry)
        }
        
        return entries
    }
    
    /// Search translations
    func searchTranslations(query searchQuery: String) throws -> [TranslationEntry] {
        guard let db = db else { return [] }
        
        var entries: [TranslationEntry] = []
        let pattern = "%\(searchQuery)%"
        
        let query = translationsTable
            .filter(sourceText.like(pattern) || translatedText.like(pattern))
            .order(timestamp.desc)
        
        for row in try db.prepare(query) {
            let entry = TranslationEntry(
                id: UUID(uuidString: row[id]) ?? UUID(),
                sourceText: row[sourceText],
                translatedText: row[translatedText],
                speaker: row[speaker],
                targetLanguage: row[targetLanguage],
                timestamp: row[timestamp],
                latencyMs: row[latencyMs]
            )
            entries.append(entry)
        }
        
        return entries
    }
    
    /// Delete a translation
    func deleteTranslation(withId entryId: UUID) throws {
        guard let db = db else { return }
        
        let entry = translationsTable.filter(id == entryId.uuidString)
        try db.run(entry.delete())
    }
    
    /// Delete the last translation
    func deleteLastTranslation() throws {
        guard let db = db else { return }
        
        let lastEntry = translationsTable
            .order(timestamp.desc)
            .limit(1)
        
        if let row = try db.pluck(lastEntry) {
            let entryId = row[id]
            try db.run(translationsTable.filter(id == entryId).delete())
        }
    }
    
    /// Get the last translation
    func getLastTranslation() throws -> TranslationEntry? {
        guard let db = db else { return nil }
        
        let query = translationsTable
            .order(timestamp.desc)
            .limit(1)
        
        guard let row = try db.pluck(query) else { return nil }
        
        return TranslationEntry(
            id: UUID(uuidString: row[id]) ?? UUID(),
            sourceText: row[sourceText],
            translatedText: row[translatedText],
            speaker: row[speaker],
            targetLanguage: row[targetLanguage],
            timestamp: row[timestamp],
            latencyMs: row[latencyMs]
        )
    }
    
    /// Get last source text
    func getLastSourceText() throws -> String? {
        guard let db = db else { return nil }
        
        let query = translationsTable
            .select(sourceText)
            .order(timestamp.desc)
            .limit(1)
        
        guard let row = try db.pluck(query) else { return nil }
        return row[sourceText]
    }
    
    /// Clear all history
    func clearHistory() throws {
        guard let db = db else { return }
        try db.run(translationsTable.delete())
    }
    
    /// Get total count
    func getCount() throws -> Int {
        guard let db = db else { return 0 }
        return try db.scalar(translationsTable.count)
    }
    
    /// Export to CSV
    func exportToCSV() throws -> String {
        let entries = try loadAllTranslations()
        let history = TranslationHistory(entries: entries)
        return history.exportToCSV()
    }
}

// MARK: - Async Wrapper

extension HistoryService {
    /// Async version of logTranslation
    func logTranslationAsync(_ entry: TranslationEntry) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    try self.logTranslation(entry)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Async version of loadRecentTranslations
    func loadRecentTranslationsAsync(limit: Int = 100) async throws -> [TranslationEntry] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    let entries = try self.loadRecentTranslations(limit: limit)
                    continuation.resume(returning: entries)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
