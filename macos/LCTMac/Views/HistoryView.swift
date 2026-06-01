import SwiftUI

/// History view displaying past translations from SQLite persistence
struct HistoryView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedEntry: TranslationEntry?
    @State private var persistentEntries: [TranslationEntry] = []
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false
    
    private var displayEntries: [TranslationEntry] {
        if searchText.isEmpty {
            return persistentEntries
        }
        let lowercasedSearch = searchText.lowercased()
        return persistentEntries.filter {
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
                
                Text("\(persistentEntries.count) entries")
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
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading history...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayEntries.isEmpty {
                emptyState
            } else {
                List(displayEntries, selection: $selectedEntry) { entry in
                    HistoryEntryRow(entry: entry)
                        .tag(entry)
                        .contextMenu {
                            Button("Copy") { copyEntry(entry) }
                            Button("Delete", role: .destructive) {
                                deleteEntry(entry)
                            }
                        }
                }
                .listStyle(.inset)
            }
            
            Divider()
            
            // Footer with export and clear buttons
            HStack {
                Button(action: exportToCSV) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(persistentEntries.isEmpty)
                
                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(persistentEntries.isEmpty)
                
                Spacer()
                
                if let selected = selectedEntry {
                    Button(action: { copyEntry(selected) }) {
                        Label("Copy Selected", systemImage: "doc.on.doc")
                    }
                    
                    Button(role: .destructive, action: { deleteEntry(selected) }) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
        .frame(width: 650, height: 550)
        .task {
            await loadHistory()
        }
        .alert("Clear All History?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                viewModel.clearPersistentHistory()
                persistentEntries.removeAll()
            }
        } message: {
            Text("This will permanently delete all translation history. This action cannot be undone.")
        }
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
    
    private func loadHistory() async {
        isLoading = true
        persistentEntries = await viewModel.loadPersistentHistory(limit: 500)
        isLoading = false
    }
    
    private func deleteEntry(_ entry: TranslationEntry) {
        viewModel.deletePersistentEntry(entry)
        persistentEntries.removeAll { $0.id == entry.id }
        if selectedEntry?.id == entry.id {
            selectedEntry = nil
        }
    }
    
    private func exportToCSV() {
        guard let csv = viewModel.exportHistoryCSV() else { return }
        
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
