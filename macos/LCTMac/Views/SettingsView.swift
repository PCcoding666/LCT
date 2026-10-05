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
    @State private var installedModels: [String] = []
    @State private var modelListError: String?
    @State private var isLoadingModels = false
    @State private var diagnosticsMessage: String?

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
                .disabled(localSettings.ollamaEndpointError != nil)
                .help(localSettings.ollamaEndpointError ?? "")
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
            await refreshInstalledModels()
        }
    }

    // MARK: - Basic Sections

    @ViewBuilder
    private var basicSections: some View {
        Section("Audio Capture") {
            Toggle("Capture System Audio", isOn: $localSettings.captureSystemAudio)
            Toggle("Capture Microphone", isOn: $localSettings.captureMicrophone)
        }

        Section("Language") {
            Picker("Source Language", selection: $localSettings.sourceLanguage) {
                ForEach(SourceLanguage.allCases) { language in
                    HStack {
                        Text(language.displayName)
                        if !isLanguageAvailable(language) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .tag(language)
                }
            }
            .help("The language being spoken that you want to recognize")

            if !isLanguageAvailable(localSettings.sourceLanguage) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("This language has no on-device speech model on your Mac. Download it in System Settings, or choose another language. LCT only recognizes speech on-device.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Picker("Target Language", selection: $localSettings.targetLanguage) {
                ForEach(TargetLanguage.allCases) { language in
                    Text("\(language.displayName) (\(language.nativeName))").tag(language)
                }
            }
            .help("The language to translate into")
        }

        Section("Translation Model") {
            if installedModels.isEmpty {
                HStack {
                    Text("Model")
                    TextField("Model Name", text: $localSettings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                }
                .help("e.g., qwen3.5:4b-mlx, qwen2.5:3b, gemma2:2b")
            } else {
                Picker("Model", selection: $localSettings.ollamaModel) {
                    ForEach(installedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    if !installedModels.contains(localSettings.ollamaModel) {
                        Text("\(localSettings.ollamaModel) (not installed)")
                            .tag(localSettings.ollamaModel)
                    }
                }
                .help("Models currently installed in Ollama")
            }

            HStack {
                if isLoadingModels {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text("Checking installed models…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = modelListError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(installedModels.count) model(s) installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refresh") {
                    Task { await refreshInstalledModels() }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Advanced Sections

    @ViewBuilder
    private var advancedSections: some View {
        Section("Advanced") {
            DisclosureGroup("Ollama Connection") {
                HStack {
                    Text("Host")
                    TextField("Host", text: $localSettings.ollamaHost)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Port")
                    TextField("Port", value: $localSettings.ollamaPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Spacer()
                }

                Toggle("Allow Remote Ollama (HTTPS only)", isOn: $localSettings.remoteOllamaOptIn)
                    .help("Explicit consent required before connecting to a non-local Ollama server. Remote servers are only contacted over HTTPS.")

                Text("Local servers (localhost/127.0.0.1) use HTTP. Remote servers require this explicit opt-in and are only contacted over HTTPS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let endpointError = localSettings.ollamaEndpointError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(endpointError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Text("Timeout")
                    TextField("Timeout", value: $localSettings.ollamaTimeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            DisclosureGroup("Translation Tuning") {
                Picker("Model Type", selection: $localSettings.translationModelType) {
                    ForEach(TranslationModelType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .help("Standard uses chat prompts; TranslateGemma uses specialized translation format")

                HStack {
                    Text("Temperature")
                    Slider(value: $localSettings.ollamaTemperature, in: 0...1, step: 0.1)
                    Text(String(format: "%.1f", localSettings.ollamaTemperature))
                        .frame(width: 40)
                        .monospacedDigit()
                }
                .help("Lower = more consistent, Higher = more creative")

                Toggle("Live Draft Translation", isOn: $localSettings.liveDraftTranslation)
                    .help("Translate speech as it's being spoken for lower latency, instead of waiting for each sentence to finish")

                Toggle("Context-Aware Translation", isOn: $localSettings.contextAware)
                    .help("Use previous translations for better context")

                if localSettings.contextAware {
                    HStack {
                        Text("Max Context Entries")
                        Stepper("\(localSettings.maxContextEntries)", value: $localSettings.maxContextEntries, in: 1...10)
                    }
                }

                HStack {
                    Text("Custom Prompt")
                    Spacer()
                    Button(localSettings.customPrompt.isEmpty ? "Use Default" : "Customized") {
                        showingPromptEditor = true
                    }
                    .buttonStyle(.bordered)
                }
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

    // MARK: - Installed Models

    private func refreshInstalledModels() async {
        isLoadingModels = true
        modelListError = nil
        defer { isLoadingModels = false }

        guard let endpoint = localSettings.validatedOllamaEndpoint else {
            modelListError = localSettings.ollamaEndpointError ?? "Invalid Ollama address"
            return
        }
        let url = endpoint.baseURL.appendingPathComponent("api/tags")

        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(TagsResponse.self, from: data)
            installedModels = response.models.map(\.name).sorted()
            if installedModels.isEmpty {
                modelListError = "No models installed — run: ollama pull \(RecommendedModel.defaultModel.name)"
            }
        } catch {
            installedModels = []
            modelListError = "Cannot reach Ollama — start it or check Advanced › Ollama Connection"
        }
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

        let guardian = OllamaGuardian.shared
        let historyEntryCount = (try? HistoryService().getCount()) ?? 0

        return DiagnosticsReport.build(
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
            microphoneStatus: describe(micStatus),
            speechStatus: describe(speechStatus),
            screenRecordingGranted: screenStatus,
            ollamaURL: localSettings.ollamaURL,
            ollamaIsLocal: localSettings.isLocalOllama,
            modelName: localSettings.ollamaModel,
            modelType: localSettings.translationModelType.displayName,
            sourceLanguage: localSettings.sourceLanguage.displayName,
            targetLanguage: localSettings.targetLanguage.displayName,
            captureSystemAudio: localSettings.captureSystemAudio,
            captureMicrophone: localSettings.captureMicrophone,
            ollamaStatus: guardian.status.displayText,
            ollamaVersion: guardian.ollamaVersion ?? "unknown",
            installedModels: installedModels,
            historyEnabled: localSettings.historyEnabled,
            historyEntryCount: historyEntryCount
        )
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
        let locale = Locale(identifier: language.isoCode)
        // LCT requires on-device recognition, so availability means the
        // on-device model is present — not just that a recognizer exists.
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
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
