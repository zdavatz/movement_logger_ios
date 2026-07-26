import Foundation
import CoreMotion

/// Records the Apple Watch's fused inertial motion into a **separate** CSV
/// (`WatchImu_<stamp>.csv`), paired to the watch-GPS ride of the same stamp.
///
/// Why a separate file, and why raw: the ride CSV is a clean 1 Hz GPS grid the
/// phone/desktop parsers already read — bolting a 25 Hz motion stream onto it
/// would bloat it and break the schema. And we're still *developing* the
/// activity classifier (belly-paddle vs foil-pump vs gliding), so we log the
/// raw fused samples rather than pre-computed per-second features: that lets the
/// phone-side classifier be tuned against the real waveform. Once the classifier
/// is validated this can be slimmed to compact per-second features (or moved
/// on-watch).
///
/// Channel: `CMMotionManager.deviceMotion` — the sensor-FUSED output, so gravity
/// is already separated from `userAcceleration`. That split is exactly what
/// tells the strokes apart: a belly-paddle is a large fore-aft arm swing, a
/// foil-pump is a vertical body heave (~1 Hz), gliding/waiting is near-still.
/// Cadence tops out ~1.5 Hz, so 25 Hz (≥16 samples/cycle) is ample and cheap —
/// the 800 Hz `CMBatchedSensorManager` firehose is for a golf swing, not this.
/// Updates keep flowing in the background because a `WorkoutKeepAlive` session
/// is already holding the app awake for the GPS logger.
final class WatchImuLogger {

    /// 25 Hz — comfortably above Nyquist for a ~1.5 Hz stroke, light on power.
    private static let hz = 25.0

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "watch-imu"
        q.maxConcurrentOperationCount = 1   // serial: the handler + flush share it
        return q
    }()

    private var handle: FileHandle?
    private(set) var csvURL: URL?
    private var isLogging = false

    /// Absolute-time base so each sample carries an epoch-ms stamp that lines up
    /// with the GPS ride's UTC column. `motion.timestamp` is seconds-since-boot
    /// (same domain as `systemUptime`); anchoring it to one wall-clock read at
    /// start keeps the per-sample time monotonic and free of per-sample `Date()`.
    private var baseEpochMs: Double = 0
    private var baseUptimeS: Double = 0

    /// Rows buffered on the motion queue, flushed ~once per second so the file
    /// isn't hit 25×/s.
    private var buffer: [String] = []

    /// Begin logging into `WatchImu_<stamp>.csv`. `stamp` MUST match the paired
    /// GPS ride's filename stamp so the phone can associate the two.
    func start(stamp: String) {
        guard !isLogging, motion.isDeviceMotionAvailable else { return }
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
        motion.deviceMotionUpdateInterval = 1.0 / Self.hz
        isLogging = true
        motion.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            self.append(m)
        }
    }

    /// Stop and flush. Keeps `csvURL` set so `stop()` can hand the file to
    /// `WatchSync` for transfer to the phone.
    func stop() {
        guard isLogging else { return }
        isLogging = false
        motion.stopDeviceMotionUpdates()
        // Drain the buffer on the same serial queue the handler used, so the
        // final partial second isn't lost to a race.
        queue.addOperation { [weak self] in self?.flush(force: true) }
        queue.waitUntilAllOperationsAreFinished()
        try? handle?.close()
        handle = nil
    }

    private func append(_ m: CMDeviceMotion) {
        let epoch = baseEpochMs + (m.timestamp - baseUptimeS) * 1000
        let u = m.userAcceleration, g = m.gravity, r = m.rotationRate
        buffer.append(String(format: "%.0f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f",
                             epoch, u.x, u.y, u.z, g.x, g.y, g.z, r.x, r.y, r.z))
        if buffer.count >= Int(Self.hz) { flush(force: false) }
    }

    private func flush(force: Bool) {
        guard let h = handle, !buffer.isEmpty else { return }
        let chunk = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)
        if let data = chunk.data(using: .utf8) { try? h.write(contentsOf: data) }
    }
}
