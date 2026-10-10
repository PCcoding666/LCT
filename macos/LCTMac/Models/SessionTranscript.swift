import Foundation

/// Untrimmed record of one capture session: every finalized caption from the
/// moment a start() succeeds until the next one. Kept independently of the
/// on-screen cards (which are trimmed to maxDisplayCards) and of the opt-in
/// persistent history, so an export always covers the whole session. A pure
/// value type: export logic and tests never touch the capture pipeline.
struct SessionTranscript: Equatable {
    /// One finalized caption line and its final translation (empty while the
    /// translation is still pending, or when it failed).
    struct Entry: Equatable, Identifiable {
        let id: UUID
        let source: AudioSource
        let sourceText: String
        var translatedText: String
        /// When the caption was finalized (session offsets derive from this).
        let finalizedAt: Date
    }

    /// When the current session began; nil before the first start() and after clear().
    private(set) var startedAt: Date?

    /// Finalized captions in finalization order, both capture lanes interleaved.
    private(set) var entries: [Entry] = []

    /// Start a new session, dropping whatever the previous one recorded.
    mutating func begin(at date: Date) {
        startedAt = date
        entries = []
    }

    mutating func append(id: UUID, source: AudioSource, sourceText: String, finalizedAt: Date) {
        entries.append(Entry(id: id, source: source, sourceText: sourceText, translatedText: "", finalizedAt: finalizedAt))
    }

    /// Record the completed translation for a caption. Only final results
    /// reach this — streaming intermediate output never does.
    mutating func updateTranslation(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].translatedText = text
    }

    /// Revoke captions the recognizer rolled back.
    mutating func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
    }

    mutating func clear() {
        startedAt = nil
        entries = []
    }
}
