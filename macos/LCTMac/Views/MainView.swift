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

/// Pure formatting for the HUD language label and the empty-state listening
/// line. Kept view-free so it is unit-testable.
enum LanguageLabel {
    /// Top-bar label: `ZH → EN` when both lanes share a recognition language;
    /// `SYS ZH · MIC EN → EN` when the microphone lane is active and differs.
    static func format(
        system: SourceLanguage,
        microphone: SourceLanguage?,
        target: TargetLanguage,
        microphoneActive: Bool
    ) -> String {
        let sys = system.isoCode.uppercased()
        let mic = (microphone ?? system).isoCode.uppercased()
        let tgt = target.isoCode.uppercased()
        guard microphoneActive, mic != sys else {
            return "\(sys) → \(tgt)"
        }
        return "SYS \(sys) · MIC \(mic) → \(tgt)"
    }

    /// Empty-state line while capturing: `// listening (ZH)…`, or
    /// `// listening (SYS ZH · MIC EN)…` when the lanes differ.
    static func listening(
        system: SourceLanguage,
        microphone: SourceLanguage?,
        microphoneActive: Bool
    ) -> String {
        let sys = system.isoCode.uppercased()
        let mic = (microphone ?? system).isoCode.uppercased()
        guard microphoneActive, mic != sys else {
            return "// listening (\(sys))…"
        }
        return "// listening (SYS \(sys) · MIC \(mic))…"
    }
}

/// Main application view with transcription and translation display
@MainActor
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

            errorBanner

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
        .animation(.easeInOut(duration: 0.3), value: viewModel.notice)
        .task {
            // Warm the translation model in the background right after the
            // main window appears, so the first start() finds it in memory.
            await viewModel.prepareModelOnLaunch()
            // Populate the language menu's availability markers (which
            // languages need an on-device model download).
            await viewModel.refreshLanguageAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { notification in
            // The ⌘, settings window saved new settings — apply them to the
            // running app. updateSettings never re-posts this notification.
            guard let newSettings = notification.object as? AppSettings,
                  newSettings != viewModel.settings else { return }
            viewModel.updateSettings(newSettings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCapture)) { notification in
            Task {
                if let shouldStart = notification.object as? Bool {
                    if shouldStart {
                        await viewModel.start()
                    } else {
                        await viewModel.stop()
                    }
                } else {
                    await viewModel.toggleCapture()
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
        .onReceive(NotificationCenter.default.publisher(for: .exportSession)) { notification in
            // File menu export commands carry the format raw value.
            guard let raw = notification.object as? String,
                  let format = SessionExporter.Format(rawValue: raw) else { return }
            viewModel.exportSession(format)
        }
    }

    // MARK: - HUD Bar (always visible)

    private var hudBar: some View {
        HStack(spacing: 16) {
            // Recording status + elapsed time
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)

                switch viewModel.captureState {
                case .capturing:
                    if let startedAt = viewModel.captureStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(viewModel.isPaused ? "paused" : "rec \(elapsedString(since: startedAt, now: timeline.date))")
                                .font(HUD.mono(.caption))
                                .foregroundStyle(viewModel.isPaused ? Color.orange : .secondary)
                        }
                    }
                case .idle:
                    Text("idle")
                        .font(HUD.mono(.caption))
                        .foregroundStyle(.secondary)
                case .starting:
                    Text("starting…")
                        .font(HUD.mono(.caption))
                        .foregroundStyle(HUD.accent)
                case .stopping:
                    Text("stopping…")
                        .font(HUD.mono(.caption))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Language direction + model identity + latency
            HStack(spacing: 8) {
                languageMenu

                OllamaStatusIndicator(isConnected: viewModel.isOllamaConnected) {
                    viewModel.startOllamaFromIndicator()
                }

                HStack(spacing: 4) {
                    Text(viewModel.settings.ollamaModel)
                        .font(HUD.mono(.caption))
                        .foregroundStyle(modelNameColor)

                    if viewModel.modelState == .loading {
                        Text("loading…")
                            .font(HUD.mono(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .help(modelStateHelp)

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

                Menu {
                    Button("Export as Markdown…") { viewModel.exportSession(.markdown) }
                    Button("Export as Text…") { viewModel.exportSession(.plainText) }
                    Button("Export as Subtitles (SRT)…") { viewModel.exportSession(.srt) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(viewModel.sessionTranscript.entries.isEmpty)
                .help("Export this session")

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

    // MARK: - Language Menu (HUD bar)

    /// Clickable language label: switch each lane's recognition language and
    /// the translation target without opening Settings — live while capturing.
    private var languageMenu: some View {
        Menu {
            Section("System Audio") {
                sourceLanguageItems(for: .system)
            }
            if viewModel.supportsPerLaneLanguages {
                Section("Microphone") {
                    Button {
                        Task { await viewModel.setSourceLanguage(nil, for: .microphone) }
                    } label: {
                        menuItemLabel("Same as System Audio", selected: viewModel.settings.microphoneSourceLanguage == nil)
                    }
                    sourceLanguageItems(for: .microphone)
                }
            }
            Section("Translate To") {
                ForEach(TargetLanguage.allCases) { language in
                    Button {
                        viewModel.setTargetLanguage(language)
                    } label: {
                        menuItemLabel("\(language.displayName) (\(language.nativeName))",
                                      selected: viewModel.settings.targetLanguage == language)
                    }
                }
            }
        } label: {
            Text(LanguageLabel.format(
                system: viewModel.settings.sourceLanguage,
                microphone: viewModel.settings.microphoneSourceLanguage,
                target: viewModel.settings.targetLanguage,
                microphoneActive: viewModel.settings.captureMicrophone
            ))
            .font(HUD.mono(.caption))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recognition and translation languages — applies live while capturing")
    }

    /// One menu item per source language the engine can use on-device.
    /// Unsupported languages are hidden; downloadable ones are annotated.
    @ViewBuilder
    private func sourceLanguageItems(for source: AudioSource) -> some View {
        ForEach(SourceLanguage.allCases) { language in
            if viewModel.languageAvailability[language] != .unsupported {
                Button {
                    Task { await viewModel.setSourceLanguage(language, for: source) }
                } label: {
                    let title = viewModel.languageAvailability[language] == .downloadable
                        ? "\(language.displayName) (download)"
                        : language.displayName
                    menuItemLabel(title, selected: isSourceLanguageSelected(language, for: source))
                }
            }
        }
    }

    private func isSourceLanguageSelected(_ language: SourceLanguage, for source: AudioSource) -> Bool {
        switch source {
        case .system:
            return viewModel.settings.sourceLanguage == language
        case .microphone:
            return viewModel.settings.microphoneSourceLanguage == language
        }
    }

    private func menuItemLabel(_ title: String, selected: Bool) -> some View {
        Group {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
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
            if viewModel.isCapturing {
                Text(LanguageLabel.listening(
                    system: viewModel.settings.sourceLanguage,
                    microphone: viewModel.settings.microphoneSourceLanguage,
                    microphoneActive: viewModel.captureSources.contains(.microphone)
                ))
                    .font(HUD.mono(.body))
                    .foregroundStyle(.secondary)
                Text("// speak or play audio — captions appear here")
                    .font(HUD.mono(.body))
                    .foregroundStyle(.tertiary)
            } else {
                Text("// no transcriptions yet")
                    .font(HUD.mono(.body))
                    .foregroundStyle(.secondary)
                Text("// press ⌘␣ or hit start to begin capturing")
                    .font(HUD.mono(.body))
                    .foregroundStyle(.tertiary)
            }
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
            AudioMetersView(
                systemLevel: viewModel.systemLevel,
                micLevel: viewModel.micLevel,
                sources: viewModel.captureSources,
                isActive: viewModel.isCapturing && !viewModel.isPaused,
                micDeviceName: viewModel.microphoneDeviceName,
                micDeviceIsVirtual: viewModel.microphoneDeviceIsVirtual
            )

            Text(viewModel.isCapturing
                 ? "⌘␣ stop · ⌘P pause · ⇧⌘C copy · ⌘O overlay"
                 : "⌘␣ start · ⌘P pause · ⇧⌘C copy · ⌘O overlay")
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
                    Task { await viewModel.toggleCapture() }
                }) {
                    Label(captureButtonTitle, systemImage: captureButtonIcon)
                        .font(HUD.mono(.body))
                        .frame(minWidth: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.captureState == .capturing ? .red : HUD.accent)
                .disabled(viewModel.captureState == .starting || viewModel.captureState == .stopping)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var captureButtonTitle: String {
        switch viewModel.captureState {
        case .idle: return "start"
        case .starting: return "starting…"
        case .capturing: return "stop"
        case .stopping: return "stopping…"
        }
    }

    private var captureButtonIcon: String {
        switch viewModel.captureState {
        case .idle: return "play.fill"
        case .capturing: return "stop.fill"
        case .starting, .stopping: return "hourglass"
        }
    }

    private var statusDotColor: Color {
        switch viewModel.captureState {
        case .idle: return Color.secondary.opacity(0.5)
        case .starting: return HUD.accent
        case .capturing: return viewModel.isPaused ? Color.orange : HUD.accent
        case .stopping: return Color.orange
        }
    }

    /// Model name in the HUD: full brightness while loading/loaded (or before
    /// the first probe), dimmed when the model is known to be out of memory.
    private var modelNameColor: Color {
        switch viewModel.modelState {
        case .notLoaded, .failed:
            return .secondary.opacity(0.5)
        case .unknown, .loading, .loaded:
            return .secondary
        }
    }

    private var modelStateHelp: String {
        switch viewModel.modelState {
        case .unknown:
            return "Translation model"
        case .loading:
            return "Model is loading into memory…"
        case .loaded:
            return "Model loaded in memory"
        case .notLoaded:
            return "Model not loaded — it will load when you start"
        case .failed(let reason):
            return "Model not loaded — \(reason)"
        }
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
            .padding(.vertical, 10)
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

@MainActor
struct TranscriptSegmentRow: View {
    let segment: TranslationSegment

    private static let timeFormat = Date.FormatStyle(date: .omitted, time: .standard)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.timestamp.formatted(Self.timeFormat))
                    .font(HUD.mono(.caption2))
                    .foregroundStyle(.tertiary)

                // Capture lane badge (MIC / SYS) so dual-source transcripts stay distinguishable
                Label(segment.source.label, systemImage: segment.source.icon)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(segment.source == .microphone ? Color.orange : Color.cyan)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }
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

@MainActor
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

// MARK: - Audio Level Meters (OBS-style, one row per active capture lane)

@MainActor
struct AudioMetersView: View {
    let systemLevel: Float
    let micLevel: Float
    let sources: [AudioSource]
    let isActive: Bool
    var micDeviceName: String? = nil
    var micDeviceIsVirtual: Bool = false

    var body: some View {
        // When idle (no capture session yet), preview the lanes implied by nothing —
        // just show the system row greyed out so the slot doesn't jump around.
        let lanes: [AudioSource] = sources.isEmpty ? [.system] : sources

        VStack(alignment: .leading, spacing: 3) {
            ForEach(lanes, id: \.self) { lane in
                LaneMeterView(
                    lane: lane,
                    level: lane == .microphone ? micLevel : systemLevel,
                    isActive: isActive,
                    deviceName: lane == .microphone ? micDeviceName : nil,
                    deviceIsVirtual: lane == .microphone && micDeviceIsVirtual
                )
            }
        }
        .frame(width: 150)
    }
}

@MainActor
struct LaneMeterView: View {
    let lane: AudioSource
    let level: Float   // 0...1, normalized -60dB…0dB
    let isActive: Bool
    var deviceName: String? = nil
    var deviceIsVirtual: Bool = false

    private var tint: Color {
        lane == .microphone ? .orange : .cyan
    }

    /// dB readout for debugging ("-∞" when effectively silent)
    private var dBText: String {
        guard isActive, level > 0.001 else { return "-∞" }
        let db = Int(level * 60 - 60)
        return "\(db)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(lane.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? tint : Color.secondary.opacity(0.5))
                    .frame(width: 24, alignment: .leading)

                GeometryReader { geo in
                    let fill = geo.size.width * CGFloat(isActive ? max(0, min(level, 1)) : 0)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.08))

                        // Gradient spans the FULL track; mask reveals only up to the
                        // current level so colors stay anchored to dB zones (OBS-style)
                        LinearGradient(
                            colors: [HUD.accent, HUD.accent, .yellow, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width, height: 6)
                        .mask(
                            HStack(spacing: 0) {
                                Rectangle().frame(width: fill)
                                Spacer(minLength: 0)
                            }
                        )
                    }
                }
                .frame(height: 6)

                Text(dBText)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing)
            }
            .frame(height: 10)

            // The mic lane names its input device so a silent virtual sound card
            // (e.g. BlackHole) is identifiable at a glance.
            if lane == .microphone, let deviceName, !deviceName.isEmpty {
                Text(deviceIsVirtual ? "\(deviceName) · virtual" : deviceName)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(deviceIsVirtual ? Color.orange : Color.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 29)
            }
        }
        .animation(.linear(duration: 0.06), value: level)
        .help(lane == .microphone ? "Microphone input level" : "System audio level")
    }
}

// MARK: - Ollama Status Indicator

@MainActor
struct OllamaStatusIndicator: View {
    let isConnected: Bool
    /// Tap handler for the disconnected state; the view model owns the
    /// start attempt and any error notice it produces.
    let onStartRequested: () -> Void
    @State private var isHovering = false
    @StateObject private var guardian = OllamaGuardian.shared

    var body: some View {
        Button(action: {
            if !isConnected {
                onStartRequested()
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
        .help((guardian.status == .running || isConnected) ? "Ollama service running" : "Click to start Ollama")
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
