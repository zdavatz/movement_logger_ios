import SwiftUI

@main
struct MovementLoggerWatchApp: App {
    /// One long-lived controller for the whole app. `@State` keeps the same
    /// instance across view updates; it's shared to the view tree via the
    /// Observation environment.
    @State private var controller = SessionController()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .environment(controller)
        }
    }
}
