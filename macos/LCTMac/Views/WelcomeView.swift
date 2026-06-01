import SwiftUI
import Speech
import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Welcome/Setup view for first-time users
struct WelcomeView: View {
    @StateObject private var guardian = OllamaGuardian.shared
    @StateObject private var modelManager = OllamaModelManager()
    
    @State private var currentStep: SetupStep = .welcome
    @State private var isSettingUp = false
    @State private var setupError: String?
    
    // Permission states
    @State private var hasScreenCapturePermission = false
    @State private var hasMicrophonePermission = false
    @State private var hasSpeechRecognitionPermission = false
    @State private var isCheckingPermissions = false
    
    /// Default model to use
    private let defaultModel = RecommendedModel.defaultModel
    
    let onComplete: () -> Void
    
    enum SetupStep {
        case welcome
        case permissions
        case checkingOllama
        case ollamaNotInstalled
        case downloadingModel
        case complete
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
        .frame(width: 600, height: 500)
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
        case .checkingOllama, .ollamaNotInstalled, .downloadingModel: return 2
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
            
            Text("LCT needs the following permissions to capture and translate audio")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 16) {
                // Screen Recording Permission
                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Required to capture system audio",
                    isGranted: hasScreenCapturePermission,
                    isChecking: isCheckingPermissions,
                    action: requestScreenCapturePermission
                )
                
                // Microphone Permission
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to capture your voice",
                    isGranted: hasMicrophonePermission,
                    isChecking: isCheckingPermissions,
                    action: requestMicrophonePermission
                )
                
                // Speech Recognition Permission
                PermissionRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    description: "Required for speech-to-text",
                    isGranted: hasSpeechRecognitionPermission,
                    isChecking: isCheckingPermissions,
                    action: requestSpeechRecognitionPermission
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            
            if !allPermissionsGranted {
                Text("Click each permission to grant access, or open System Settings manually")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button(action: openSystemSettings) {
                    Label("Open System Settings", systemImage: "gear")
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            Task {
                await checkAllPermissions()
            }
        }
        // Auto-refresh when coming back from System Settings
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if currentStep == .permissions && !allPermissionsGranted {
                print("[WelcomeView] App became active. Auto-checking permissions...")
                Task {
                    await checkAllPermissions()
                }
            }
        }
    }
    
    private var allPermissionsGranted: Bool {
        hasScreenCapturePermission && hasMicrophonePermission && hasSpeechRecognitionPermission
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
            
            Text("LCT uses Ollama for local AI translation. Please install Ollama to continue.")
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
                
                Text("After installing, click 'Check Again' below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
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
                    currentStep = .ollamaNotInstalled
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    // MARK: - Complete Content
    
    private var completeContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)
            
            Text("LCT is ready to use. Click 'Get Started' to begin translating.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ollama is running")
                }
                
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Model '\(defaultModel.displayName)' is ready")
                }
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack {
            if currentStep == .ollamaNotInstalled {
                Button("Check Again") {
                    Task {
                        await checkOllama()
                    }
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
            return allPermissionsGranted ? "Continue" : "Skip for Now"
        case .checkingOllama:
            return "Setting up..."
        case .ollamaNotInstalled:
            return "Skip for Now"
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
            currentStep = .complete
            
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
        defer { isSettingUp = false }
        
        await guardian.checkStatus()
        
        switch guardian.status {
        case .notInstalled:
            currentStep = .ollamaNotInstalled
            
        case .running:
            await modelManager.fetchInstalledModels()
            
            // Check if default model is installed
            if modelManager.isModelInstalled(defaultModel.name) {
                currentStep = .complete
            } else {
                // Download the default model automatically
                currentStep = .downloadingModel
                await downloadModel()
            }
            
        case .installed, .stopped:
            // Try to start Ollama
            do {
                try await guardian.startService()
                await modelManager.fetchInstalledModels()
                
                if modelManager.isModelInstalled(defaultModel.name) {
                    currentStep = .complete
                } else {
                    currentStep = .downloadingModel
                    await downloadModel()
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
            currentStep = .complete
        } catch {
            setupError = error.localizedDescription
            currentStep = .ollamaNotInstalled
        }
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
        Task {
            // Requesting screen capture will trigger the system dialog
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                hasScreenCapturePermission = true
            } catch {
                // Permission denied or not yet granted
                hasScreenCapturePermission = false
                // Open System Settings for Screen Recording
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
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
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            DispatchQueue.main.async { [self] in
                hasSpeechRecognitionPermission = (status == .authorized)
            }
        }
    }
    
    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
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
    let action: () -> Void
    
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
                    action()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}