import SwiftUI
import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit
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

/// Global log function that writes to both console and file
func appLog(_ message: String) {
    let line = "\(message)\n"
    _logLock.lock()
    defer { _logLock.unlock() }

    _logStream?.write(line)
    fputs(line, stderr)
}

/// Application delegate for handling app lifecycle events
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
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
        
        // Ensure the app is recognized as a foreground GUI application
        // This is critical for SPM-built executables that aren't inside a .app bundle
        NSApp.setActivationPolicy(.regular)
        
        // Setup status bar item (optional)
        setupStatusBarItem()

        // Register system-wide hotkeys (⌃⌥⌘ S/P/O)
        GlobalHotKeyManager.shared.registerDefaults()

        // Request necessary permissions
        requestPermissions()
        
        // Activate the app and bring window to front
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            // Ensure the main window is visible
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("LCT for macOS terminating...")
        
        // Cleanup
        cleanup()
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
    
    // MARK: - Permissions
    
    private func requestPermissions() {
        // 使用 CGPreflightScreenCaptureAccess 检查权限
        // 这比 SCShareableContent 更稳定，不会触发 RPDaemonProxy 错误
        let hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
        
        if hasScreenCapturePermission {
            print("Screen capture permission granted")
        } else {
            print("Screen capture permission not yet granted. Will request when needed.")
            // 不要在启动时请求权限，让用户点击 Start 时再请求
        }
        
        // Microphone permission will be requested when first used
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
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
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
