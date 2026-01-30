import SwiftUI
import AppKit

/// Overlay window for floating transcription display
struct OverlayView: View {
    @ObservedObject var viewModel: TranscriptionViewModel
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header (visible on hover)
            if isHovering {
                overlayHeader
            }
            
            // Recent segments with speaker labels
            ForEach(viewModel.recentSegments.suffix(3)) { segment in
                OverlaySegmentView(segment: segment)
            }
            
            // Divider
            if !viewModel.currentTranslatedText.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 1)
            }
            
            // Translated text
            if !viewModel.currentTranslatedText.isEmpty {
                Text(viewModel.currentTranslatedText)
                    .font(.system(size: viewModel.settings.overlayFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
            }
            
            // Latency indicator
            if viewModel.settings.showLatency && viewModel.lastLatencyMs > 0 {
                HStack {
                    Spacer()
                    Text("\(viewModel.lastLatencyMs) ms")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(viewModel.settings.overlayOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
    
    private var overlayHeader: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(viewModel.isCapturing ? .green : .red)
                .frame(width: 6, height: 6)
            
            Text(viewModel.isCapturing ? "Listening" : "Stopped")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
            
            Spacer()
            
            // Control buttons
            HStack(spacing: 8) {
                Button(action: { viewModel.togglePause() }) {
                    Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                
                Button(action: { viewModel.copyToClipboard() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.bottom, 4)
    }
}

/// Individual segment in overlay
struct OverlaySegmentView: View {
    let segment: TranscriptionResult
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Speaker badge
            if let speaker = segment.speaker {
                Text(speakerInitial(speaker))
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(speakerColor(speaker))
                    .clipShape(Circle())
            }
            
            // Text
            Text(segment.text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(segment.isVolatile ? 0.6 : 0.9))
                .lineLimit(2)
        }
    }
    
    private func speakerInitial(_ speaker: String) -> String {
        if speaker.contains("Speaker") {
            let number = speaker.replacingOccurrences(of: "Speaker ", with: "")
            return number
        }
        return String(speaker.prefix(1)).uppercased()
    }
    
    private func speakerColor(_ speaker: String) -> Color {
        // Generate consistent color from speaker name
        let hash = abs(speaker.hashValue)
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        return colors[hash % colors.count]
    }
}

// MARK: - Overlay Window Controller

/// Controller for managing the overlay window
class OverlayWindowController: NSObject, ObservableObject {
    private var overlayWindow: NSPanel?
    private var viewModel: TranscriptionViewModel?
    
    @Published var isVisible: Bool = false
    
    /// Show the overlay window
    func show(with viewModel: TranscriptionViewModel) {
        self.viewModel = viewModel
        
        if overlayWindow == nil {
            createWindow()
        }
        
        overlayWindow?.orderFront(nil)
        isVisible = true
    }
    
    /// Hide the overlay window
    func hide() {
        overlayWindow?.orderOut(nil)
        isVisible = false
    }
    
    /// Toggle overlay visibility
    func toggle(with viewModel: TranscriptionViewModel) {
        if isVisible {
            hide()
        } else {
            show(with: viewModel)
        }
    }
    
    private func createWindow() {
        guard let viewModel = viewModel else { return }
        
        // Create window
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        
        // Set content
        let overlayView = OverlayView(viewModel: viewModel)
        window.contentView = NSHostingView(rootView: overlayView)
        
        // Position window
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            let x = screenRect.maxX - windowRect.width - 20
            let y = screenRect.maxY - windowRect.height - 20
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        self.overlayWindow = window
    }
    
    /// Update window position
    func setPosition(_ position: NSPoint) {
        overlayWindow?.setFrameOrigin(position)
    }
    
    /// Update window size
    func setSize(_ size: NSSize) {
        overlayWindow?.setContentSize(size)
    }
    
    /// Close and release the window
    func close() {
        overlayWindow?.close()
        overlayWindow = nil
        isVisible = false
    }
}

// MARK: - Preview

#Preview {
    let viewModel = TranscriptionViewModel()
    
    // Add sample data
    let sampleSegments = [
        TranscriptionResult(
            text: "Hello, how are you doing today?",
            speaker: "Speaker 1",
            startTime: 0,
            endTime: 2.5
        ),
        TranscriptionResult(
            text: "I'm doing great, thanks for asking!",
            speaker: "Speaker 2",
            startTime: 2.5,
            endTime: 5.0
        )
    ]
    
    return OverlayView(viewModel: viewModel)
        .frame(width: 400)
        .padding()
        .background(Color.black.opacity(0.5))
}
