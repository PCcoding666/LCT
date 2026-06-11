import Foundation
import SQLite

/// Service for persisting translation history to SQLite
final class HistoryService: @unchecked Sendable {
    private var db: Connection?
    private let databasePath: String
    // Dedicated serial queue to enforce strict single-writer/reader concurrency
    private let dbQueue = DispatchQueue(label: "com.lct.history.db", qos: .userInitiated)

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

    init(databasePath: String? = nil) {
        self.databasePath = databasePath ?? Self.defaultDBPath()
        do {
            db = try createConnection()
            try createTables()
        } catch {
            print("Failed to initialize HistoryService: \(error)")
        }
    }

    private func createConnection() throws -> Connection {
        let path = databasePath

        // Ensure directory exists
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        return try Connection(path)
    }

    private static func defaultDBPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("LCT")
        return appDirectory.appendingPathComponent("history.sqlite").path
    }

    private func createTables() throws {
        guard let db = db else { return }

        // Enable WAL mode for better concurrency (readers don't block writers)
        _ = try db.scalar("PRAGMA journal_mode = WAL")
        // Set busy timeout to gracefully handle concurrency
        _ = try db.scalar("PRAGMA busy_timeout = 5000")

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
        try dbQueue.sync {
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
    }

    /// Load all translations
    func loadAllTranslations() throws -> [TranslationEntry] {
        try dbQueue.sync {
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
    }

    /// Load recent translations
    func loadRecentTranslations(limit: Int = 100) throws -> [TranslationEntry] {
        try dbQueue.sync {
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
    }

    /// Load translations within date range
    func loadTranslations(from startDate: Date, to endDate: Date) throws -> [TranslationEntry] {
        try dbQueue.sync {
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
    }

    /// Search translations
    func searchTranslations(query searchQuery: String) throws -> [TranslationEntry] {
        try dbQueue.sync {
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
    }

    /// Delete a translation
    func deleteTranslation(withId entryId: UUID) throws {
        try dbQueue.sync {
            guard let db = db else { return }
            let entry = translationsTable.filter(id == entryId.uuidString)
            try db.run(entry.delete())
        }
    }

    /// Delete the last translation
    func deleteLastTranslation() throws {
        try dbQueue.sync {
            guard let db = db else { return }
            let lastEntry = translationsTable.order(timestamp.desc).limit(1)
            if let row = try db.pluck(lastEntry) {
                let entryId = row[id]
                try db.run(translationsTable.filter(id == entryId).delete())
            }
        }
    }

    /// Get the last translation
    func getLastTranslation() throws -> TranslationEntry? {
        try dbQueue.sync {
            guard let db = db else { return nil }
            let query = translationsTable.order(timestamp.desc).limit(1)
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
    }

    /// Get last source text
    func getLastSourceText() throws -> String? {
        try dbQueue.sync {
            guard let db = db else { return nil }
            let query = translationsTable.select(sourceText).order(timestamp.desc).limit(1)
            guard let row = try db.pluck(query) else { return nil }
            return row[sourceText]
        }
    }

    /// Clear all history
    func clearHistory() throws {
        try dbQueue.sync {
            guard let db = db else { return }
            try db.run(translationsTable.delete())
        }
    }

    /// Apply retention limits to prevent unbounded history growth.
    func pruneHistory(retentionDays: Int, maxEntries: Int) throws {
        try dbQueue.sync {
            guard let db = db else { return }

            if retentionDays > 0,
               let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) {
                try db.run(translationsTable.filter(timestamp < cutoffDate).delete())
            }

            if maxEntries > 0 {
                let orderedIds = try db.prepare(
                    translationsTable
                        .select(id)
                        .order(timestamp.desc)
                ).map { $0[id] }

                guard orderedIds.count > maxEntries else { return }

                for entryId in orderedIds.dropFirst(maxEntries) {
                    try db.run(translationsTable.filter(id == entryId).delete())
                }
            }
        }
    }

    /// Get total count
    func getCount() throws -> Int {
        try dbQueue.sync {
            guard let db = db else { return 0 }
            return try db.scalar(translationsTable.count)
        }
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Dispatch to robust dedicated DB queue asynchronously to not block the caller
            dbQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: NSError(domain: "HistoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service deallocated"]))
                    return
                }
                do {
                    // Do not call self.logTranslation here (which uses sync), do the raw commit directly to avoid deadlock
                    guard let db = self.db else {
                        continuation.resume()
                        return
                    }
                    try db.run(self.translationsTable.insert(
                        self.id <- entry.id.uuidString,
                        self.sourceText <- entry.sourceText,
                        self.translatedText <- entry.translatedText,
                        self.speaker <- entry.speaker,
                        self.targetLanguage <- entry.targetLanguage,
                        self.timestamp <- entry.timestamp,
                        self.latencyMs <- entry.latencyMs
                    ))
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
            dbQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: NSError(domain: "HistoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service deallocated"]))
                    return
                }
                do {
                    guard let db = self.db else {
                        continuation.resume(returning: [])
                        return
                    }
                    var entries: [TranslationEntry] = []
                    let query = self.translationsTable.order(self.timestamp.desc).limit(limit)
                    for row in try db.prepare(query) {
                        let entry = TranslationEntry(
                            id: UUID(uuidString: row[self.id]) ?? UUID(),
                            sourceText: row[self.sourceText],
                            translatedText: row[self.translatedText],
                            speaker: row[self.speaker],
                            targetLanguage: row[self.targetLanguage],
                            timestamp: row[self.timestamp],
                            latencyMs: row[self.latencyMs]
                        )
                        entries.append(entry)
                    }
                    continuation.resume(returning: entries)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async version of pruneHistory
    func pruneHistoryAsync(retentionDays: Int, maxEntries: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dbQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: NSError(domain: "HistoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service deallocated"]))
                    return
                }
                do {
                    guard let db = self.db else {
                        continuation.resume()
                        return
                    }

                    if retentionDays > 0,
                       let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) {
                        try db.run(self.translationsTable.filter(self.timestamp < cutoffDate).delete())
                    }

                    if maxEntries > 0 {
                        let orderedIds = try db.prepare(
                            self.translationsTable
                                .select(self.id)
                                .order(self.timestamp.desc)
                        ).map { $0[self.id] }

                        if orderedIds.count > maxEntries {
                            for entryId in orderedIds.dropFirst(maxEntries) {
                                try db.run(self.translationsTable.filter(self.id == entryId).delete())
                            }
                        }
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async version of deleteTranslation
    func deleteTranslationAsync(withId entryId: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dbQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: NSError(domain: "HistoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service deallocated"]))
                    return
                }
                do {
                    guard let db = self.db else {
                        continuation.resume()
                        return
                    }
                    let entry = self.translationsTable.filter(self.id == entryId.uuidString)
                    try db.run(entry.delete())
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
