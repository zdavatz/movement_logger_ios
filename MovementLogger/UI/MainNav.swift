import SwiftUI

/// Bottom-tab scaffold matching the desktop (Live → Sync → Replay) and the
/// Android `MainNav.kt`. Owns the shared `FileSyncViewModel` so the Live tab
/// sees the SensorStream samples that the Sync tab's BLE worker decoded.
struct MainNav: View {
    /// Tabs are integer-tagged so the launch-env hook below (used by App
    /// Store screenshot capture) can flip the initial tab without touching
    /// the segmented bar.
    @State private var selection: Int = Self.initialTab()
    @State private var vm = FileSyncViewModel()

    var body: some View {
        TabView(selection: $selection) {
            LiveScreen(vm: vm, onGoToSync: { selection = 1 })
                .tabItem { Label("Live", systemImage: "sensor") }
                .tag(0)
            FileSyncScreen(vm: vm)
                .tabItem { Label("Sync", systemImage: "icloud.and.arrow.down") }
                .tag(1)
            ReplayScreen()
                .tabItem { Label("Replay", systemImage: "play.circle") }
                .tag(2)
        }
    }

    /// `INITIAL_TAB` env var hook used by `scripts/capture_*.sh` / simctl
    /// launches for App Store screenshot capture. Values: `live` / `sync` /
    /// `replay`. Default is the Live tab (matches desktop default).
    private static func initialTab() -> Int {
        switch ProcessInfo.processInfo.environment["INITIAL_TAB"] {
        case "sync": return 1
        case "replay": return 2
        default: return 0
        }
    }
}
