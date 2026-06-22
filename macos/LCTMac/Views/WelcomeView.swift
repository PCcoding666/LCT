import SwiftUI
import Speech
import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Welcome/Setup view for first-time users
@MainActor
struct WelcomeView: View {
    @StateObject private var guardian = OllamaGuardian.shared
    @StateObject private var modelManager = OllamaModelManager()
    
    @State private var currentStep: SetupStep = .welcome
    @State private var isSettingUp = false
    @State private var setupError: String?
    @State private var remoteHost = ""
    @State private var remotePortText = "11434"
    @State private var remoteModel = RecommendedModel.defaultModel.name
    @State private var readyModelName = RecommendedModel.defaultModel.name
    @State private var setupSkipped = false
    
    // Permission states
    @State private var hasScreenCapturePermission = false
    @State private var hasMicrophonePermission = false
    @State private var hasSpeechRecognitionPermission = false
    @State private var isCheckingPermissions = false
    /// Set once the user has triggered the screen-recording prompt; until the
    /// app restarts, CGPreflight keeps returning false even after granting.
    @State private var screenRecordingRequested = false
    
    /// Default model to use
    private let defaultModel = RecommendedModel.defaultModel
    
    let onComplete: () -> Void
    
    enum SetupStep {
        case welcome
        case permissions
        case checkingOllama
        case ollamaNotInstalled
        case modelMissing
        case remoteOllama
        case downloadingModel
        case complete
    }

    private struct RemoteOllamaConfig {
        let host: String
        let port: Int
        let baseURL: String
        let model: String
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    switch currentStep {
                    case .welcome:
                        welcomeContent
                    case .permissions:
                        permissionsContent
                    case .checkingOllama:
                        checkingOllamaContent
                    case .ollamaNotInstalled:
                        ollamaNotInstalledContent
                    case .modelMissing:
                        modelMissingContent
                    case .remoteOllama:
                        remoteOllamaContent
                    case .downloadingModel:
                        downloadingModelContent
                    case .complete:
                        completeContent
                    }
                }
                .padding(32)
            }
            
            Divider()
            
            // Footer
            footerView
        }
        .frame(width: 600, height: 560)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading) {
                Text("LCT for macOS")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Live Captions Translator")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Step indicator
            stepIndicator
        }
        .padding()
    }
    
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<4) { index in
                Circle()
                    .fill(stepColor(for: index))
                    .frame(width: 8, height: 8)
            }
        }
    }
    
    private func stepColor(for index: Int) -> Color {
        let currentIndex = stepIndex
        if index < currentIndex {
            return .green
        } else if index == currentIndex {
            return .blue
        } else {
            return .gray.opacity(0.3)
        }
    }
    
    private var stepIndex: Int {
        switch currentStep {
        case .welcome: return 0
        case .permissions: return 1
        case .checkingOllama, .ollamaNotInstalled, .modelMissing, .remoteOllama, .downloadingModel: return 2
        case .complete: return 3
        }
    }
    
    // MARK: - Welcome Content
    
    private var welcomeContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Welcome to LCT")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Real-time speech recognition and translation powered by local AI")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "waveform", title: "Speech Recognition", description: "Apple's native speech recognition")
                FeatureRow(icon: "globe", title: "Local Translation", description: "Private, offline translation with Ollama")
                FeatureRow(icon: "lock.shield", title: "Privacy First", description: "All processing happens on your device")
            }
            .padding(.top, 16)
        }
    }
    
    // MARK: - Permissions Content
    
    private var permissionsContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Permissions Required")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Grant microphone and speech recognition to get started. Screen recording is optional — it lets LCT caption audio from videos and meetings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 16) {
                // Microphone Permission (required)
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Capture your voice",
                    isGranted: hasMicrophonePermission,
                    isChecking: isCheckingPermissions,
                    onGrant: requestMicrophonePermission
                )

                // Speech Recognition Permission (required)
                PermissionRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    description: "Convert speech to text",
                    isGranted: hasSpeechRecognitionPermission,
                    isChecking: isCheckingPermissions,
                    onGrant: requestSpeechRecognitionPermission
                )

                Divider()

                // Screen Recording Permission (optional — needs a restart to take effect)
                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Capture audio from videos & meetings",
                    isGranted: hasScreenCapturePermission,
                    isChecking: isCheckingPermissions,
                    isOptional: true,
                    pendingRestart: screenRecordingRequested && !hasScreenCapturePermission,
                    onGrant: requestScreenCapturePermission,
                    onRestart: relaunchApp
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if screenRecordingRequested && !hasScreenCapturePermission {
                Text("macOS requires a restart for screen recording to take effect. You can also continue with microphone only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            Task {
                await checkAllPermissions()
            }
        }
        // Auto-refresh when coming back from System Settings
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if currentStep == .permissions {
                print("[WelcomeView] App became active. Auto-checking permissions...")
                Task {
                    await checkAllPermissions()
                }
            }
        }
    }
    
    /// Only microphone + speech recognition are required to proceed. Screen
    /// recording is optional (microphone-only mode covers the rest).
    private var requiredPermissionsGranted: Bool {
        hasMicrophonePermission && hasSpeechRecognitionPermission
    }
    
    // MARK: - Checking Ollama Content
    
    private var checkingOllamaContent: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Setting up...")
                .font(.title2)
            
            Text("Checking Ollama and preparing translation model")
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Ollama Not Installed Content
    
    private var ollamaNotInstalledContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            
            Text("Ollama Required")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Install Ollama locally or connect LCT to an existing Ollama server.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 12) {
                Button(action: {
                    guardian.openInstallationPage()
                }) {
                    Label("Download Ollama", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    remoteHost = ""
                    remotePortText = "11434"
                    remoteModel = defaultModel.name
                    setupError = nil
                    currentStep = .remoteOllama
                }) {
                    Label("Use Remote Ollama Server", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Text("After installing Ollama locally, click 'Check Again' below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Model Missing Content

    private var modelMissingContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Translation Model Required")
                .font(.title)
                .fontWeight(.bold)

            Text("Ollama is running, but \(defaultModel.displayName) is not installed.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Model")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(defaultModel.name)
                        .monospaced()
                }

                HStack {
                    Text("Download Size")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(defaultModel.size)
                }

                Divider()

                Text("Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("ollama pull \(defaultModel.name)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - Remote Ollama Content

    private var remoteOllamaContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "network")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Remote Ollama Server")
                .font(.title)
                .fontWeight(.bold)

            Text("Connect to a reachable Ollama API that already has the translation model installed.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                Text("Host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("192.168.1.20", text: $remoteHost)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Port")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("11434", text: $remotePortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(defaultModel.name, text: $remoteModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Text("LCT will verify /api/tags and save this endpoint if the model is present.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Downloading Model Content
    
    private var downloadingModelContent: some View {
        VStack(spacing: 24) {
            if modelManager.pullProgress < 1.0 {
                ProgressView(value: modelManager.pullProgress) {
                    Text("Downloading \(defaultModel.displayName)")
                        .font(.headline)
                } currentValueLabel: {
                    Text(modelManager.pullStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .progressViewStyle(.linear)
                
                Text("\(Int(modelManager.pullProgress * 100))%")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .monospacedDigit()
                
                Text("Size: \(defaultModel.size)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                
                Text("Download Complete!")
                    .font(.title)
                    .fontWeight(.bold)
            }
            
            if modelManager.isPulling {
                Button("Cancel") {
                    modelManager.cancelPull()
                    currentStep = .modelMissing
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    // MARK: - Complete Content
    
    private var completeContent: some View {
        VStack(spacing: 24) {
            Image(systemName: setupSkipped ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(setupSkipped ? .orange : .green)
            
            Text(setupSkipped ? "Setup Skipped" : "You're All Set!")
                .font(.title)
                .fontWeight(.bold)
            
            Text(setupSkipped ? "Configure Ollama in Settings before starting translation." : "LCT is ready to use. Click 'Get Started' to begin translating.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if !setupSkipped {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Ollama connection is ready")
                    }

                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Model '\(readyModelName)' is ready")
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack {
            if currentStep == .ollamaNotInstalled || currentStep == .modelMissing {
                Button("Check Again") {
                    Task {
                        await checkOllama()
                    }
                }
            }

            if currentStep == .remoteOllama {
                Button("Back") {
                    setupError = nil
                    currentStep = .ollamaNotInstalled
                }
            }
            
            Spacer()
            
            if let error = setupError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            
            Spacer()
            
            Button(action: nextStep) {
                Text(nextButtonTitle)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSettingUp || (currentStep == .downloadingModel && modelManager.isPulling))
        }
        .padding()
    }
    
    private var nextButtonTitle: String {
        switch currentStep {
        case .welcome:
            return "Get Started"
        case .permissions:
            return requiredPermissionsGranted ? "Continue" : "Skip for Now"
        case .checkingOllama:
            return "Setting up..."
        case .ollamaNotInstalled:
            return "Skip for Now"
        case .modelMissing:
            return "Install Model"
        case .remoteOllama:
            return isSettingUp ? "Testing..." : "Test Connection"
        case .downloadingModel:
            return modelManager.isPulling ? "Downloading..." : "Continue"
        case .complete:
            return "Get Started"
        }
    }
    
    // MARK: - Actions
    
    private func nextStep() {
        setupError = nil
        
        switch currentStep {
        case .welcome:
            currentStep = .permissions
            Task {
                await checkAllPermissions()
            }
            
        case .permissions:
            currentStep = .checkingOllama
            Task {
                await checkOllama()
            }
            
        case .checkingOllama:
            // Wait for check to complete
            break
            
        case .ollamaNotInstalled:
            // Skip and continue anyway (user can set up later)
            setupSkipped = true
            currentStep = .complete

        case .modelMissing:
            currentStep = .downloadingModel
            Task {
                await downloadModel()
            }

        case .remoteOllama:
            Task {
                await testRemoteOllama()
            }
            
        case .downloadingModel:
            if !modelManager.isPulling {
                currentStep = .complete
            }
            
        case .complete:
            onComplete()
        }
    }
    
    private func checkOllama() async {
        isSettingUp = true
        setupError = nil
        defer { isSettingUp = false }
        
        await guardian.checkStatus()
        
        switch guardian.status {
        case .notInstalled:
            currentStep = .ollamaNotInstalled
            
        case .running:
            await modelManager.fetchInstalledModels()
            
            // Check if default model is installed
            if modelManager.isModelInstalled(defaultModel.name) {
                setupSkipped = false
                readyModelName = defaultModel.name
                currentStep = .complete
            } else {
                currentStep = .modelMissing
            }
            
        case .installed, .stopped:
            // Try to start Ollama
            do {
                try await guardian.startService()
                await modelManager.fetchInstalledModels()
                
                if modelManager.isModelInstalled(defaultModel.name) {
                    setupSkipped = false
                    readyModelName = defaultModel.name
                    currentStep = .complete
                } else {
                    currentStep = .modelMissing
                }
            } catch {
                setupError = "Failed to start Ollama: \(error.localizedDescription)"
                currentStep = .ollamaNotInstalled
            }
            
        case .starting:
            // Wait for it
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await checkOllama()
            
        case .error(let message):
            setupError = message
            currentStep = .ollamaNotInstalled
        }
    }
    
    private func downloadModel() async {
        do {
            try await modelManager.pullModel(defaultModel.name)
            setupSkipped = false
            readyModelName = defaultModel.name
            currentStep = .complete
        } catch {
            setupError = error.localizedDescription
            currentStep = .modelMissing
        }
    }

    private func testRemoteOllama() async {
        isSettingUp = true
        setupError = nil
        defer { isSettingUp = false }

        guard let config = normalizedRemoteOllamaConfig() else {
            setupError = "Enter a valid HTTP host, port, and model."
            return
        }

        guard let url = URL(string: "\(config.baseURL)/api/tags") else {
            setupError = "Invalid remote Ollama URL."
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                setupError = "Remote Ollama did not return a healthy /api/tags response."
                return
            }

            let modelsResponse = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            guard modelsResponse.models.contains(where: { isModelName($0.name, matching: config.model) }) else {
                setupError = "Remote Ollama connected, but '\(config.model)' is not installed."
                return
            }

            var settings = AppSettings.load()
            settings.ollamaHost = config.host
            settings.ollamaPort = config.port
            settings.ollamaModel = config.model

            guard settings.save() else {
                setupError = AppSettings.consumeLastPersistenceError() ?? "Failed to save remote Ollama settings."
                return
            }

            setupSkipped = false
            readyModelName = config.model
            currentStep = .complete
        } catch {
            setupError = "Cannot connect to remote Ollama: \(error.localizedDescription)"
        }
    }

    private func normalizedRemoteOllamaConfig() -> RemoteOllamaConfig? {
        let rawHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPort = remotePortText.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = remoteModel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawHost.isEmpty, !model.isEmpty else {
            return nil
        }

        var port = 11434
        if !rawPort.isEmpty {
            guard let parsedPort = Int(rawPort) else {
                return nil
            }
            port = parsedPort
        }

        guard (1...65_535).contains(port) else {
            return nil
        }

        let lowercasedHost = rawHost.lowercased()
        if lowercasedHost.hasPrefix("http://") || lowercasedHost.hasPrefix("https://") {
            guard var components = URLComponents(string: rawHost),
                  components.scheme?.lowercased() == "http",
                  let parsedHost = components.host else {
                return nil
            }

            if let parsedPort = components.port {
                port = parsedPort
            }

            components.scheme = "http"
            components.host = parsedHost
            components.port = port
            components.path = ""
            components.query = nil
            components.fragment = nil

            guard let absoluteURL = components.url?.absoluteString else {
                return nil
            }
            let baseURL = absoluteURL.hasSuffix("/") ? String(absoluteURL.dropLast()) : absoluteURL

            return RemoteOllamaConfig(
                host: normalizedHostForSettings(parsedHost),
                port: port,
                baseURL: baseURL,
                model: model
            )
        }

        let hostInput = rawHost.hasSuffix("/") ? String(rawHost.dropLast()) : rawHost

        if let components = URLComponents(string: "http://\(hostInput)"),
           let parsedHost = components.host {
            if let parsedPort = components.port {
                port = parsedPort
            }

            guard (1...65_535).contains(port) else {
                return nil
            }

            let host = normalizedHostForSettings(parsedHost)
            return RemoteOllamaConfig(
                host: host,
                port: port,
                baseURL: "http://\(host):\(port)",
                model: model
            )
        }

        guard hostInput.filter({ $0 == ":" }).count > 1 else {
            return nil
        }

        let host = normalizedHostForSettings(hostInput)
        return RemoteOllamaConfig(
            host: host,
            port: port,
            baseURL: "http://\(host):\(port)",
            model: model
        )
    }

    private func normalizedHostForSettings(_ host: String) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]"
        }

        return host
    }

    private func isModelName(_ installedName: String, matching requestedName: String) -> Bool {
        installedName == requestedName || installedName.hasPrefix("\(requestedName):")
    }
    
    // MARK: - Permission Methods
    
    private func checkAllPermissions() async {
        isCheckingPermissions = true
        defer { isCheckingPermissions = false }
        
        // Check Screen Capture permission
        hasScreenCapturePermission = await checkScreenCapturePermission()
        
        // Check Microphone permission
        hasMicrophonePermission = await checkMicrophonePermission()
        
        // Check Speech Recognition permission
        hasSpeechRecognitionPermission = await checkSpeechRecognitionPermission()
    }
    
    private func checkScreenCapturePermission() async -> Bool {
        print("[WelcomeView] Checking Screen Capture Permission...")
        let hasAccess = CGPreflightScreenCaptureAccess()
        if hasAccess {
            print("[WelcomeView] CGPreflight returned TRUE")
            return true
        }
        
        // Fallback to SCShareableContent to bypass cache
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let granted = !content.displays.isEmpty
            print("[WelcomeView] SCShareableContent check completed. Displays > 0? \(granted)")
            return granted
        } catch {
            print("[WelcomeView] SCShareableContent threw: \(error.localizedDescription)")
            return false
        }
    }
    
    private func checkMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized
    }
    
    private func checkSpeechRecognitionPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .authorized
    }
    
    private func requestScreenCapturePermission() {
        screenRecordingRequested = true
        Task {
            // Requesting screen capture triggers the system dialog (first time)
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                hasScreenCapturePermission = true
            } catch {
                // Not yet granted — open System Settings so the user can enable it.
                // Note: even after granting, macOS needs an app restart for it to
                // take effect, which is why we surface a Restart button.
                hasScreenCapturePermission = false
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Relaunch the app so a newly granted screen-recording permission takes
    /// effect (CGPreflight caches the old value for the process's lifetime).
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
    
    private func requestMicrophonePermission() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                hasMicrophonePermission = granted
            }
        }
    }
    
    private func requestSpeechRecognitionPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                hasSpeechRecognitionPermission = (status == .authorized)
            }
        }
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
    var isOptional: Bool = false
    var pendingRestart: Bool = false
    let onGrant: () -> Void
    var onRestart: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    if isOptional && !isGranted {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isChecking {
            ProgressView()
                .scaleEffect(0.8)
        } else if isGranted {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
        } else if pendingRestart {
            Button("Restart to apply") {
                onRestart?()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        } else {
            Button("Grant") {
                onGrant()
            }
            .buttonStyle(.bordered)
        }
    }

    private var iconColor: Color {
        if isGranted { return .green }
        if pendingRestart { return .orange }
        return isOptional ? Color(nsColor: .tertiaryLabelColor) : .orange
    }
}
