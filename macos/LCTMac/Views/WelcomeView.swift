import SwiftUI
import Speech
import AVFoundation

/// Persists the onboarding step across an app relaunch so the setup flow
/// resumes where the user left off. Retained for its tests; no current UI
/// writes to it (the screen-recording restart flow that used it is gone —
/// system audio capture no longer needs that permission).
enum OnboardingResumeStore {
    static let key = "onboardingResumeStep"

    static func save(stepID: String, defaults: UserDefaults = .standard) {
        defaults.set(stepID, forKey: key)
    }

    /// Returns the saved step and removes it, so a stale value can never
    /// trap the setup flow in a resume loop.
    static func consume(defaults: UserDefaults = .standard) -> String? {
        guard let stepID = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return stepID
    }
}

/// Which model onboarding settles on, and the persistence of that choice.
/// Free of SwiftUI so the decision logic stays testable.
enum OnboardingModelSelection {
    /// The model to use when Ollama already has compatible ones installed:
    /// the recommendation wins, otherwise the first installed alternative.
    static func preferredInstalledModel(
        recommendation: ModelRecommendation,
        isInstalled: (String) -> Bool
    ) -> String? {
        if isInstalled(recommendation.recommended.name) {
            return recommendation.recommended.name
        }
        return recommendation.alternatives.first { isInstalled($0.name) }?.name
    }

    /// Write the chosen model into settings. Returns an error message when
    /// the save fails — onboarding must not silently complete with a model
    /// the capture flow will not use.
    @discardableResult
    static func saveChosenModel(_ modelName: String) -> String? {
        var settings = AppSettings.load()
        settings.ollamaModel = modelName
        guard settings.save() else {
            return AppSettings.consumeLastPersistenceError() ?? "Failed to save the selected model."
        }
        return nil
    }
}

/// Captions-first setup. Translation preparation is optional and lives in Settings.
@MainActor
struct WelcomeView: View {
    // Persisted identifiers from older onboarding versions remain decodable.
    // The current UI only uses welcome and permissions; no service setup runs.
    enum SetupStep: String {
        case welcome, permissions, checkingOllama, ollamaNotInstalled
        case modelMissing, remoteOllama, downloadingModel, complete
    }

    @State private var showPermissions = false
    @State private var setupSettings = AppSettings.load()
    @State private var hasMicrophonePermission = false
    @State private var hasSpeechRecognitionPermission = false
    @State private var systemAudioPermission: SystemAudioPermissionRow.State = .unknown
    @State private var setupError: String?
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.largeTitle).foregroundStyle(HUD.accent)
                VStack(alignment: .leading) {
                    Text("LCT for macOS").font(.title2.weight(.semibold))
                    Text("Live captions, on your Mac").foregroundStyle(.secondary)
                }
                Spacer()
                Text(showPermissions ? "2 / 2" : "1 / 2").foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if showPermissions { permissionsContent } else { welcomeContent }
                    if let setupError {
                        Text(setupError).foregroundStyle(.red).font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            Divider()
            HStack {
                if showPermissions {
                    Button("Back") { showPermissions = false }
                }
                Spacer()
                Button(showPermissions ? "Open Captions" : "Set Up Captions") {
                    if showPermissions { finishSetup() } else { showPermissions = true }
                }
                .buttonStyle(.borderedProminent)
                .tint(HUD.accent)
                .disabled(showPermissions && !canContinue)
            }
            .padding(20)
        }
        .frame(width: 600, height: 600)
        .preferredColorScheme(.dark)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Start with captions.").font(.largeTitle.bold())
            Text("Read videos, meetings, or your microphone in real time. No translation model is needed to begin.")
                .font(.title3).foregroundStyle(.secondary)
            FeatureRow(icon: "waveform", title: "Original captions first", description: "Apple speech recognition runs locally. Some languages need a one-time speech download.")
            FeatureRow(icon: "character.bubble", title: "Translation when you want it", description: "Download a local translation model in Settings. Captions keep working while it prepares.")
            FeatureRow(icon: "lock.shield", title: "Private by default", description: "Audio and captions stay on your Mac. History is saved only if you enable it.")
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose what to caption").font(.title2.bold())
            Toggle("System audio — videos and meetings", isOn: $setupSettings.captureSystemAudio)
            Toggle("Microphone — your voice", isOn: $setupSettings.captureMicrophone)
            Picker("Spoken language", selection: $setupSettings.sourceLanguage) {
                ForEach(SourceLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Divider()
            PermissionRow(icon: "waveform", title: "Speech Recognition", description: "Convert speech into original captions", isGranted: hasSpeechRecognitionPermission, isChecking: false, onGrant: requestSpeechPermission)
            if setupSettings.captureSystemAudio {
                SystemAudioPermissionRow(state: systemAudioPermission, onAllow: requestSystemPermission, onOpenSettings: { AudioCaptureService.openSystemAudioSettings() })
            }
            if setupSettings.captureMicrophone {
                PermissionRow(icon: "mic.fill", title: "Microphone", description: "Required only for microphone captions", isGranted: hasMicrophonePermission, isChecking: false, onGrant: requestMicrophonePermission)
            }
            Text("Speech language resources are checked when you start. Translation has a separate optional download in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canContinue: Bool {
        (setupSettings.captureSystemAudio || setupSettings.captureMicrophone)
            && hasSpeechRecognitionPermission
            && (!setupSettings.captureMicrophone || hasMicrophonePermission)
    }

    private func refreshPermissions() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasSpeechRecognitionPermission = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private func requestMicrophonePermission() {
        Task { hasMicrophonePermission = await AVCaptureDevice.requestAccess(for: .audio) }
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in hasSpeechRecognitionPermission = status == .authorized }
        }
    }

    private func requestSystemPermission() {
        guard systemAudioPermission != .probing else { return }
        systemAudioPermission = .probing
        Task.detached {
            let result = await SystemAudioPermissionProbe.run()
            await MainActor.run { systemAudioPermission = result == .granted ? .granted : .denied }
        }
    }

    private func finishSetup() {
        setupSettings.translationEnabled = false
        guard setupSettings.save() else {
            setupError = AppSettings.consumeLastPersistenceError() ?? "Could not save settings. Please try again."
            return
        }
        AppSettings.markSetupComplete()
        onComplete()
    }
}

// MARK: - Supporting Views

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let isChecking: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isChecking {
                ProgressView()
                    .scaleEffect(0.8)
            } else if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            } else {
                Button("Grant") {
                    onGrant()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// The optional system-audio row. macOS has no preflight for the tap's TCC
/// consent — it answers only by delivering or withholding IO callbacks — so
/// Allow runs a real probe (see `SystemAudioPermissionProbe`), and the only
/// remediation for a denial is the Settings pane.
@MainActor
struct SystemAudioPermissionRow: View {
    enum State: Equatable {
        case unknown
        case probing
        case granted
        case denied
    }

    let state: State
    let onAllow: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title2)
                .foregroundStyle(state == .granted ? .green : .orange)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("System Audio")
                        .font(.headline)
                    Text("Recommended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Caption audio from videos and meetings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch state {
            case .unknown:
                Button("Allow") {
                    onAllow()
                }
                .buttonStyle(.bordered)
            case .probing:
                ProgressView()
                    .scaleEffect(0.8)
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            case .denied:
                HStack(spacing: 8) {
                    Text("Denied")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
