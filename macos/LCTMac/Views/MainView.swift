import SwiftUI

/// Main application view with transcription and translation display
struct MainView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @State private var showSettings = false
    @State private var showHistory = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
            
            Divider()
            
            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status indicators
                    statusBar
                    
                    // Transcription cards
                    transcriptionCards
                    
                    // Current translation
                    currentTranslation
                }
                .padding()
            }
            
            Divider()
            
            // Audio level and controls
            bottomBar
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $viewModel.settings) { newSettings in
                viewModel.updateSettings(newSettings)
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(entries: viewModel.translationHistory)
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }
    
    // MARK: - Toolbar
    
    private var toolbar: some View {
        HStack {
            // App title
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                
                Text("LCT for macOS")
                    .font(.headline)
            }
            
            Spacer()
            
            // Connection status
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isOllamaConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isOllamaConnected ? "Ollama Connected" : "Ollama Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Toolbar buttons
            HStack(spacing: 12) {
                Button(action: { showHistory = true }) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("History")
                
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
                .help("Settings")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        HStack(spacing: 16) {
            // Capture status
            Label {
                Text(viewModel.isCapturing ? "Capturing" : "Stopped")
            } icon: {
                Image(systemName: viewModel.isCapturing ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(viewModel.isCapturing ? .green : .secondary)
            }
            .font(.caption)
            
            // Translation status
            if viewModel.isTranslating {
                Label("Translating...", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            
            // Latency
            if viewModel.settings.showLatency && viewModel.lastLatencyMs > 0 {
                Label("\(viewModel.lastLatencyMs) ms", systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Pause indicator
            if viewModel.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
    
    // MARK: - Transcription Cards
    
    private var transcriptionCards: some View {
        VStack(spacing: 12) {
            if viewModel.recentSegments.isEmpty {
                emptyStateCard
            } else {
                ForEach(viewModel.recentSegments) { segment in
                    TranscriptionCard(segment: segment)
                }
            }
        }
    }
    
    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("No transcriptions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("Click Start to begin capturing audio")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
    
    // MARK: - Current Translation
    
    private var currentTranslation: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Label("Translation", systemImage: "textformat")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { viewModel.copyToClipboard() }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
            }
            
            // Original text
            if !viewModel.currentOriginalText.isEmpty {
                Text(viewModel.currentOriginalText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            
            // Translated text
            if !viewModel.currentTranslatedText.isEmpty {
                Text(viewModel.currentTranslatedText)
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )
            }
        }
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack(spacing: 16) {
            // Audio level meter
            AudioLevelView(level: viewModel.audioLevel)
                .frame(width: 100)
            
            Spacer()
            
            // Control buttons
            HStack(spacing: 12) {
                // Clear button
                Button(action: { viewModel.clear() }) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCapturing)
                
                // Pause/Resume button
                Button(action: { viewModel.togglePause() }) {
                    Label(
                        viewModel.isPaused ? "Resume" : "Pause",
                        systemImage: viewModel.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isCapturing)
                
                // Start/Stop button
                Button(action: {
                    Task {
                        if viewModel.isCapturing {
                            await viewModel.stop()
                        } else {
                            await viewModel.start()
                        }
                    }
                }) {
                    Label(
                        viewModel.isCapturing ? "Stop" : "Start",
                        systemImage: viewModel.isCapturing ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isCapturing ? .red : .green)
            }
        }
        .padding()
    }
}

// MARK: - Transcription Card

struct TranscriptionCard: View {
    let segment: TranscriptionResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with speaker and timestamp
            HStack {
                if let speaker = segment.speaker {
                    Label(speaker, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        )
                }
                
                Spacer()
                
                Text(formatTime(segment.startTime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            // Text content
            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.isVolatile ? .secondary : .primary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
    }
    
    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Level View

struct AudioLevelView: View {
    let level: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                
                // Level indicator
                RoundedRectangle(cornerRadius: 4)
                    .fill(levelColor)
                    .frame(width: geometry.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 8)
    }
    
    private var levelColor: Color {
        if level < 0.5 {
            return .green
        } else if level < 0.8 {
            return .yellow
        } else {
            return .red
        }
    }
}

// MARK: - Preview

#Preview {
    MainView()
}
