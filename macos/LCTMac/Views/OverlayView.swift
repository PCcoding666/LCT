import SwiftUI
import AppKit
import Foundation

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
            
            // Previous Segment (faded)
            if let prev = viewModel.previousSegment, !prev.isEmpty {
                OverlayTranslationPair(
                    original: prev.displaySource,
                    translated: prev.displayTranslation,
                    fontSize: viewModel.settings.overlayFontSize - 1, // slightly smaller
                    isOld: true
                )
            }
            
            // Active Segment
            if let active = viewModel.activeSegment, !active.isEmpty {
                OverlayTranslationPair(
                    original: active.displaySource,
                    translated: active.displayTranslation,
                    fontSize: viewModel.settings.overlayFontSize,
                    isOld: false
                )
            }
            
            // Status and Latency
            HStack {
                if let active = viewModel.activeSegment {
                    if active.state == .error, let err = active.errorMessage {
                        statusBadge(text: "Error: \(err)", color: .red)
                    } else if active.state == .listening {
                        statusBadge(text: "Listening", color: .green)
                    } else if active.state == .translating {
                        statusBadge(text: "Translating", color: .yellow, isTranslating: true)
                    }
                } else if viewModel.isPaused {
                    statusBadge(text: "Paused", color: .orange)
                }
                
                Spacer()
                
                if viewModel.settings.showLatency && viewModel.lastLatencyMs > 0 {
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

    private func statusBadge(text: String, color: Color, isTranslating: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
            if isTranslating {
                OverlayTypingDots()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.4))
        .cornerRadius(4)
    }
}

/// Translation pair in overlay
struct OverlayTranslationPair: View {
    let original: String
    let translated: String
    let fontSize: Double
    let isOld: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !original.isEmpty {
                Text(original)
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.white.opacity(isOld ? 0.4 : 0.6))
                    .lineLimit(2)
            }
            
            if !translated.isEmpty {
                Text(translated)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(isOld ? .white.opacity(0.7) : .white)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(isOld ? 0.2 : 0.4))
        )
    }
}

/// Typing dots animation for overlay
struct OverlayTypingDots: View {
    @State private var dotIndex = 0
    @State private var timer: Timer?
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 3, height: 3)
                    .opacity(dotIndex == index ? 1.0 : 0.3)
            }
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] _ in
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

// MARK: - Overlay Window Controller

/// Controller for managing the overlay window
@MainActor
class OverlayWindowController: NSObject, ObservableObject {
    private var overlayWindow: NSPanel?
    private var viewModel: TranscriptionViewModel?
    private var dragStartLocation: NSPoint?
    private var resizeStartLocation: NSPoint?
    private var startFrame: NSRect?
    
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
        saveWindowPosition()
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
            contentRect: NSRect(x: 0, y: 0, width: viewModel.settings.overlayWidth, height: viewModel.settings.overlayHeight),
            styleMask: [.nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovable = true
        window.acceptsMouseMovedEvents = true
        
        // Set click-through
        updateClickThrough(window)
        
        // Set content
        let overlayView = OverlayView(viewModel: viewModel)
        window.contentView = NSHostingView(rootView: overlayView)
        
        // Position window
        restoreWindowPosition(window)
        
        // Track window movements
        setupWindowTracking(window)
        
        self.overlayWindow = window
    }
    
    /// Update click-through setting
    private func updateClickThrough(_ window: NSPanel) {
        guard let viewModel = viewModel else { return }
        window.ignoresMouseEvents = viewModel.settings.overlayClickThrough
    }
    
    /// Restore saved window position
    private func restoreWindowPosition(_ window: NSPanel) {
        guard let viewModel = viewModel else { return }
        let settings = viewModel.settings
        
        // Use saved position if available and valid
        if settings.overlayPositionX != 0.0 && settings.overlayPositionY != 0.0 {
            if NSScreen.screens.contains(where: { screen in
                screen.visibleFrame.contains(NSPoint(x: settings.overlayPositionX, y: settings.overlayPositionY))
            }) {
                window.setFrameOrigin(NSPoint(x: settings.overlayPositionX, y: settings.overlayPositionY))
                return
            }
        }
        
        // Default position: top right corner
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            let x = screenRect.maxX - windowRect.width - 20
            let y = screenRect.maxY - windowRect.height - 20
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
    
    /// Save current window position
    @MainActor
    private func saveWindowPosition() {
        guard let window = overlayWindow,
              let viewModel = viewModel else { return }
        
        let frame = window.frame
        viewModel.settings.overlayPositionX = frame.origin.x
        viewModel.settings.overlayPositionY = frame.origin.y
        viewModel.settings.overlayWidth = frame.size.width
        viewModel.settings.overlayHeight = frame.size.height
        viewModel.settings.save()
    }
    
    /// Setup window tracking for drag and resize
    private func setupWindowTracking(_ window: NSPanel) {
        // Track window moves
        let moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveWindowPosition()
            }
        }
        
        // Track window resizes
        let resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveWindowPosition()
            }
        }
        
        // Store observers (need to be released properly in production)
        objc_setAssociatedObject(window, "moveObserver", moveObserver, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(window, "resizeObserver", resizeObserver, .OBJC_ASSOCIATION_RETAIN)
    }
    
    /// Update window position
    func setPosition(_ position: NSPoint) {
        overlayWindow?.setFrameOrigin(position)
    }
    
    /// Update window size
    func setSize(_ size: NSSize) {
        overlayWindow?.setContentSize(size)
        saveWindowPosition()
    }
    
    /// Reload overlay settings (call when settings change)
    func reloadSettings() {
        guard let window = overlayWindow,
              let viewModel = viewModel else { return }
        
        // Update click-through
        updateClickThrough(window)
        
        // Update window level
        window.level = viewModel.settings.overlayStayOnTop ? .floating : .normal
        
        // Update position if settings changed
        let currentFrame = window.frame
        if currentFrame.size.width != viewModel.settings.overlayWidth ||
           currentFrame.size.height != viewModel.settings.overlayHeight {
            window.setContentSize(NSSize(width: viewModel.settings.overlayWidth, height: viewModel.settings.overlayHeight))
        }
    }
    
    /// Close and release the window
    func close() {
        saveWindowPosition()
        
        // Remove observers
        if let moveObserver = objc_getAssociatedObject(overlayWindow as Any, "moveObserver") {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let resizeObserver = objc_getAssociatedObject(overlayWindow as Any, "resizeObserver") {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        
        overlayWindow?.close()
        overlayWindow = nil
        isVisible = false
    }
}
