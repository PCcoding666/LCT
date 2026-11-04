import SwiftUI
import Speech
import AVFoundation

/// Settings view for configuring the application
@MainActor
struct SettingsView: View {
    @Binding var settings: AppSettings
    let onSave: (AppSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localSettings: AppSettings
    @State private var showingPromptEditor = false
    @State private var diagnosticsMessage: String?
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var languageAvailability: [SourceLanguage: LanguageAvailability] = [:]

    init(settings: Binding<AppSettings>, onSave: @escaping (AppSettings) -> Void) {
        self._settings = settings
        self.onSave = onSave
        self._localSettings = State(initialValue: settings.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Done") {
                    onSave(localSettings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!localSettings.captureSystemAudio && !localSettings.captureMicrophone)
            }
            .padding()

            Divider()

            // Settings form
            Form {
                basicSections
                advancedSections
                diagnosticsSection
            }
            .formStyle(.grouped)

            Divider()

            // Footer with reset button
            HStack {
                Button("Reset to Defaults") {
                    localSettings = AppSettings()
                }
                .foregroundStyle(.red)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()
        }
        .frame(width: 550, height: 620)
        .sheet(isPresented: $showingPromptEditor) {
            PromptEditorView(prompt: $localSettings.customPrompt)
        }
        .task {
            refreshInputDevices()
            let kind = SpeechEngineSelection.engineKind(transcriberEngineAvailable: SpeechEngineAvailability.isTranscriberEngineAvailable)
            let engine = SpeechEngineFactory.makeEngine(kind: kind, language: localSettings.sourceLanguage)
            languageAvailability = await engine.languageAvailability()
        }
    }

    // MARK: - Basic Sections

    @ViewBuilder
    private var basicSections: some View {
        Section("Audio Capture") {
            Toggle("Capture System Audio", isOn: $localSettings.captureSystemAudio)
            Toggle("Capture Microphone", isOn: $localSettings.captureMicrophone)

            Picker("Microphone Device", selection: $localSettings.microphoneDeviceUID) {
                Text("System Default (\(systemDefaultInputName))").tag(String?.none)
                ForEach(inputDevices) { device in
                    Text(device.isVirtual ? "\(device.name) (virtual)" : device.name)
                        .tag(String?.some(device.uid))
                }
            }
            .help("Which input device LCT listens to for microphone capture")
            .disabled(!localSettings.captureMicrophone)
        }

        Section("Language") {
            Picker("System Audio Language", selection: $localSettings.sourceLanguage) {
                ForEach(SourceLanguage.allCases) { language in
                    HStack {
                        Text(language.displayName)
                        if languageAvailability[language] != nil && !isLanguageAvailable(language) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .tag(language)
                }
            }
            .help("The language being spoken on the system audio that you want to recognize")

            if let availability = languageAvailability[localSettings.sourceLanguage], availability != .installed {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(availability == .downloadable
                         ? "This speech language needs an Apple on-device resource. LCT will request the download when you start captions; an internet connection is needed for that download."
                         : "This language is not available for on-device speech on this Mac. Choose another language or install its speech resources in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Picker("Microphone Language", selection: $localSettings.microphoneSourceLanguage) {
                Text("Same as System Audio").tag(SourceLanguage?.none)
                ForEach(SourceLanguage.allCases) { language in
                    Text(language.displayName).tag(SourceLanguage?.some(language))
                }
            }
            .help("The language to recognize on the microphone — by default it follows the system audio language")

            Picker("Target Language", selection: $localSettings.targetLanguage) {
                ForEach(TargetLanguage.allCases) { language in
                    Text("\(language.displayName) (\(language.nativeName))").tag(language)
                }
            }
            .help("The language to translate into")
        }

        Section("Local Translation") {
            LocalTranslationControls(enabled: $localSettings.translationEnabled)
        }
    }

    // MARK: - Advanced Sections

    @ViewBuilder
    private var advancedSections: some View {
        Section("Advanced") {
            DisclosureGroup("Translation Tuning") {
                HStack {
                    Text("Temperature")
                    Slider(value: $localSettings.ollamaTemperature, in: 0...1, step: 0.1)
                    Text(String(format: "%.1f", localSettings.ollamaTemperature))
                }
                Toggle("Use Previous Captions as Context", isOn: $localSettings.contextAware)
                Button("Edit Translation Prompt…") { showingPromptEditor = true }
            }

            DisclosureGroup("Display & Overlay") {
                Toggle("Show Latency", isOn: $localSettings.showLatency)

                HStack {
                    Text("Max Display Cards")
                    Stepper("\(localSettings.maxDisplayCards)", value: $localSettings.maxDisplayCards, in: 1...20)
                }

                HStack {
                    Text("Overlay Opacity")
                    Slider(value: $localSettings.overlayOpacity, in: 0.3...1.0, step: 0.05)
                    Text(String(format: "%.0f%%", localSettings.overlayOpacity * 100))
                        .frame(width: 50)
                        .monospacedDigit()
                }

                HStack {
                    Text("Overlay Font Size")
                    Slider(value: $localSettings.overlayFontSize, in: 10...24, step: 1)
                    Text(String(format: "%.0f pt", localSettings.overlayFontSize))
                        .frame(width: 50)
                        .monospacedDigit()
                }

                Toggle("Overlay Stays on Top", isOn: $localSettings.overlayStayOnTop)
                    .help("Keep overlay window above all other windows")

                Toggle("Overlay Click Through", isOn: $localSettings.overlayClickThrough)
                    .help("Allow clicks to pass through the overlay window")
            }

            DisclosureGroup("History") {
                Toggle("Keep Translation History", isOn: $localSettings.historyEnabled)
                    .help("Save transcripts and translations on this Mac (off by default)")

                Text("History is off by default. When enabled, transcripts and translations are stored on this Mac only — never sent anywhere. Turning it off keeps existing entries but stops saving new ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Retention")
                    Stepper("\(localSettings.historyRetentionDays) days", value: $localSettings.historyRetentionDays, in: 1...365)
                }
                .help("Automatically remove history entries older than this many days")
                .disabled(!localSettings.historyEnabled)

                HStack {
                    Text("Max Entries")
                    Stepper("\(localSettings.historyMaxEntries)", value: $localSettings.historyMaxEntries, in: 100...50000, step: 100)
                }
                .help("Keep only the newest history entries after each successful translation")
                .disabled(!localSettings.historyEnabled)
            }
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            HStack {
                Button("Export Diagnostics…") {
                    exportDiagnostics()
                }

                Button("Show Log File") {
                    let logURL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/LCTMac.log")
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }

                Spacer()
            }

            if let message = diagnosticsMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemDefaultInputName: String {
        inputDevices.first(where: { $0.isSystemDefault })?.name ?? "unavailable"
    }

    private func refreshInputDevices() {
        inputDevices = AudioInputDevices.listInputDevices()
    }

    // MARK: - Diagnostics Export

    private func exportDiagnostics() {
        let report = buildDiagnosticsReport()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LCT-diagnostics.txt"
        panel.title = "Export Diagnostics"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            diagnosticsMessage = "Diagnostics saved. Attach this file when reporting issues."
        } catch {
            diagnosticsMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func buildDiagnosticsReport() -> String {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let screenStatus = CGPreflightScreenCaptureAccess()

        let service = EmbeddedTranslationService.shared
        return [
            "LCT Diagnostics Report (metadata only)",
            "Version: \(appVersion) (\(buildNumber))",
            "macOS: \(osVersion)",
            "Microphone: \(describe(micStatus))",
            "Speech Recognition: \(describe(speechStatus))",
            "Screen Recording (fallback only): \(screenStatus)",
            "System Audio: \(SystemAudioAuthorizationStore.lastResult()?.rawValue ?? "unknown")",
            "Capture: systemAudio=\(localSettings.captureSystemAudio) microphone=\(localSettings.captureMicrophone)",
            "Translation: enabled=\(localSettings.translationEnabled) ready=\(service.isReady)",
            "Runtime: embedded llama.cpp",
            "Model: \(EmbeddedTranslationService.modelName), downloaded=\(service.isModelDownloaded)",
            "Languages: \(localSettings.sourceLanguage.displayName) → \(localSettings.targetLanguage.displayName)",
            "History enabled: \(localSettings.historyEnabled)",
            "No transcripts, translations, or log contents are included."
        ].joined(separator: "\n")
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Helpers

    private func isLanguageAvailable(_ language: SourceLanguage) -> Bool {
        // On macOS 26 the selected engine's inventory is authoritative;
        // the legacy recognizer alone can incorrectly label installed assets.
        languageAvailability[language] == .installed
    }
}

/// Prompt editor sheet
@MainActor
struct PromptEditorView: View {
    @Binding var prompt: String
    @Environment(\.dismiss) private var dismiss
    @State private var localPrompt: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Translation Prompt")
                    .font(.headline)

                Spacer()

                Button("Done") {
                    prompt = localPrompt
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Customize the system prompt for translation. Use {TARGET_LANGUAGE} as a placeholder for the target language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $localPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                HStack {
                    Button("Reset to Default") {
                        localPrompt = ""
                    }

                    Spacer()

                    Button("Preview Default") {
                        localPrompt = AppSettings.defaultPrompt
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .onAppear {
            localPrompt = prompt
        }
    }
}
