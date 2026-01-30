import SwiftUI

/// History view displaying past translations
struct HistoryView: View {
    let entries: [TranslationEntry]
    
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedEntry: TranslationEntry?
    
    private var filteredEntries: [TranslationEntry] {
        if searchText.isEmpty {
            return entries.reversed()
        }
        let lowercasedSearch = searchText.lowercased()
        return entries.reversed().filter {
            $0.sourceText.lowercased().contains(lowercasedSearch) ||
            $0.translatedText.lowercased().contains(lowercasedSearch)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Translation History")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text("\(entries.count) entries")
                    .foregroundStyle(.secondary)
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            Divider()
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding()
            
            Divider()
            
            // Entry list
            if filteredEntries.isEmpty {
                emptyState
            } else {
                List(filteredEntries, selection: $selectedEntry) { entry in
                    HistoryEntryRow(entry: entry)
                        .tag(entry)
                }
                .listStyle(.inset)
            }
            
            Divider()
            
            // Footer with export button
            HStack {
                Button(action: exportToCSV) {
                    Label("Export to CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
                
                Spacer()
                
                if let selected = selectedEntry {
                    Button(action: { copyEntry(selected) }) {
                        Label("Copy Selected", systemImage: "doc.on.doc")
                    }
                }
            }
            .padding()
        }
        .frame(width: 600, height: 500)
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text(searchText.isEmpty ? "No history yet" : "No results found")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text(searchText.isEmpty ? "Translations will appear here" : "Try a different search term")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func exportToCSV() {
        let history = TranslationHistory(entries: entries)
        let csv = history.exportToCSV()
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "lct_history.csv"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to save CSV: \(error)")
            }
        }
    }
    
    private func copyEntry(_ entry: TranslationEntry) {
        let text = """
        Source: \(entry.sourceText)
        Translation: \(entry.translatedText)
        Language: \(entry.targetLanguage)
        Time: \(entry.formattedTimestamp)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Individual history entry row
struct HistoryEntryRow: View {
    let entry: TranslationEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                if let speaker = entry.speaker {
                    Label(speaker, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                
                Spacer()
                
                Text(entry.formattedTimestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                Text(entry.formattedLatency)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // Source text
            Text(entry.sourceText)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
            
            // Translated text
            Text(entry.translatedText)
                .font(.body)
                .foregroundStyle(.blue)
                .lineLimit(2)
            
            // Language badge
            HStack {
                Text(entry.targetLanguage)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.1))
                    )
                
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    HistoryView(entries: [
        TranslationEntry(
            sourceText: "Hello, how are you?",
            translatedText: "你好，你怎么样？",
            speaker: "Speaker 1",
            targetLanguage: "Chinese",
            latencyMs: 150
        ),
        TranslationEntry(
            sourceText: "I'm doing great, thanks!",
            translatedText: "我很好，谢谢！",
            speaker: "Speaker 2",
            targetLanguage: "Chinese",
            latencyMs: 120
        )
    ])
}
