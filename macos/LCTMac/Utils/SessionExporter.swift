import Foundation
import UniformTypeIdentifiers

/// Renders a SessionTranscript into an exportable document. Pure functions
/// only; wall-clock dates are formatted in an injected time zone so tests
/// produce identical strings on any machine.
enum SessionExporter {
    /// Supported export formats. Raw values travel inside NotificationCenter
    /// objects so the File menu commands can reach the main window's view model.
    enum Format: String, CaseIterable {
        case markdown
        case plainText
        case srt

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            case .srt: return "srt"
            }
        }

        var contentType: UTType {
            // UTType.markdown needs a newer OS than the deployment target;
            // a well-formed extension always yields at least a dynamic UTI.
            switch self {
            case .markdown: return UTType(filenameExtension: "md") ?? .data
            case .plainText: return .plainText
            case .srt: return UTType(filenameExtension: "srt") ?? .data
            }
        }
    }

    /// Full document for one format. `sourceLanguages`/`targetLanguage` are
    /// header display labels (e.g. "ZH" and "EN").
    static func export(
        _ transcript: SessionTranscript,
        format: Format,
        sourceLanguages: String,
        targetLanguage: String,
        timeZone: TimeZone = .current
    ) -> String {
        switch format {
        case .markdown:
            return markdown(transcript, sourceLanguages: sourceLanguages, targetLanguage: targetLanguage, timeZone: timeZone)
        case .plainText:
            return plainText(transcript, sourceLanguages: sourceLanguages, targetLanguage: targetLanguage, timeZone: timeZone)
        case .srt:
            return srt(transcript)
        }
    }

    /// Default save-panel name, e.g. "LCT Session 2026-10-11 14.03.md".
    static func suggestedFileName(for format: Format, sessionStart: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "LCT Session \(formatter.string(from: sessionStart)).\(format.fileExtension)"
    }

    // MARK: - Markdown

    private static func markdown(_ transcript: SessionTranscript, sourceLanguages: String, targetLanguage: String, timeZone: TimeZone) -> String {
        let sessionStart = self.sessionStart(of: transcript)
        let titleDate = sessionStart.map { " — \(headerDateString($0, timeZone: timeZone))" } ?? ""
        var lines: [String] = [
            "# LCT Session\(titleDate)",
            "",
            "- Duration: \(clockString(duration(of: transcript, since: sessionStart)))",
            "- Languages: \(sourceLanguages) → \(targetLanguage)",
            "- Lines: \(transcript.entries.count)",
        ]
        if let sessionStart, !transcript.entries.isEmpty {
            for entry in transcript.entries {
                lines.append("")
                lines.append("**[\(clockString(offset(of: entry, since: sessionStart)))] \(entry.source.label)** \(markdownEscaped(singleLine(entry.sourceText)))")
                let translation = singleLine(entry.translatedText)
                if !translation.isEmpty {
                    lines.append("> \(markdownEscaped(translation))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escape a leading character Markdown would otherwise parse as a heading,
    /// quote, or list marker.
    private static func markdownEscaped(_ text: String) -> String {
        guard let first = text.first, "#>-*+".contains(first) else { return text }
        return "\\" + text
    }

    // MARK: - Plain text

    private static func plainText(_ transcript: SessionTranscript, sourceLanguages: String, targetLanguage: String, timeZone: TimeZone) -> String {
        let sessionStart = self.sessionStart(of: transcript)
        let titleDate = sessionStart.map { " — \(headerDateString($0, timeZone: timeZone))" } ?? ""
        var lines: [String] = ["LCT Session\(titleDate) (\(sourceLanguages) → \(targetLanguage))"]
        if let sessionStart {
            for entry in transcript.entries {
                lines.append("")
                let prefix = "[\(clockString(offset(of: entry, since: sessionStart)))] [\(entry.source.label)] "
                lines.append("\(prefix)\(singleLine(entry.sourceText))")
                let translation = singleLine(entry.translatedText)
                if !translation.isEmpty {
                    lines.append("\(String(repeating: " ", count: prefix.count))\(translation)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - SRT

    private static func srt(_ transcript: SessionTranscript) -> String {
        guard let sessionStart = sessionStart(of: transcript) else { return "" }

        // No precise speech start/end exists — only the finalization time — so
        // a cue ends at its finalization offset and starts an estimated
        // display duration earlier, never overlapping the previous cue on the
        // same capture lane. Lanes may overlap each other (they really do
        // speak at the same time), so cues are numbered after sorting.
        struct Cue {
            let start: TimeInterval
            let end: TimeInterval
            let index: Int
            let text: String
        }
        var cues: [Cue] = []
        var lastEndBySource: [AudioSource: TimeInterval] = [:]
        for (index, entry) in transcript.entries.enumerated() {
            var end = offset(of: entry, since: sessionStart)
            let estimated = min(max(Double(entry.sourceText.count) * 0.07, 1.0), 7.0)
            let start = max(end - estimated, lastEndBySource[entry.source] ?? 0, 0)
            if start >= end {
                end = start + 0.5
            }
            lastEndBySource[entry.source] = end
            var text = singleLine(entry.sourceText)
            let translation = singleLine(entry.translatedText)
            if !translation.isEmpty {
                text += "\n" + translation
            }
            cues.append(Cue(start: start, end: end, index: index, text: text))
        }
        cues.sort { ($0.start, $0.index) < ($1.start, $1.index) }

        let blocks = cues.enumerated().map { number, cue in
            """
            \(number + 1)
            \(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))
            \(cue.text)
            """
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Shared helpers

    /// Session baseline for offsets and headers. Falls back to the first
    /// entry when a clear() mid-session erased the explicit start time.
    private static func sessionStart(of transcript: SessionTranscript) -> Date? {
        transcript.startedAt ?? transcript.entries.first?.finalizedAt
    }

    private static func duration(of transcript: SessionTranscript, since sessionStart: Date?) -> TimeInterval {
        guard let sessionStart, let last = transcript.entries.last else { return 0 }
        return max(0, last.finalizedAt.timeIntervalSince(sessionStart))
    }

    private static func offset(of entry: SessionTranscript.Entry, since sessionStart: Date) -> TimeInterval {
        max(0, entry.finalizedAt.timeIntervalSince(sessionStart))
    }

    private static func headerDateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// "HH:MM:SS" for whole-second session offsets.
    private static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "HH:MM:SS,mmm" per the SRT spec.
    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let totalMs = max(0, Int((seconds * 1000).rounded()))
        let ms = totalMs % 1000
        let totalSeconds = totalMs / 1000
        return String(format: "%02d:%02d:%02d,%03d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, ms)
    }

    /// Caption text is one logical line; stray line breaks would corrupt the
    /// Markdown list and the SRT cue layout.
    private static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
