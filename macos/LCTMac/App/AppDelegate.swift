import SwiftUI
import AppKit

/// Application delegate for handling app lifecycle events
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var overlayWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("LCT for macOS launched successfully")
        
        // Setup status bar item (optional)
        setupStatusBarItem()
        
        // Request necessary permissions
        requestPermissions()
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
        Task {
            // Check screen capture permission (needed for ScreenCaptureKit)
            // This will trigger the permission dialog if not already granted
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                print("Screen capture permission granted")
            } catch {
                print("Screen capture permission not granted: \(error)")
            }
            
            // Microphone permission will be requested when first used
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        // Stop any running services
        // Close overlay window
        overlayWindow?.close()
        overlayWindow = nil
        
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

// MARK: - SCShareableContent Import

import ScreenCaptureKit
