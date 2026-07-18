import SwiftUI

/// Bottom-tab scaffold matching the desktop (Live → Sync → Replay) and the
/// Android `MainNav.kt`. Owns the shared `FileSyncViewModel` so the Live tab
/// sees the SensorStream samples that the Sync tab's BLE worker decoded.
struct MainNav: View {
    /// Tabs are integer-tagged so the launch-env hook below (used by App
    /// Store screenshot capture) can flip the initial tab without touching
    /// the segmented bar.
    @State private var selection: Int = Self.initialTab()
    // Singleton — shared with the background sync agent so foreground and
    // background drive the same `BleClient`. See `FileSyncViewModel.shared`.
    @State private var vm = FileSyncViewModel.shared
    // Independent CoreLocation singleton — survives tab switches so a
    // running CSV log doesn't get torn down when the user peeks at Sync.
    @State private var gps = GpsCore.shared

    var body: some View {
        TabView(selection: $selection) {
            LiveScreen(vm: vm, onGoToSync: { selection = 2 })
                .tabItem { Label("Live", systemImage: "sensor") }
                .tag(0)
            GpsScreen(core: gps)
                .tabItem { Label("GPS", systemImage: "location.fill") }
                .tag(1)
            FileSyncScreen(vm: vm)
                .tabItem { Label("Sync", systemImage: "icloud.and.arrow.down") }
                .tag(2)
            ReplayScreen()
                .tabItem { Label("Replay", systemImage: "play.circle") }
                .tag(3)
            MergeScreen()
                .tabItem { Label("Merge", systemImage: "film.stack") }
                .tag(6)
            RidesScreen()
                .tabItem { Label("Rides", systemImage: "applewatch") }
                .tag(4)
            GpsDebugScreen(vm: vm)
                .tabItem { Label("GPS Debug", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(5)
        }
    }

    /// `INITIAL_TAB` env var hook used by `scripts/capture_*.sh` / simctl
    /// launches for App Store screenshot capture. Values: `live` / `gps` /
    /// `sync` / `replay`. Default is the Live tab (matches desktop default).
    private static func initialTab() -> Int {
        switch ProcessInfo.processInfo.environment["INITIAL_TAB"] {
        case "gps": return 1
        case "sync": return 2
        case "replay": return 3
        default: return 0
        }
    }
}
