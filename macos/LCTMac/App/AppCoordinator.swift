import SwiftUI
import AppKit
import Combine

/// The main window's SwiftUI scene. SwiftUI also uses the id as the
/// window's `NSWindow.identifier`.
enum MainWindow {
    static let id = "main"
}

/// A start/stop request from the Window menu, the status bar item, or the
/// global hotkey, decoded from a `.toggleCapture` notification.
enum CaptureCommand: Equatable {
    case start
    case stop
    case toggle

    /// `object: true` starts, `object: false` stops, anything else toggles
    /// (start if idle, stop if capturing).
    init(notificationObject object: Any?) {
        switch object as? Bool {
        case true?: self = .start
        case false?: self = .stop
        case nil: self = .toggle
        }
    }
}

/// App-lifetime owner of the transcription view model and the subtitle
/// overlay, and the one observer of the app-level commands: start/stop,
/// pause, overlay, and settings changes from the menu bar, the status bar
/// item, the global hotkeys, and the Settings window.
///
/// It lives on the app delegate rather than in a view because the app keeps
/// running in the menu bar after the main window is closed: those commands,
/// and any capture session in progress, must keep working without the
/// window. MainView only displays the view model.
@MainActor
final class AppCoordinator {
    let overlayController = OverlayWindowController()

    private let isSetupComplete: @MainActor () -> Bool
    private let isMainWindowVisible: @MainActor () -> Bool
    private let makeViewModel: @MainActor () -> TranscriptionViewModel
    private var createdViewModel: TranscriptionViewModel?
    private var mainWindowOpener: (@MainActor () -> Void)?
    private var cancellables = Set<AnyCancellable>()

    init(notificationCenter: NotificationCenter = .default,
         isSetupComplete: @escaping @MainActor () -> Bool = { AppSettings.hasCompletedSetup },
         isMainWindowVisible: @escaping @MainActor () -> Bool = AppCoordinator.mainWindowIsVisible,
         makeViewModel: @escaping @MainActor () -> TranscriptionViewModel = AppCoordinator.makeAppViewModel) {
        self.isSetupComplete = isSetupComplete
        self.isMainWindowVisible = isMainWindowVisible
        self.makeViewModel = makeViewModel
        observeCommands(on: notificationCenter)
    }

    /// The app's single view model, created on first use and kept for the
    /// rest of the run, so closing and reopening the main window keeps the
    /// session. Only touched after onboarding, so it loads the settings
    /// onboarding saved.
    var viewModel: TranscriptionViewModel {
        if let createdViewModel { return createdViewModel }
        let viewModel = makeViewModel()
        createdViewModel = viewModel
        return viewModel
    }

    // MARK: - Main window

    /// Register how to open the main window: SwiftUI's `openWindow` action,
    /// the only public way to reopen a closed SwiftUI window. Set by
    /// `MainWindowCommands`.
    func setMainWindowOpener(_ opener: @escaping @MainActor () -> Void) {
        mainWindowOpener = opener
    }

    /// Activate the app and bring the main window to the front, reopening it
    /// if it was closed or restoring it if it was minimized.
    func showMainWindow() {
        NSApp?.activate(ignoringOtherApps: true)
        if let mainWindowOpener {
            mainWindowOpener()
        } else {
            NSApp?.windows.first { $0.identifier?.rawValue == MainWindow.id }?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Commands

    /// Deliver a start/stop request. If the main window is closed or
    /// minimized it comes back first, so the user sees the capture state and
    /// any error notice; when it is already on screen, nothing steals focus
    /// (the global hotkey works from other apps).
    func perform(_ command: CaptureCommand) async {
        let windowVisible = isMainWindowVisible()
        appLog("[AppCoordinator] Capture command \(command) — main window \(windowVisible ? "visible" : "not visible, showing it")")
        if !windowVisible {
            showMainWindow()
        }

        // The window shows onboarding until setup completes; there is no
        // capture session to control yet.
        guard isSetupComplete() else {
            appLog("[AppCoordinator] ⏭ Capture command ignored — setup not completed")
            return
        }

        switch command {
        case .start:
            await viewModel.start()
        case .stop:
            await viewModel.stop()
        case .toggle:
            await viewModel.toggleCapture()
        }
    }

    private func togglePause() {
        guard isSetupComplete() else { return }
        viewModel.togglePause()
    }

    private func toggleOverlay() {
        guard isSetupComplete() else { return }
        overlayController.toggle(with: viewModel)
    }

    /// The ⌘, Settings window saved new settings — apply them to the running
    /// app. A view model created later loads them itself. updateSettings
    /// never re-posts this notification, so there is no loop.
    private func applySettings(_ newSettings: AppSettings) {
        guard let createdViewModel, newSettings != createdViewModel.settings else { return }
        createdViewModel.updateSettings(newSettings)
    }

    private func observeCommands(on notificationCenter: NotificationCenter) {
        notificationCenter.publisher(for: .toggleCapture)
            .map { CaptureCommand(notificationObject: $0.object) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] command in
                Task { await self?.perform(command) }
            }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .togglePause)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.togglePause() }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .toggleOverlay)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.toggleOverlay() }
            .store(in: &cancellables)

        notificationCenter.publisher(for: .settingsDidChange)
            .compactMap { $0.object as? AppSettings }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSettings in self?.applySettings(newSettings) }
            .store(in: &cancellables)
    }

    // MARK: - Defaults

    /// A minimized or closed main window is not visible.
    static func mainWindowIsVisible() -> Bool {
        NSApp?.windows.contains { $0.identifier?.rawValue == MainWindow.id && $0.isVisible } ?? false
    }

    /// The production view model. Warms the translation model in the
    /// background right away, so the first start() finds it in memory —
    /// once per run, not every time the main window reopens.
    static func makeAppViewModel() -> TranscriptionViewModel {
        let viewModel = TranscriptionViewModel()
        Task { await viewModel.prepareModelOnLaunch() }
        return viewModel
    }
}

/// Hands SwiftUI's `openWindow` action to the coordinator, so AppKit callers
/// (the status bar item, the global hotkeys) can reopen the main window after
/// the user closed it. Menu commands are built at launch and live as long as
/// the app, unlike any view inside the window.
@MainActor
struct MainWindowCommands: Commands {
    let coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let openWindow = self.openWindow
        let _ = coordinator.setMainWindowOpener { openWindow(id: MainWindow.id) }
        EmptyCommands()
    }
}
