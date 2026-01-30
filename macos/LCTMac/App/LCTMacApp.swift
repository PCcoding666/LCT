import SwiftUI

/// LCT for macOS - Main Application Entry Point
@main
struct LCTMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Main Window
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // App commands
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    // TODO: Implement update check
                }
                .keyboardShortcut("U", modifiers: [.command])
            }
            
            // Edit commands
            CommandGroup(after: .pasteboard) {
                Button("Copy Translation") {
                    NotificationCenter.default.post(name: .copyTranslation, object: nil)
                }
                .keyboardShortcut("C", modifiers: [.command, .shift])
            }
            
            // View commands
            CommandGroup(after: .toolbar) {
                Button("Toggle Overlay") {
                    NotificationCenter.default.post(name: .toggleOverlay, object: nil)
                }
                .keyboardShortcut("O", modifiers: [.command])
                
                Divider()
                
                Button("Show History") {
                    NotificationCenter.default.post(name: .showHistory, object: nil)
                }
                .keyboardShortcut("H", modifiers: [.command, .shift])
            }
            
            // Control commands
            CommandGroup(after: .windowArrangement) {
                Button("Start/Stop Capture") {
                    NotificationCenter.default.post(name: .toggleCapture, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [.command])
                
                Button("Pause/Resume") {
                    NotificationCenter.default.post(name: .togglePause, object: nil)
                }
                .keyboardShortcut("P", modifiers: [.command])
            }
        }
        
        // Settings Window
        #if os(macOS)
        Settings {
            SettingsWindowView()
        }
        #endif
    }
}

/// Settings window view wrapper
struct SettingsWindowView: View {
    @State private var settings = AppSettings.load()
    
    var body: some View {
        SettingsView(settings: $settings) { newSettings in
            newSettings.save()
            settings = newSettings
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let copyTranslation = Notification.Name("LCT.copyTranslation")
    static let toggleOverlay = Notification.Name("LCT.toggleOverlay")
    static let showHistory = Notification.Name("LCT.showHistory")
    static let toggleCapture = Notification.Name("LCT.toggleCapture")
    static let togglePause = Notification.Name("LCT.togglePause")
}
