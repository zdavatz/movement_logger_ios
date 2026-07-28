import Foundation
import Observation
import CoreMotion
import CoreLocation

/// Box-replacement logger using the iPhone's own sensors — the iOS port of
/// Android's `PhoneLoggerCore`. Records GPS (piggybacking on `GpsCore`'s
/// CoreLocation stream) plus raw accel / gyro / mag / baro (~100 Hz IMU)
/// into the same Sens/Gps CSV pair the box firmware writes:
/// `SensPhone_<stamp>.csv` + `GpsPhone_<stamp>.csv` in `Documents/`. The
/// names start with "Sens"/"Gps" so the Replay tab's pickers list them, and
/// the schemas match `CsvParsers` verbatim — the whole Replay pipeline
/// (pitch / Nasenwinkel, height above water, speed, track) works unchanged.
/// Cross-platform: byte-compatible with the Android `SensPhone_*`/`GpsPhone_*`
/// files, so recordings are interchangeable between the apps.
///
/// Timebase: both files share one `Time [10ms]` tick clock derived from
/// `ProcessInfo.systemUptime` (CoreMotion's `CMLogItem.timestamp` is the
/// same since-boot domain; GPS rows stamp the uptime at arrival — exactly
/// what `GpsCore.monotonicMs` does for its own log). A
/// `# SYNC epoch_ms=… tick_ms=0` anchor after each header maps tick 0 to
/// the phone wall clock — the same marker the box firmware writes on
/// SET_TIME — giving Replay its drift-free "Phone-clock sync" alignment.
///
/// Units convert to the box CSV's — with one iOS-only trap: **Apple's raw
/// accelerometer sign is inverted vs Android/the ST box** (flat on a table
/// Apple reads z = −1 g, the box +1000 mg), so acc is `−g × 1000` mg.
/// Gyro (rad/s, right-hand, device axes) and magnetometer (µT, device
/// axes) match conventions — mdps = rad/s × 180/π × 1000, mgauss = µT × 10.
/// Pressure kPa × 10 = mB. The `T ['C]` column is a constant 20 °C
/// (no ambient thermometer; `Baro` only needs a plausible Kelvin).
///
/// The Android `CsvParsers.parseSensorStream` is strict — one blank field
/// fails the whole file — so no sens row is written until gyro + mag
/// (+ baro when present) have delivered a first sample; a phone without
/// barometer logs a constant 1013.25 mB instead of a blank.
///
/// Backgrounding: `start()` also starts `GpsCore` if it isn't reading —
/// its background-location delivery (blue indicator) keeps the process
/// alive with the screen locked, and CoreMotion keeps delivering on the
/// serial queue. All file IO runs on that one queue — no locks.
@Observable
final class PhoneLogger: @unchecked Sendable {

    static let shared = PhoneLogger()

    // --- published (main thread) ---
    var isRecording = false
    var sensRows: UInt64 = 0
    var gpsRows: UInt64 = 0
    var sensName: String? = nil
    var gpsName: String? = nil
    var hasBaro = true
    /// Non-nil only on failures (file open / sensor unavailable).
    var errorText: String? = nil
    /// URLs of the last finished (or in-flight) pair, for ShareLinks.
    var lastSensURL: URL? = nil
    var lastGpsURL: URL? = nil

    // --- private ---
    /// ~100 Hz IMU — the box's Sens rate.
    private static let imuInterval = 1.0 / 100.0
    private static let gravity = 9.80665
    private static let radToMdps = 180.0 / Double.pi * 1000.0
    /// No ambient thermometer on phones — constant for the `T ['C]` column.
    private static let tempC = 20.0
    /// Sea-level standard, used only when the phone has no barometer.
    private static let noBaroMb = 1013.25
    /// Batch sens rows before each FileHandle write (~4 writes/s at 100 Hz).
    private static let flushEveryRows = 25
    /// Publish the row counters every N sens rows (~2 Hz) so the 100 Hz
    /// stream doesn't hammer SwiftUI observation.
    private static let stateEveryRows: UInt64 = 50

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let altimeter = CMAltimeter()
    /// Serial queue owning ALL sensor callbacks + file IO.
    @ObservationIgnored private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "phone-logger"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    @ObservationIgnored private var recording = false
    @ObservationIgnored private var sensHandle: FileHandle? = nil
    @ObservationIgnored private var gpsHandle: FileHandle? = nil
    @ObservationIgnored private var startUptime: TimeInterval = 0
    @ObservationIgnored private var startedGps = false

    // Latest cached values from the non-accel sensors (NaN = not yet seen).
    @ObservationIgnored private var gyroMdps = (x: Double.nan, y: Double.nan, z: Double.nan)
    @ObservationIgnored private var magMgauss = (x: Double.nan, y: Double.nan, z: Double.nan)
    @ObservationIgnored private var pressureMb = Double.nan
    @ObservationIgnored private var baroPresent = false

    @ObservationIgnored private var sensCount: UInt64 = 0
    @ObservationIgnored private var gpsCount: UInt64 = 0
    @ObservationIgnored private var sensBuf = ""

    @ObservationIgnored private let utcFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss.SS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private init() {}

    // MARK: - Controls (call from the main thread)

    func start() {
        guard !recording else { return }
        errorText = nil
        guard motion.isAccelerometerAvailable, motion.isGyroAvailable else {
            errorText = "Motion sensors unavailable on this device"
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        let stamp = df.string(from: Date())
        let sensURL = docs.appendingPathComponent("SensPhone_\(stamp).csv")
        let gpsURL = docs.appendingPathComponent("GpsPhone_\(stamp).csv")

        // Both headers mirror the box firmware's spaced-name schema, so the
        // parsers read them with tickDiv = 1 (already 10 ms units). The
        // `# SYNC` anchor's tick is in the Time-column unit for the same
        // reason — tick 0 == the epoch sampled right here.
        let epochMs = Int64(Date().timeIntervalSince1970 * 1000)
        startUptime = ProcessInfo.processInfo.systemUptime
        let sync = "# SYNC epoch_ms=\(epochMs) tick_ms=0\n"
        let sensHeader = "Time [10ms],AccX [mg],AccY [mg],AccZ [mg],"
            + "GyroX [mdps],GyroY [mdps],GyroZ [mdps],"
            + "MagX [mgauss],MagY [mgauss],MagZ [mgauss],P [mB],T ['C]\n"
        let gpsHeader =
            "Time [10ms],UTC,Lat [deg],Lon [deg],Alt [m],SpeedKMh,Course [deg],Fix,NumSat,HDOP\n"
        do {
            sensHandle = try Self.createAndOpen(sensURL, contents: sensHeader + sync)
            gpsHandle = try Self.createAndOpen(gpsURL, contents: gpsHeader + sync)
        } catch {
            errorText = "CSV open failed: \(error.localizedDescription)"
            try? sensHandle?.close()
            sensHandle = nil
            return
        }

        gyroMdps = (.nan, .nan, .nan)
        magMgauss = (.nan, .nan, .nan)
        pressureMb = .nan
        sensCount = 0
        gpsCount = 0
        sensBuf = ""
        baroPresent = CMAltimeter.isRelativeAltitudeAvailable()
        recording = true

        motion.gyroUpdateInterval = Self.imuInterval
        motion.startGyroUpdates(to: queue) { [weak self] d, _ in
            guard let self, let d else { return }
            let r = d.rotationRate
            self.gyroMdps = (r.x * Self.radToMdps, r.y * Self.radToMdps, r.z * Self.radToMdps)
        }
        motion.magnetometerUpdateInterval = Self.imuInterval * 2
        motion.startMagnetometerUpdates(to: queue) { [weak self] d, _ in
            guard let self, let d else { return }
            let f = d.magneticField   // µT → mgauss: 1 µT = 10 mG
            self.magMgauss = (f.x * 10.0, f.y * 10.0, f.z * 10.0)
        }
        if baroPresent {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] d, _ in
                guard let self, let d else { return }
                self.pressureMb = d.pressure.doubleValue * 10.0   // kPa → hPa/mB
            }
        }
        motion.accelerometerUpdateInterval = Self.imuInterval
        motion.startAccelerometerUpdates(to: queue) { [weak self] d, _ in
            guard let self, let d else { return }
            self.writeSensRow(d)
        }

        // GPS: fixes flow in via GpsCore's delegate hook (`onFix`). Start
        // the reader if idle — its background-location mode is also what
        // keeps this whole logger alive with the screen locked.
        if !GpsCore.shared.isReading {
            GpsCore.shared.start()
            startedGps = true
        }

        isRecording = true
        hasBaro = baroPresent
        sensRows = 0
        gpsRows = 0
        sensName = sensURL.lastPathComponent
        gpsName = gpsURL.lastPathComponent
        lastSensURL = sensURL
        lastGpsURL = gpsURL
    }

    func stop() {
        guard recording else { return }
        recording = false
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        motion.stopMagnetometerUpdates()
        if baroPresent { altimeter.stopRelativeAltitudeUpdates() }
        queue.addOperation { [self] in
            flushSensBuf()
            try? sensHandle?.close()
            try? gpsHandle?.close()
            sensHandle = nil
            gpsHandle = nil
            DispatchQueue.main.async {
                self.sensRows = self.sensCount
                self.gpsRows = self.gpsCount
            }
        }
        // Only tear down the GPS reader if we started it and it isn't busy
        // with its own iPhoneGps_* recording.
        if startedGps && !GpsCore.shared.isLogging {
            GpsCore.shared.stop()
        }
        startedGps = false
        isRecording = false
    }

    /// Phone fix from `GpsCore`'s CoreLocation delegate — no-op unless a
    /// recording is open. Hops onto the logger queue so all IO stays
    /// single-threaded.
    func onFix(_ loc: CLLocation) {
        guard recording else { return }
        queue.addOperation { [self] in writeGpsRow(loc) }
    }

    // MARK: - Row writers (phone-logger queue only)

    private func writeSensRow(_ d: CMAccelerometerData) {
        guard recording, sensHandle != nil else { return }
        // Android's parser is strict (one blank field fails the file) and
        // these CSVs are cross-platform — hold rows until every present
        // sensor has reported once so no field is ever blank.
        if gyroMdps.x.isNaN || magMgauss.x.isNaN || (baroPresent && pressureMb.isNaN) { return }
        let ticks = Int64((d.timestamp - startUptime) * 100.0)   // 10 ms units
        guard ticks >= 0 else { return }
        // Apple raw accel is −(specific force)/g — negate into box mg.
        let a = d.acceleration
        let p = baroPresent ? pressureMb : Self.noBaroMb
        let row = String(
            format: "%lld,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f\n",
            ticks,
            -a.x * 1000.0, -a.y * 1000.0, -a.z * 1000.0,
            gyroMdps.x, gyroMdps.y, gyroMdps.z,
            magMgauss.x, magMgauss.y, magMgauss.z,
            p, Self.tempC
        )
        sensBuf += row
        sensCount &+= 1
        if sensCount % UInt64(Self.flushEveryRows) == 0 { flushSensBuf() }
        if sensCount % Self.stateEveryRows == 0 {
            let n = sensCount
            DispatchQueue.main.async { self.sensRows = n }
        }
    }

    private func flushSensBuf() {
        guard !sensBuf.isEmpty, let h = sensHandle else { return }
        if let data = sensBuf.data(using: .utf8) {
            try? h.write(contentsOf: data)
        }
        sensBuf = ""
    }

    private func writeGpsRow(_ loc: CLLocation) {
        guard recording, let h = gpsHandle else { return }
        // Uptime at arrival — the same clock domain as the sensor ticks
        // (and as GpsCore's own log). CLLocation.timestamp only feeds the
        // UTC column for the legacy GPS-derived alignment path.
        let ticks = Int64((ProcessInfo.processInfo.systemUptime - startUptime) * 100.0)
        guard ticks >= 0 else { return }
        let utc = utcFmt.string(from: loc.timestamp)
        let speedKmh = loc.speed >= 0 ? loc.speed * 3.6 : Double.nan
        let course = loc.course >= 0 ? loc.course : Double.nan
        // iOS altitude is already MSL (unlike Android's ellipsoidal GNSS
        // altitude), matching the box's NMEA altitude semantics directly.
        // HDOP ≈ accuracy / 5 m UERE — same proxy as the Android logger, so
        // downstream quality gates (hdop ≤ 50) mean the same thing.
        let acc = loc.horizontalAccuracy
        let hdop = acc >= 0 ? acc / 5.0 : Double.nan
        let row = String(ticks) + "," + utc + ","
            + field(loc.coordinate.latitude, "%.6f") + ","
            + field(loc.coordinate.longitude, "%.6f") + ","
            + field(loc.altitude, "%.1f") + ","
            + field(speedKmh, "%.2f") + ","
            + field(course, "%.1f") + ",1,0,"
            + field(hdop, "%.2f") + "\n"
        if let data = row.data(using: .utf8) {
            try? h.write(contentsOf: data)
        }
        gpsCount &+= 1
        let g = gpsCount
        let s = sensCount
        DispatchQueue.main.async {
            self.gpsRows = g
            self.sensRows = s
        }
    }

    private func field(_ v: Double, _ fmt: String) -> String {
        v.isNaN ? "" : String(format: fmt, v)
    }

    private static func createAndOpen(_ url: URL, contents: String) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: contents.data(using: .utf8))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        return h
    }
}
