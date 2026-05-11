import SwiftUI

/// Bottom-tab scaffold: Sync (existing) + Replay (new). Mirrors the
/// Android `MainNav.kt` two-tab navigation, but uses SwiftUI's `TabView`
/// instead of a separate NavHost.
struct MainNav: View {
    var body: some View {
        TabView {
            FileSyncScreen()
                .tabItem {
                    Label("Sync", systemImage: "icloud.and.arrow.down")
                }
            ReplayScreen()
                .tabItem {
                    Label("Replay", systemImage: "play.circle")
                }
        }
    }
}
