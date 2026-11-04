import SwiftUI
import AppKit
import CoreGraphics
import os

/// Custom output stream that writes to a log file
private final class FileLogStream {
    let fileHandle: FileHandle

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            fileHandle.write(data)
        }
    }
}

nonisolated(unsafe) private var _logStream: FileLogStream?
private let _logLock = NSLock()

/// Timestamp prefix for log lines: "HH:mm:ss.SSS" in local time.
enum LogTimestamp {
    static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }
}

// Only touched while holding _logLock, so sharing the formatter is safe.
private let _timestampFormatter = LogTimestamp.makeFormatter()

/// Global log function that writes to both console and file.
/// Every line is prefixed with a local-time "HH:mm:ss.SSS" timestamp.
func appLog(_ message: String) {
    _logLock.lock()
    defer { _logLock.unlock() }

    let line = "\(_timestampFormatter.string(from: Date())) \(message)\n"
    _logStream?.write(line)
    fputs(line, stderr)
}

/// Application delegate for handling app lifecycle events
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var translationTerminationPending = false
    /// Owns the view model and handles capture/pause/overlay commands for
    /// the whole run, including while the main window is closed.
    let coordinator = AppCoordinator()

    private var statusItem: NSStatusItem?
    private var overlayWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup log file
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LCTMac.log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        if let fh = FileHandle(forWritingAtPath: logPath.path) {
            fh.truncateFile(atOffset: 0)
            _logStream = FileLogStream(fileHandle: fh)
        }
        
        appLog("LCT for macOS launched successfully — log: \(logPath.path)")

        // Speech recognition self-test mode (diagnostics): runs the real
        // recognition pipeline against an audio file, writes a JSON report,
        // and terminates. Skips the normal startup flow entirely — no status
        // item, no hotkeys, no permission preflight, no capture.
        if let options = SpeechSelfTestOptions.parse(arguments: ProcessInfo.processInfo.arguments) {
            appLog("[SpeechSelfTest] Self-test mode: locale=\(options.localeIdentifier) engine=\(options.engine)")
            Task {
                await SpeechSelfTestRunner().run(options: options)
            }
            return
        }

        // Dual-channel variant: lanes A (.system) and B (.microphone) fed
        // concurrently from two audio files through the real engine.
        if let options = SpeechDualSelfTestOptions.parse(arguments: ProcessInfo.processInfo.arguments) {
            appLog("[SpeechSelfTest] Dual self-test mode: engine=\(options.engine) localeA=\(options.localeIdentifierA) localeB=\(options.localeIdentifierB)")
            Task {
                await SpeechDualSelfTestRunner().run(options: options)
            }
            return
        }

        // Ensure the app is recognized as a foreground GUI application
        // This is critical for SPM-built executables that aren't inside a .app bundle
        NSApp.setActivationPolicy(.regular)
        
        // Setup status bar item (optional)
        setupStatusBarItem()

        // Register system-wide hotkeys (⌃⌥⌘ S/P/O)
        GlobalHotKeyManager.shared.registerDefaults()

        // Activate the app and bring the main window to front
        DispatchQueue.main.async {
            self.coordinator.showMainWindow()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("LCT for macOS terminating...")

        // Cleanup
        cleanup()
    }

    /// The embedded runtime belongs to this process. Cancel downloads and
    /// unload its model without contacting or terminating an external service.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let arguments = ProcessInfo.processInfo.arguments
        if SpeechSelfTestOptions.parse(arguments: arguments) != nil
            || SpeechDualSelfTestOptions.parse(arguments: arguments) != nil {
            return .terminateNow
        }
        let service = EmbeddedTranslationService.shared
        switch service.state {
        case .downloading, .verifying, .loading, .ready:
            break
        case .notDownloaded, .downloaded, .failed:
            return .terminateNow
        }
        guard !translationTerminationPending else { return .terminateLater }
        translationTerminationPending = true
        Task { [weak self] in
            // URLSession must finish producing and persisting resume data
            // before a normal quit closes the process.
            await service.cancelDownloadAndWait()
            await service.unloadModel()
            self?.finishTranslationTermination()
        }
        // An independent timeout must not wait for an uncooperative native
        // operation to finish; process exit itself releases any remaining RAM.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.finishTranslationTermination()
        }
        return .terminateLater
    }

    private func finishTranslationTermination() {
        guard translationTerminationPending else { return }
        translationTerminationPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in background with status bar
        return false
    }
    
    // MARK: - Status Bar
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "LCT")
            button.action = #selector(statusBarClicked)
            button.target = self
        }
        
        // Create menu
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Show Main Window", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle Overlay", action: #selector(toggleOverlay), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Start Capture", action: #selector(startCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Capture", action: #selector(stopCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit LCT", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        // Stop any running services
        // Close overlay window
        overlayWindow?.close()
        overlayWindow = nil

        // Unregister global hotkeys
        GlobalHotKeyManager.shared.unregister()

        // Remove status item
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
    
    // MARK: - Actions
    
    @objc private func statusBarClicked() {
        showMainWindow()
    }
    
    @objc private func showMainWindow() {
        coordinator.showMainWindow()
    }
    
    @objc private func toggleOverlay() {
        NotificationCenter.default.post(name: .toggleOverlay, object: nil)
    }
    
    @objc private func startCapture() {
        NotificationCenter.default.post(name: .toggleCapture, object: true)
    }
    
    @objc private func stopCapture() {
        NotificationCenter.default.post(name: .toggleCapture, object: false)
    }
    
    @objc private func showPreferences() {
        // Open settings window
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
