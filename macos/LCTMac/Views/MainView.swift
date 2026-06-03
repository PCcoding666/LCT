import SwiftUI
import Combine

/// Main application view with transcription and translation display
struct MainView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @StateObject private var overlayController = OverlayWindowController()
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
                    
                    // Transcript log
                    transcriptView
                }
                .padding()
            }
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // Audio level and controls
            bottomBar
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $viewModel.settings) { newSettings in
                viewModel.updateSettings(newSettings)
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(viewModel: viewModel)
        }
        .overlay(alignment: .top) {
            if let error = viewModel.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: error.contains("restart") ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                        .foregroundStyle(error.contains("restart") ? .orange : .red)
                    
                    Text(error)
                        .font(.callout)
                        .lineLimit(2)
                    
                    Spacer()
                    
                    Button(action: { viewModel.errorMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(error.contains("restart") ? Color.orange.opacity(0.15) : Color.red.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(error.contains("restart") ? Color.orange.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    // Auto-dismiss after 8 seconds for info messages
                    if error.contains("restart") {
                        Task {
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            await MainActor.run {
                                if viewModel.errorMessage == error {
                                    withAnimation { viewModel.errorMessage = nil }
                                }
                            }
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.errorMessage)
        .onReceive(NotificationCenter.default.publisher(for: .toggleCapture)) { notification in
            Task {
                if let shouldStart = notification.object as? Bool {
                    if shouldStart {
                        await viewModel.start()
                    } else {
                        await viewModel.stop()
                    }
                } else {
                    // Toggle
                    if viewModel.isCapturing {
                        await viewModel.stop()
                    } else {
                        await viewModel.start()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePause)) { _ in
            viewModel.togglePause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyTranslation)) { _ in
            viewModel.copyToClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleOverlay)) { _ in
            overlayController.toggle(with: viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHistory)) { _ in
            showHistory = true
        }
        .onAppear {
            print("[MainView] Appeared")
            // Note: Overlay is now shown only when user toggles it or starts capture
            // to avoid window initialization conflicts
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
            
            // Ollama status with more detail
            OllamaStatusIndicator(isConnected: viewModel.isOllamaConnected)
            
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
    
    // MARK: - Transcript View
    
    private var transcriptView: some View {
        VStack(spacing: 12) {
            if viewModel.segments.isEmpty {
                emptyStateCard
            } else {
                ForEach(viewModel.segments) { segment in
                    TranscriptSegmentCard(segment: segment)
                }
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
}

// MARK: - Transcript Segment Card

struct TranscriptSegmentCard: View {
    let segment: CaptionSegment
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with timestamp and latency
            HStack {
                Text(formatTime(segment.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                Spacer()
                
                if segment.latencyMs > 0 {
                    Text("\(segment.latencyMs) ms")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // Text content
            if !segment.displaySource.isEmpty {
                Text(segment.displaySource)
                    .font(.body)
                    .foregroundStyle(segment.state == .listening ? .secondary : .primary)
            }
            
            if !segment.displayTranslation.isEmpty {
                Text(segment.displayTranslation)
                    .font(.body)
                    .foregroundStyle(segment.state == .translating ? .cyan : .blue)
            }
            
            if segment.state == .error, let err = segment.errorMessage {
                Text("Error: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
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

// MARK: - Ollama Status Indicator

struct OllamaStatusIndicator: View {
    let isConnected: Bool
    @State private var isHovering = false
    @StateObject private var guardian = OllamaGuardian.shared
    
    var body: some View {
        Button(action: {
            if !isConnected {
                Task {
                    try? await guardian.ensureRunning()
                }
            }
        }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if guardian.status != .running && !guardian.isChecking {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                if guardian.isChecking {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.gray.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help((guardian.status == .running || isConnected) ? "Ollama is running" : "Click to start Ollama")
    }
    
    private var statusColor: Color {
        if guardian.isChecking {
            return .yellow
        }
        return (guardian.status == .running || isConnected) ? .green : .red
    }
    
    private var statusText: String {
        if guardian.isChecking {
            return "Checking..."
        }
        
        switch guardian.status {
        case .running:
            if let version = guardian.ollamaVersion {
                return "Ollama v\(version)"
            }
            return "Ollama Connected"
        case .starting:
            return "Starting..."
        case .notInstalled:
            return "Ollama Not Installed"
        case .installed, .stopped:
            return "Ollama Stopped"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}


// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotIndex = 0
    @State private var timer: Timer?
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.blue)
                    .frame(width: 4, height: 4)
                    .opacity(dotIndex == index ? 1.0 : 0.3)
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [self] _ in
                Task { @MainActor in
                    dotIndex = (dotIndex + 1) % 3
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

