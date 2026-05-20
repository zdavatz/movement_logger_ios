import SwiftUI
import UIKit

@main
struct MovementLoggerApp: App {
    // SwiftUI's lifecycle doesn't expose a synchronous "before
    // didFinishLaunching" hook, but `BGTaskScheduler.register` MUST be called
    // before `application(_:didFinishLaunchingWithOptions:)` returns or iOS
    // drops the identifier. `UIApplicationDelegateAdaptor` gives us that
    // hook back without losing the SwiftUI App scaffold.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainNav()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil)
                     -> Bool {
        // 1) Register the BG task identifier BEFORE this method returns.
        BackgroundSync.register()
        // 2) Touch the singleton early so the CBCentralManager (with its
        //    restoration identifier) is constructed before iOS has any
        //    chance to deliver `willRestoreState`. SwiftUI evaluates the
        //    root view lazily and may not instantiate MainNav until a scene
        //    materialises — that's too late for restoration.
        _ = FileSyncViewModel.shared
        // 3) Refresh the BG schedule against the persisted AgentConfig.
        //    This catches the cold-launch case where the user toggled
        //    Keep-synced on, killed the app, and we're starting fresh.
        BackgroundSync.refresh()
        return true
    }
}
