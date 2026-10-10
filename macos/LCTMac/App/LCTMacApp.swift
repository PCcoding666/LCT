import SwiftUI

/// LCT for macOS - Main Application Entry Point
@main
@MainActor
struct LCTMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showWelcome: Bool = {
        return !AppSettings.hasCompletedSetup
    }()
    
    var body: some Scene {
        // Main Window — a single Window, not a WindowGroup: the app has one
        // view model (owned by AppCoordinator), and closing this window only
        // hides it, so the coordinator can bring it back for menu, status bar
        // and hotkey commands.
        Window("LCT", id: MainWindow.id) {
            ZStack {
                if showWelcome {
                    WelcomeView {
                        AppSettings.markSetupComplete()
                        print("[LCTMacApp] Setup completed, showing MainView")
                        DispatchQueue.main.async {
                            showWelcome = false
                        }
                    }
                    .transition(.opacity)
                } else {
                    MainView(viewModel: appDelegate.coordinator.viewModel)
                        .transition(.opacity)
                        .onAppear {
                            print("[LCTMacApp] MainView appeared")
                        }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showWelcome)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .commands {
            MainWindowCommands(coordinator: appDelegate.coordinator)

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
@MainActor
struct SettingsWindowView: View {
    @State private var settings = AppSettings.load()

    var body: some View {
        SettingsView(settings: $settings) { newSettings in
            newSettings.save()
            settings = newSettings
            // Let the running view model apply the change immediately (via
            // AppCoordinator); it never re-posts this notification, so no loop.
            NotificationCenter.default.post(name: .settingsDidChange, object: newSettings)
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
    static let settingsDidChange = Notification.Name("LCT.settingsDidChange")
}