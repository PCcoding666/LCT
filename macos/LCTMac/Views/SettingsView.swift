import SwiftUI

/// Settings view for configuring the application
struct SettingsView: View {
    @Binding var settings: AppSettings
    let onSave: (AppSettings) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var localSettings: AppSettings
    
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
                    Picker("Engine", selection: $localSettings.preferredEngine) {
                        ForEach(SpeechEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    
                    if localSettings.preferredEngine == .whisper {
                        Picker("Model Size", selection: $localSettings.whisperModelSize) {
                            ForEach(WhisperModelSize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        
                        Toggle("Enable Speaker Diarization", isOn: $localSettings.enableDiarization)
                    }
                }
                
                // Ollama Settings
                Section("Ollama Configuration") {
                    TextField("Host", text: $localSettings.ollamaHost)
                    
                    HStack {
                        Text("Port")
                        TextField("Port", value: $localSettings.ollamaPort, format: .number)
                            .frame(width: 100)
                    }
                    
                    TextField("Model Name", text: $localSettings.ollamaModel)
                    
                    HStack {
                        Text("Timeout (seconds)")
                        TextField("Timeout", value: $localSettings.ollamaTimeout, format: .number)
                            .frame(width: 100)
                    }
                    
                    HStack {
                        Text("Temperature")
                        Slider(value: $localSettings.ollamaTemperature, in: 0...1, step: 0.1)
                        Text(String(format: "%.1f", localSettings.ollamaTemperature))
                            .frame(width: 40)
                    }
                }
                
                // Translation Settings
                Section("Translation") {
                    Picker("Target Language", selection: $localSettings.targetLanguage) {
                        ForEach(TargetLanguage.allCases) { language in
                            Text("\(language.displayName) (\(language.nativeName))").tag(language)
                        }
                    }
                    
                    Toggle("Context-Aware Translation", isOn: $localSettings.contextAware)
                    
                    if localSettings.contextAware {
                        HStack {
                            Text("Max Context Entries")
                            Stepper("\(localSettings.maxContextEntries)", value: $localSettings.maxContextEntries, in: 1...10)
                        }
                    }
                }
                
                // UI Settings
                Section("Display") {
                    Toggle("Show Overlay Window", isOn: $localSettings.showOverlay)
                    
                    HStack {
                        Text("Overlay Opacity")
                        Slider(value: $localSettings.overlayOpacity, in: 0.3...1.0, step: 0.05)
                        Text(String(format: "%.0f%%", localSettings.overlayOpacity * 100))
                            .frame(width: 50)
                    }
                    
                    HStack {
                        Text("Font Size")
                        Slider(value: $localSettings.overlayFontSize, in: 10...24, step: 1)
                        Text(String(format: "%.0f pt", localSettings.overlayFontSize))
                            .frame(width: 50)
                    }
                    
                    Toggle("Show Latency", isOn: $localSettings.showLatency)
                    
                    HStack {
                        Text("Max Display Cards")
                        Stepper("\(localSettings.maxDisplayCards)", value: $localSettings.maxDisplayCards, in: 1...20)
                    }
                }
                
                // Advanced Settings
                Section("Advanced") {
                    TextField("Python Path", text: $localSettings.pythonPath)
                    SecureField("Hugging Face Token", text: $localSettings.huggingFaceToken)
                        .help("Required for Pyannote speaker diarization")
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
        .frame(width: 550, height: 650)
    }
}

#Preview {
    SettingsView(settings: .constant(AppSettings())) { _ in }
}
