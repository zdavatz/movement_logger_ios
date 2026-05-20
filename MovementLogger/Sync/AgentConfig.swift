import Foundation

/// Process-wide persistent config for the background sync agent.
///
/// iOS equivalent of Android's `sync/AgentConfig.kt` (SharedPreferences) and
/// the desktop's `~/.movementlogger/config.toml`. Stored in `UserDefaults`
/// because the values are small primitives and a `BGAppRefreshTask` handler
/// must read them with zero startup cost when iOS relaunches us in the
/// background.
///
/// Three-state `logModeManual` is encoded via a separate `_known` companion
/// bit — UserDefaults has no native tri-state Boolean, same trick as the
/// Android port.
enum AgentConfig {
    private static let kBoxId = "agent.boxId"
    private static let kKeepSynced = "agent.keepSynced"
    private static let kLogModeManual = "agent.logModeManual"
    private static let kLogModeManualKnown = "agent.logModeManualKnown"

    /// `CBPeripheral.identifier.uuidString` of the box the user is mirroring.
    /// Persisted on every successful `.connected` so the BG handler can
    /// reach the same box after the app has been suspended/terminated.
    static var boxId: String? {
        get { UserDefaults.standard.string(forKey: kBoxId) }
        set { UserDefaults.standard.set(newValue, forKey: kBoxId) }
    }

    /// User-facing "Keep synced" toggle. The single source of truth — the
    /// in-process 30 s poll AND the BG scheduler both gate on this.
    static var keepSynced: Bool {
        get { UserDefaults.standard.bool(forKey: kKeepSynced) }
        set { UserDefaults.standard.set(newValue, forKey: kKeepSynced) }
    }

    /// Box log-mode mirror. `nil` = unknown (legacy firmware, or never
    /// queried yet this install). `false` = auto (logs on power-on),
    /// `true` = manual (idle until START_LOG).
    static var logModeManual: Bool? {
        get {
            guard UserDefaults.standard.bool(forKey: kLogModeManualKnown) else { return nil }
            return UserDefaults.standard.bool(forKey: kLogModeManual)
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(true, forKey: kLogModeManualKnown)
                UserDefaults.standard.set(v, forKey: kLogModeManual)
            } else {
                UserDefaults.standard.set(false, forKey: kLogModeManualKnown)
                UserDefaults.standard.removeObject(forKey: kLogModeManual)
            }
        }
    }

    /// Locked gating policy (mirrors Android + desktop):
    /// `keepSynced && boxId != nil && logModeManual != true`.
    ///
    /// MANUAL disables the background schedule (the user controls when
    /// the box logs); AUTO + Keep-synced + known box enables it.
    /// `logModeManual == nil` (unknown) is treated as not-manual so legacy
    /// firmware that ignores GET_MODE still participates — matches Android.
    static var active: Bool {
        keepSynced && boxId != nil && logModeManual != true
    }
}
