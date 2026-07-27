import Foundation
import CoreMotion
import Observation

/// Owns the watch's inertial motion for two jobs off ONE `CMMotionManager`
/// (Apple's rule — a second manager can starve the first):
///
///  1. **Live board angles** for the watch UI. When the watch is strapped to
///     the board, `CMMotionManager.deviceMotion` gives fused, gravity-referenced
///     **pitch / roll / yaw** — the watch analogue of the box's `BoardAnglesCard`.
///     A **"Zero here"** tare captures the mounted pose as the reference (the
///     watch's strap orientation is arbitrary, so like the box's `nosePlusY` we
///     need one reference to read deviation from level/forward). Published live
///     for SwiftUI via `@Observable`.
///  2. **Ride logging** into a separate `WatchImu_<stamp>.csv`, paired to the
///     watch-GPS ride of the same stamp (see the ride-CSV note below).
///
/// Why a separate CSV, and why raw: the ride CSV is a clean 1 Hz GPS grid the
/// phone/desktop parsers already read — a 25 Hz motion stream would bloat it and
/// break the schema. And the activity classifier (belly-paddle vs foil-pump vs
/// gliding) is still being developed, so we log the raw fused samples
/// (`epoch_ms, ux/uy/uz` userAcceleration g, `gx/gy/gz` gravity, `rx/ry/rz`
/// rotationRate rad/s) rather than pre-computed features — and the **gravity
/// vector is exactly what yields board pitch/roll post-hoc**, so a board-mounted
/// ride records its angles even though the CSV schema itself is unchanged.
/// 25 Hz is ≥16 samples/cycle for a ≤1.5 Hz stroke; updates keep flowing in the
/// background off the `WorkoutKeepAlive` session that holds the app awake.
@Observable
final class WatchImuLogger {

    /// 25 Hz — comfortably above Nyquist for a ~1.5 Hz stroke, light on power.
    private static let hz = 25.0

    // MARK: - Live board angles (degrees), published for the watch UI.

    /// Relative to the "Zero here" tare when set (`hasZero`), else the raw fused
    /// attitude. Pitch = nose up/down, Roll = bank, Yaw = heading change.
    var pitchDeg: Double = 0
    var rollDeg: Double = 0
    var yawDeg: Double = 0
    var hasZero = false
    /// True while `deviceMotion` is actually delivering — the readout shows "—"
    /// until the first sample lands.
    var anglesLive = false

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "watch-imu"
        q.maxConcurrentOperationCount = 1   // serial: handler + flush share it
        return q
    }()

    /// The tare pose. Captured/cleared inside the handler (flags below) so the
    /// `CMAttitude` is only ever touched on the delivery queue — a
    /// `multiply(byInverseOf:)` mutates its receiver, so the reference must be a
    /// distinct object from the frame being displayed (it is: each callback's
    /// `deviceMotion` is a fresh object).
    @ObservationIgnored private var referenceAttitude: CMAttitude?
    @ObservationIgnored private var zeroPending = false
    @ObservationIgnored private var clearPending = false
    @ObservationIgnored private var sampleCount = 0

    // Independent clients keep the one manager running; it stops only when all
    // are done: the watch's own angle card (`liveUI`), the phone live-view
    // stream (`liveStream`), and a ride recording (`loggingActive`).
    @ObservationIgnored private var liveUI = false
    @ObservationIgnored private var liveStream = false
    @ObservationIgnored private var loggingActive = false

    /// Called on the main queue at the UI publish rate (~8 Hz) with the current
    /// pitch/roll/yaw (degrees). Used to stream the live snapshot to the phone.
    @ObservationIgnored var onAngles: ((Double, Double, Double) -> Void)?

    // MARK: - Logging file state
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private(set) var csvURL: URL?
    @ObservationIgnored private var baseEpochMs: Double = 0
    @ObservationIgnored private var baseUptimeS: Double = 0
    @ObservationIgnored private var buffer: [String] = []

    // MARK: - Live UI control

    /// Start delivering live angles for the watch's own UI. Idempotent.
    func startLive() { liveUI = true; ensureRunning() }
    /// Stop the watch-UI angle client. The manager keeps running if a ride is
    /// still logging or the phone is streaming.
    func stopLive() { liveUI = false; ensureRunning() }

    /// The phone opened its live view — keep angles flowing to feed the stream
    /// even when the watch screen is off (e.g. board-mounted during a ride).
    func startStream() { liveStream = true; ensureRunning() }
    func stopStream() { liveStream = false; ensureRunning() }

    /// Capture the current pose as the zero reference (tare).
    func zero() { zeroPending = true; hasZero = true }
    /// Drop the tare — angles then read against the raw fused reference.
    func clearZero() { clearPending = true; hasZero = false }

    // MARK: - Ride logging

    /// Begin logging into `WatchImu_<stamp>.csv`. `stamp` MUST match the paired
    /// GPS ride's filename stamp so the phone can associate the two.
    func start(stamp: String) {
        guard motion.isDeviceMotionAvailable else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = docs.appendingPathComponent("WatchImu_\(stamp).csv")
        let header = "epoch_ms,ux_g,uy_g,uz_g,gx,gy,gz,rx_rps,ry_rps,rz_rps\n"
        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        csvURL = url
        baseEpochMs = Date().timeIntervalSince1970 * 1000
        baseUptimeS = ProcessInfo.processInfo.systemUptime
        loggingActive = true
        ensureRunning()
    }

    /// Stop logging and flush. Keeps `csvURL` set so the caller can hand the
    /// file to `WatchSync`. The live client (if any) keeps the manager running.
    func stop() {
        guard loggingActive else { return }
        loggingActive = false           // handler stops writing before we drain
        queue.addOperation { [weak self] in self?.flush() }
        queue.waitUntilAllOperationsAreFinished()
        try? handle?.close()
        handle = nil
        ensureRunning()
    }

    // MARK: - Manager run control

    private func ensureRunning() {
        let want = liveUI || liveStream || loggingActive
        if want, !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / Self.hz
            motion.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
                guard let self, let m else { return }
                self.handle(m)
            }
        } else if !want, motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
            if anglesLive { DispatchQueue.main.async { self.anglesLive = false } }
        }
    }

    // MARK: - Sample handler (on the delivery queue)

    private func handle(_ m: CMDeviceMotion) {
        // Tare bookkeeping first, so `referenceAttitude` is a prior-frame object
        // distinct from the one we display this frame.
        if clearPending { referenceAttitude = nil; clearPending = false }
        if zeroPending {
            referenceAttitude = m.attitude   // this frame reads as identity below
            zeroPending = false
        }
        let att = m.attitude
        if let ref = referenceAttitude, att !== ref { att.multiply(byInverseOf: ref) }
        let p = att.pitch * 180 / .pi, r = att.roll * 180 / .pi, y = att.yaw * 180 / .pi

        // Publish to the UI throttled (~8 Hz is smooth enough for a readout).
        sampleCount &+= 1
        if sampleCount % 3 == 0 {
            DispatchQueue.main.async {
                self.pitchDeg = p; self.rollDeg = r; self.yawDeg = y
                if !self.anglesLive { self.anglesLive = true }
                self.onAngles?(p, r, y)
            }
        }

        // Log the raw fused sample if a ride is recording.
        guard loggingActive, handle != nil else { return }
        let epoch = baseEpochMs + (m.timestamp - baseUptimeS) * 1000
        let u = m.userAcceleration, g = m.gravity, rot = m.rotationRate
        buffer.append(String(format: "%.0f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f",
                             epoch, u.x, u.y, u.z, g.x, g.y, g.z, rot.x, rot.y, rot.z))
        if buffer.count >= Int(Self.hz) { flush() }
    }

    private func flush() {
        guard let h = handle, !buffer.isEmpty else { return }
        let chunk = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)
        if let data = chunk.data(using: .utf8) { try? h.write(contentsOf: data) }
    }
}
