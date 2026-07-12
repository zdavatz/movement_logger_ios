import SwiftUI
import AppIntents

@main
struct MovementLoggerWatchApp: App {
    /// One long-lived controller for the whole app. `@State` keeps the same
    /// instance across view updates; it's shared to the view tree via the
    /// Observation environment. Uses `SessionController.shared` so the
    /// Action-button intent controls the same session the UI renders.
    @State private var controller = SessionController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environment(controller)
            // Second Water-Lock trigger: on an Action-button launch the workout
            // can reach `.running` before the app is frontmost, and
            // `enableWaterLock()` is a no-op until then. Retrying on scene-active
            // guarantees the screen locks once we're actually in the foreground.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { controller.engageWaterLockIfNeeded() }
            }
        }
    }
}

// MARK: - Action button (workout intent)

/// The "style" the Action-button workout intent records. The app logs the same
/// way regardless (box if connected, else Watch GPS), so a single style is
/// offered — but a `WorkoutStyle` `@Parameter` on a `StartWorkoutIntent` is
/// exactly what makes the app eligible for the Apple Watch Ultra **Action
/// button → App** list. (Together with `workout-processing` in the watch app's
/// `WKBackgroundModes`, which the app already declares for Water Lock.) Without
/// this workout-flavoured intent, a plain `AppIntent`/`AppShortcut` only reaches
/// the Action button's *Shortcut* action + Siri, NOT the *App* list — which is
/// why nothing showed up there before.
enum WorkoutStyle: String, AppEnum {
    case session

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
    static var caseDisplayRepresentations: [WorkoutStyle: DisplayRepresentation] = [
        .session: "Movement session"
    ]
}

/// Assign this to the Apple Watch Ultra Action button
/// (**Settings → Action Button → App → MovementLogger**): a press opens the app
/// and starts a logging session (box if one is connected, otherwise Watch GPS).
/// Conforms to the system `StartWorkoutIntent`, the workout intent the Action
/// button's "App" action requires — verified against Apple's Action-button docs
/// and `KhaosT/WatchActionButtonExample`.
struct BeginSessionIntent: StartWorkoutIntent {
    static var title: LocalizedStringResource = "Start Movement Logger Session"
    static var openAppWhenRun = true

    @Parameter(title: "Style")
    var workoutStyle: WorkoutStyle

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(workoutStyle)") }

    /// Pre-configured options offered when the user assigns the button.
    static var suggestedWorkouts: [BeginSessionIntent] { [BeginSessionIntent(style: .session)] }

    init() { self.workoutStyle = .session }
    init(style: WorkoutStyle) { self.workoutStyle = style }

    @MainActor
    func perform() async throws -> some IntentResult {
        SessionController.shared.startFromActionButton()
        return .result()
    }
}

// MARK: - Siri / Shortcut action

/// Starts a session if idle, ends it if running — the toggle a single hardware
/// press should perform. Reaches the Action button's **Shortcut** action and
/// Siri ("Start MovementLogger"); the *App* action uses `BeginSessionIntent`
/// above. `openAppWhenRun` brings the app forward so GPS + the workout
/// keep-alive have a foreground context and the user sees the running timer.
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
