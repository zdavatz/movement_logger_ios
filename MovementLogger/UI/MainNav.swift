import SwiftUI

/// Bottom-tab scaffold: Sync (existing) + Replay (new). Mirrors the
/// Android `MainNav.kt` two-tab navigation, but uses SwiftUI's `TabView`
/// instead of a separate NavHost.
struct MainNav: View {
    @State private var selection: Int = ProcessInfo.processInfo.environment["INITIAL_TAB"] == "replay" ? 1 : 0

    var body: some View {
        TabView(selection: $selection) {
            FileSyncScreen()
                .tabItem {
                    Label("Sync", systemImage: "icloud.and.arrow.down")
                }
                .tag(0)
            ReplayScreen()
                .tabItem {
                    Label("Replay", systemImage: "play.circle")
                }
                .tag(1)
        }
    }
}
