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
    private static let kMagOffset = "agent.magOffsetMg"
    private static let kHeadingBias = "agent.headingBiasDeg"
    private static let kNosePlusY = "agent.nosePlusY"
    private static let kNosePlusYKnown = "agent.nosePlusYKnown"
    private static let kLateralFlip = "agent.lateralFlip"
    private static let kDirAnchorAcc = "agent.dirAnchorAcc"
    private static let kDirAnchorMag = "agent.dirAnchorMag"
    private static let kAngleZeroRef = "agent.angleZeroRef"
    private static let kAngleZeroAt = "agent.angleZeroAt"

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

    /// Magnetometer hard-iron offset [x, y, z] in mG, from the Live tab's
    /// "Calibrate compass" flow — desktop `mag_offset_mg` / Android parity.
    /// Subtracted from the raw mag before the eCompass heading; without it
    /// a box-fixed magnetic bias bigger than the ~200 mG horizontal earth
    /// field pins the heading regardless of rotation. `nil` = uncalibrated.
    static var magOffsetMg: [Double]? {
        get {
            guard let a = UserDefaults.standard.array(forKey: kMagOffset) as? [Double],
                  a.count == 3 else { return nil }
            return a
        }
        set {
            if let v = newValue, v.count == 3 {
                UserDefaults.standard.set(v, forKey: kMagOffset)
            } else {
                UserDefaults.standard.removeObject(forKey: kMagOffset)
            }
        }
    }

    /// Constant heading bias (deg) from the one-tap direction calibration:
    /// lay the box flat, point its nose SOUTH, confirm — bias = computed
    /// heading − 180. Subtracted from the displayed/drawn heading. This
    /// absorbs every constant rotation in the chain (mag-vs-accel axis
    /// alignment, soft-iron rotation, mounting) in a single step; the
    /// continuous auto-calibration handles the hard-iron offset.
    static var headingBiasDeg: Double? {
        get {
            UserDefaults.standard.object(forKey: kHeadingBias) as? Double
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: kHeadingBias)
            } else {
                UserDefaults.standard.removeObject(forKey: kHeadingBias)
            }
        }
    }

    /// Which body-axis end is the user-defined FRONT (USB-C end): true =
    /// +Y, false = -Y, nil = unknown. Set by the "USB-C end pointing UP —
    /// confirm" tap (sign of ay while the box stands on its end). The
    /// heading bias absorbs the 180° in yaw, but the 3D preview needs the
    /// real end to tilt the arrow the right way when the box is upright.
    static var nosePlusY: Bool? {
        get {
            guard UserDefaults.standard.bool(forKey: kNosePlusYKnown) else { return nil }
            return UserDefaults.standard.bool(forKey: kNosePlusY)
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(true, forKey: kNosePlusYKnown)
                UserDefaults.standard.set(v, forKey: kNosePlusY)
            } else {
                UserDefaults.standard.set(false, forKey: kNosePlusYKnown)
                UserDefaults.standard.removeObject(forKey: kNosePlusY)
            }
        }
    }

    /// Legacy scene-mirror sign — no longer used by the renderer (handedness
    /// is a fixed hardware fact). Kept only so `resetMagCalibration` can wipe
    /// a stale stored value written by older builds.
    static var lateralSign: Double? {
        get { UserDefaults.standard.object(forKey: kLateralFlip) as? Double }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: kLateralFlip)
            } else {
                UserDefaults.standard.removeObject(forKey: kLateralFlip)
            }
        }
    }

    /// Direction anchor: the RAW (offset-independent) acc + mag reading
    /// captured at the "USB-C points SOUTH — set direction" tap. "South" is
    /// defined by THIS physical pose, not by a bias number — so whenever the
    /// hard-iron offset later refines (e.g. a backflip suddenly gives the 3D
    /// fit full pose coverage), the bias is recomputed from this anchor and
    /// the south reference stays locked instead of drifting. Two [Double]
    /// arrays of 3 (ax,ay,az / mx,my,mz), or nil if never set.
    static var directionAnchorAcc: [Double]? {
        get { UserDefaults.standard.array(forKey: kDirAnchorAcc) as? [Double] }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: kDirAnchorAcc) }
            else { UserDefaults.standard.removeObject(forKey: kDirAnchorAcc) }
        }
    }
    static var directionAnchorMag: [Double]? {
        get { UserDefaults.standard.array(forKey: kDirAnchorMag) as? [Double] }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: kDirAnchorMag) }
            else { UserDefaults.standard.removeObject(forKey: kDirAnchorMag) }
        }
    }

    /// Calibrated-angle zero reference: [pitch, roll, yaw] in degrees captured
    /// at the Live tab's "Zero here" tap (yaw sampled at bias 0, so the tared
    /// heading is direction-cal independent). `nil` = not zeroed. Persisted so
    /// a mounted-box tare survives reconnect / app restart.
    static var angleZeroRef: [Double]? {
        get {
            guard let a = UserDefaults.standard.array(forKey: kAngleZeroRef) as? [Double],
                  a.count == 3 else { return nil }
            return a
        }
        set {
            if let v = newValue, v.count == 3 {
                UserDefaults.standard.set(v, forKey: kAngleZeroRef)
            } else {
                UserDefaults.standard.removeObject(forKey: kAngleZeroRef)
            }
        }
    }

    /// Wall-clock (epoch seconds) of the last "Zero here" tap — drives the
    /// "zeroed N ago" note. `nil` when never zeroed / after Clear.
    static var angleZeroAtEpoch: Double? {
        get { UserDefaults.standard.object(forKey: kAngleZeroAt) as? Double }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: kAngleZeroAt) }
            else { UserDefaults.standard.removeObject(forKey: kAngleZeroAt) }
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
