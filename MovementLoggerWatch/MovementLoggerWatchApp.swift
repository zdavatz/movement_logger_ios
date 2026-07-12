import SwiftUI
import AppIntents

@main
struct MovementLoggerWatchApp: App {
    /// One long-lived controller for the whole app. `@State` keeps the same
    /// instance across view updates; it's shared to the view tree via the
    /// Observation environment. Uses `SessionController.shared` so the
    /// Action-button intent controls the same session the UI renders.
    @State private var controller = SessionController.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environment(controller)
        }
    }
}

// MARK: - Action button / Siri

/// Starts a session if idle, ends it if running — the toggle a single hardware
/// press should perform. Assign it to the Apple Watch Ultra **Action button**
/// (Settings → Action Button → Action: Shortcut → "Start / Stop Session") for
/// hands-free start/stop with wet hands on the water. `openAppWhenRun` brings
/// the app forward so GPS + the workout keep-alive have a foreground context
/// and the user sees the running timer.
struct ToggleSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start or Stop Session"
    static var description = IntentDescription(
        "Start recording a Movement Logger session (the box if one is connected, otherwise Watch GPS), or end the current one.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SessionController.shared.toggle()
        return .result()
    }
}

/// Registers the App Shortcut so `ToggleSessionIntent` appears in the Shortcuts
/// list — which is what the Action button's "Shortcut" action picks from — and
/// gives it Siri phrases.
struct MovementLoggerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleSessionIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Start a \(.applicationName) session",
                "Log with \(.applicationName)"
            ],
            shortTitle: "Start / Stop Session",
            systemImageName: "record.circle"
        )
    }
}
