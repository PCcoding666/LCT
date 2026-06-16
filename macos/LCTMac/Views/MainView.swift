import SwiftUI
import Combine

/// Terminal-HUD theme tokens for the main window
enum HUD {
    static let accent = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let background = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let surface = Color.white.opacity(0.04)
    static let hairline = Color.white.opacity(0.08)

    static func mono(_ style: Font.TextStyle) -> Font {
        .system(style, design: .monospaced)
    }
}

/// Main application view with transcription and translation display
struct MainView: View {
    @StateObject private var viewModel = TranscriptionViewModel()
    @StateObject private var overlayController = OverlayWindowController()
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            hudBar
            Rectangle().fill(HUD.hairline).frame(height: 1)

            transcriptFeed

            Rectangle().fill(HUD.hairline).frame(height: 1)
            bottomBar
        }
        .frame(minWidth: 480, minHeight: 400)
        .background(HUD.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: $viewModel.settings) { newSettings in
                viewModel.updateSettings(newSettings)
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(viewModel: viewModel)
        }
        .overlay(alignment: .top) {
            errorBanner
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.notice)
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
    }

    // MARK: - HUD Bar (always visible)

    private var hudBar: some View {
        HStack(spacing: 16) {
            // Recording status + elapsed time
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isCapturing ? (viewModel.isPaused ? Color.orange : HUD.accent) : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)

                if viewModel.isCapturing, let startedAt = viewModel.captureStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(viewModel.isPaused ? "paused" : "rec \(elapsedString(since: startedAt, now: timeline.date))")
                            .font(HUD.mono(.caption))
                            .foregroundStyle(viewModel.isPaused ? Color.orange : .secondary)
                    }
                } else {
                    Text("idle")
                        .font(HUD.mono(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Language direction + model identity + latency
            HStack(spacing: 8) {
                Text("\(viewModel.settings.sourceLanguage.isoCode.uppercased()) → \(viewModel.settings.targetLanguage.isoCode.uppercased())")
                    .font(HUD.mono(.caption))
                    .foregroundStyle(.secondary)

                OllamaStatusIndicator(isConnected: viewModel.isOllamaConnected)

                Text(viewModel.settings.ollamaModel)
                    .font(HUD.mono(.caption))
                    .foregroundStyle(.secondary)

                if viewModel.lastLatencyMs > 0 {
                    Text("· \(viewModel.lastLatencyMs) ms")
                        .font(HUD.mono(.caption))
                        .foregroundStyle(viewModel.isTranslating ? HUD.accent : Color.secondary.opacity(0.6))
                }
            }

            Spacer()

            // Toolbar buttons
            HStack(spacing: 14) {
                Button(action: { autoScroll.toggle() }) {
                    Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(autoScroll ? HUD.accent : .secondary)
                }
                .help(autoScroll ? "Auto-scroll ON" : "Auto-scroll OFF")

                Button(action: { showHistory = true }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
                .help("History (⇧⌘H)")

                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
                .help("Settings")
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 78) // Clear the traffic-light buttons (hidden title bar)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript Feed

    private var transcriptFeed: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if viewModel.segments.isEmpty && viewModel.liveSourceText.isEmpty {
                            emptyState
                        } else {
                            ForEach(viewModel.segments) { segment in
                                TranscriptSegmentRow(segment: segment)
                                    .id(segment.id)
                            }
                        }

                        if !viewModel.liveSourceText.isEmpty {
                            liveDraftLine
                                .id("liveDraft")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onChange(of: viewModel.segments.count) { _, _ in
                    if autoScroll {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.liveSourceText) { _, _ in
                    if autoScroll {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.liveTranslation) { _, _ in
                    if autoScroll {
                        scrollToBottom(proxy: proxy)
                    }
                }

                if !autoScroll {
                    Button(action: {
                        autoScroll = true
                        scrollToBottom(proxy: proxy)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.to.line")
                            Text("latest")
                                .font(HUD.mono(.caption))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(HUD.surface)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(HUD.hairline, lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("// no transcriptions yet")
                .font(HUD.mono(.body))
                .foregroundStyle(.secondary)
            Text("// press ⌘space or hit start to begin capturing")
                .font(HUD.mono(.body))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 24)
    }

    private var liveDraftLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("❯")
                    .font(HUD.mono(.body))
                    .foregroundStyle(HUD.accent)

                Text(viewModel.liveSourceText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if viewModel.liveTranslation.isEmpty {
                    BlinkingCursor()
                }
            }

            if !viewModel.liveTranslation.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("↳")
                        .font(HUD.mono(.body))
                        .foregroundStyle(HUD.accent.opacity(0.7))

                    Text(viewModel.liveTranslation)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.85))

                    BlinkingCursor()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(HUD.surface)
        )
    }

    // MARK: - Bottom Bar (always visible)

    private var bottomBar: some View {
        HStack(spacing: 16) {
            AudioBarsView(level: viewModel.audioLevel, isActive: viewModel.isCapturing)

            Text("⌘␣ start · ⌘P pause · ⇧⌘C copy · ⌘O overlay")
                .font(HUD.mono(.caption2))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 10) {
                Button(action: { viewModel.clear() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCapturing)
                .help("Clear transcript")

                Button(action: { viewModel.togglePause() }) {
                    Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isCapturing)
                .help(viewModel.isPaused ? "Resume (⌘P)" : "Pause (⌘P)")

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
                        viewModel.isCapturing ? "stop" : "start",
                        systemImage: viewModel.isCapturing ? "stop.fill" : "play.fill"
                    )
                    .font(HUD.mono(.body))
                    .frame(minWidth: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isCapturing ? .red : HUD.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if let notice = viewModel.notice {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: noticeIcon(notice.severity))
                        .foregroundStyle(noticeColor(notice.severity))

                    Text(notice.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button(action: { viewModel.dismissNotice() }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                if !notice.actions.isEmpty {
                    HStack(spacing: 8) {
                        Spacer()
                        ForEach(notice.actions) { action in
                            Button(action.label) {
                                handleNoticeAction(action)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(noticeColor(notice.severity).opacity(0.5), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                guard notice.autoDismiss else { return }
                let id = notice.id
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    await MainActor.run {
                        if viewModel.notice?.id == id {
                            withAnimation { viewModel.dismissNotice() }
                        }
                    }
                }
            }
        }
    }

    private func handleNoticeAction(_ action: NoticeAction) {
        if action == .openAppSettings {
            viewModel.dismissNotice()
            showSettings = true
        } else {
            viewModel.perform(action)
        }
    }

    private func noticeIcon(_ severity: NoticeSeverity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func noticeColor(_ severity: NoticeSeverity) -> Color {
        switch severity {
        case .info: return HUD.accent
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - Helpers

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            if !viewModel.liveSourceText.isEmpty {
                proxy.scrollTo("liveDraft", anchor: .bottom)
            } else if let last = viewModel.segments.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func elapsedString(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    let segment: TranslationSegment

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(segment.timestamp.formatted(Self.timeFormat))
                .font(HUD.mono(.caption2))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 5) {
                if !segment.sourceText.isEmpty {
                    Text(segment.sourceText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !segment.translatedText.isEmpty && segment.state != .failed {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(segment.translatedText)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

                        if segment.state == .translating {
                            BlinkingCursor()
                        }
                    }
                }

                statusLine
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: 2)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch segment.state {
        case .translating where segment.translatedText.isEmpty:
            Text("streaming…")
                .font(HUD.mono(.caption2))
                .foregroundStyle(HUD.accent.opacity(0.7))
        case .pending:
            Text("paused — translates on resume")
                .font(HUD.mono(.caption2))
                .foregroundStyle(.orange)
        case .failed:
            Text(segment.translatedText)
                .font(HUD.mono(.caption2))
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var borderColor: Color {
        switch segment.state {
        case .translating: return HUD.accent
        case .pending: return .orange
        case .failed: return .red
        default: return Color.white.opacity(0.12)
        }
    }
}

// MARK: - Blinking Cursor

struct BlinkingCursor: View {
    @State private var isOn = false

    var body: some View {
        Rectangle()
            .fill(HUD.accent)
            .frame(width: 7, height: 14)
            .opacity(isOn ? 0.9 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                    isOn = true
                }
            }
    }
}

// MARK: - Audio Bars View

struct AudioBarsView: View {
    let level: Float
    let isActive: Bool

    private static let barHeights: [CGFloat] = [5, 9, 13, 7, 11, 15, 8, 12, 6, 10, 14, 7]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Self.barHeights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(index: index))
                    .frame(width: 3, height: Self.barHeights[index])
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.1), value: level)
    }

    private func barColor(index: Int) -> Color {
        guard isActive else { return Color.white.opacity(0.1) }
        let threshold = Float(index + 1) / Float(Self.barHeights.count)
        return level >= threshold ? HUD.accent : Color.white.opacity(0.12)
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
                    .frame(width: 7, height: 7)

                if guardian.status != .running && !isConnected {
                    Text(statusText)
                        .font(HUD.mono(.caption))
                        .foregroundStyle(.secondary)
                }

                if guardian.isChecking {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.gray.opacity(0.15) : Color.clear)
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
        return (guardian.status == .running || isConnected) ? HUD.accent : .red
    }

    private var statusText: String {
        if guardian.isChecking {
            return "checking…"
        }

        switch guardian.status {
        case .running:
            return "ollama up"
        case .starting:
            return "starting…"
        case .notInstalled:
            return "ollama not installed"
        case .installed, .stopped:
            return "ollama stopped"
        case .error(let message):
            return "error: \(message)"
        }
    }
}
