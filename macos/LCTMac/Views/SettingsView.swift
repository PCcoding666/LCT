import SwiftUI
import Speech

/// Settings view for configuring the application
struct SettingsView: View {
    @Binding var settings: AppSettings
    let onSave: (AppSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localSettings: AppSettings
    @State private var showingPromptEditor = false

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
            }
            .padding()

            Divider()

            // Settings form
            Form {
                // Audio Settings
                Section("Audio Capture") {
                    Toggle("Capture System Audio", isOn: $localSettings.captureSystemAudio)
                    Toggle("Capture Microphone", isOn: $localSettings.captureMicrophone)
                }

                // Speech Recognition
                Section("Speech Recognition") {
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
                            Text("This language may not be available on your device")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // Ollama Settings
                Section("Ollama Configuration") {
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

                    HStack {
                        Text("Model")
                        TextField("Model Name", text: $localSettings.ollamaModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    .help("e.g., qwen2.5:3b, llama3.2:3b, gemma2:2b")

                    Picker("Model Type", selection: $localSettings.translationModelType) {
                        ForEach(TranslationModelType.allCases) { type in
                            VStack(alignment: .leading) {
                                Text(type.displayName)
                            }
                            .tag(type)
                        }
                    }
                    .help("Standard uses chat prompts; TranslateGemma uses specialized translation format")

                    HStack {
                        Text("Timeout")
                        TextField("Timeout", value: $localSettings.ollamaTimeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    HStack {
                        Text("Temperature")
                        Slider(value: $localSettings.ollamaTemperature, in: 0...1, step: 0.1)
                        Text(String(format: "%.1f", localSettings.ollamaTemperature))
                            .frame(width: 40)
                            .monospacedDigit()
                    }
                    .help("Lower = more consistent, Higher = more creative")
                }

                // Translation Settings
                Section("Translation") {
                    Picker("Target Language", selection: $localSettings.targetLanguage) {
                        ForEach(TargetLanguage.allCases) { language in
                            Text("\(language.displayName) (\(language.nativeName))").tag(language)
                        }
                    }
                    .help("The language to translate into")

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

                // History Settings
                Section("History") {
                    HStack {
                        Text("Retention")
                        Stepper("\(localSettings.historyRetentionDays) days", value: $localSettings.historyRetentionDays, in: 1...365)
                    }
                    .help("Automatically remove history entries older than this many days")

                    HStack {
                        Text("Max Entries")
                        Stepper("\(localSettings.historyMaxEntries)", value: $localSettings.historyMaxEntries, in: 100...50000, step: 100)
                    }
                    .help("Keep only the newest history entries after each successful translation")
                }

                // UI Settings
                Section("Display") {
                    Toggle("Show Overlay Window", isOn: $localSettings.showOverlay)

                    HStack {
                        Text("Overlay Opacity")
                        Slider(value: $localSettings.overlayOpacity, in: 0.3...1.0, step: 0.05)
                        Text(String(format: "%.0f%%", localSettings.overlayOpacity * 100))
                            .frame(width: 50)
                            .monospacedDigit()
                    }

                    HStack {
                        Text("Font Size")
                        Slider(value: $localSettings.overlayFontSize, in: 10...24, step: 1)
                        Text(String(format: "%.0f pt", localSettings.overlayFontSize))
                            .frame(width: 50)
                            .monospacedDigit()
                    }

                    Toggle("Show Latency", isOn: $localSettings.showLatency)

                    HStack {
                        Text("Max Display Cards")
                        Stepper("\(localSettings.maxDisplayCards)", value: $localSettings.maxDisplayCards, in: 1...20)
                    }

                    HStack {
                        Text("Caption Log Max")
                        Stepper("\(localSettings.captionLogMax)", value: $localSettings.captionLogMax, in: 1...10)
                    }
                    .help("Number of recent captions shown in main view")
                }

                // Overlay Advanced Settings
                Section("Overlay Advanced") {
                    Toggle("Stay on Top", isOn: $localSettings.overlayStayOnTop)
                        .help("Keep overlay window above all other windows")

                    Toggle("Click Through", isOn: $localSettings.overlayClickThrough)
                        .help("Allow clicks to pass through the overlay window")

                    ColorPicker("Text Color", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: localSettings.overlayTextColor) ?? .white) },
                        set: { newColor in
                            localSettings.overlayTextColor = NSColor(newColor).toHexString()
                        }
                    ))

                    ColorPicker("Background Color", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: localSettings.overlayBackgroundColor) ?? .black) },
                        set: { newColor in
                            localSettings.overlayBackgroundColor = NSColor(newColor).toHexString()
                        }
                    ))

                    HStack {
                        Text("Window Size")
                        Text("\(Int(localSettings.overlayWidth)) × \(Int(localSettings.overlayHeight))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                        Spacer()
                    }
                }
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
        .frame(width: 550, height: 600)
        .sheet(isPresented: $showingPromptEditor) {
            PromptEditorView(prompt: $localSettings.customPrompt)
        }
    }

    // MARK: - Helpers

    private func isLanguageAvailable(_ language: SourceLanguage) -> Bool {
        let locale = Locale(identifier: language.isoCode)
        return SFSpeechRecognizer(locale: locale) != nil
    }
}

/// Prompt editor sheet
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
