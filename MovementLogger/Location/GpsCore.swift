import Foundation
import CoreLocation
import Observation

/// iOS pendant of the Android `UbloxGpsCore` — *not* a literal port. iOS
/// doesn't let third-party apps read generic USB CDC-ACM, so we use the
/// iPhone's own GNSS via `CoreLocation` instead.
///
/// Trade-offs vs the Android external u-blox build:
///  - **Rate**: capped at ~1 Hz by `CoreLocation`'s public API (Android
///    u-blox dongle pushes 5 Hz).
///  - **Precision**: on dual-band iPhones (14 Pro / 15 Pro / 16 Pro /
///    17 Pro …) typically 1–3 m horizontal CEP — better single-fix than
///    the L1-only MAX-M10S in the dongle.
///  - **Speed**: `CLLocation.speed` is fused (GPS Doppler + accelerometer)
///    rather than raw Doppler. Smoother for car nav, slightly damped
///    vs raw for foiling cadence work.
///
/// Same UI shape (status / rate card / fix readout / CSV record) so the
/// tab feels identical across platforms. CSV columns match the box's
/// `Gps*.csv` schema so Replay picks the file up without parser changes;
/// `NumSat` is left at 0 (Apple doesn't expose it) and `HDOP` is
/// substituted with `horizontalAccuracy` in metres — both are "how good
/// is this fix" indicators, so the column stays meaningful.
@Observable
final class GpsCore: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    static let shared = GpsCore()

    // --- Authorisation / lifecycle ---
    var authStatus: CLAuthorizationStatus = .notDetermined
    /// True between `start()` and `stop()`. Doesn't imply we have a fix yet —
    /// that's `fixAvailable`.
    var isReading: Bool = false
    var status: String = "Tap Start to begin reading the iPhone GPS"

    // --- Most-recent fix ---
    /// `nil` until the first valid fix arrives. `CLLocation.horizontalAccuracy`
    /// negative means "no fix" — we filter those out before publishing.
    var latestLocation: CLLocation? = nil
    var fixAvailable: Bool = false

    // --- Rate counters (rolling window) ---
    /// Decaying running average over the last `windowSize` arrivals so the
    /// displayed Hz settles in ~2 s but doesn't jitter every update.
    var hz: Double = 0.0
    var sampleCount: UInt64 = 0

    // --- CSV logger ---
    var isLogging: Bool = false
    var logPath: String? = nil
    var loggedRows: UInt64 = 0

    // --- Private ---
    private let manager: CLLocationManager
    private let windowSize = 10
    private var arrivalTimes: [Date] = []
    private var csvHandle: FileHandle? = nil
    private var csvFileURL: URL? = nil
    private var csvStartMonoMs: Int64 = 0

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // `bestForNavigation` is the highest-precision mode the public API
        // exposes — uses dual-band on supported iPhones and unlocks the
        // accelerometer-augmented dead-reckoning path.
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        authStatus = manager.authorizationStatus
    }

    // MARK: - Public controls

    /// First call from the UI: ask for permission (when in use). `start()`
    /// is safe to call before the user grants; we re-arm in
    /// `locationManagerDidChangeAuthorization` once the answer comes back.
    func start() {
        isReading = true
        switch authStatus {
        case .notDetermined:
            status = "Requesting location permission…"
            manager.requestWhenInUseAuthorization()
            // updates will start from the delegate once permission lands
        case .authorizedWhenInUse, .authorizedAlways:
            status = "Waiting for first fix…"
            manager.startUpdatingLocation()
        case .denied, .restricted:
            isReading = false
            status = "Location access denied — enable it in Settings → Privacy → Location"
        @unknown default:
            isReading = false
            status = "Unknown authorization state"
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isReading = false
        fixAvailable = false
        status = "Stopped"
        arrivalTimes.removeAll(keepingCapacity: true)
        hz = 0
        stopLogging()
    }

    // MARK: - CSV logger

    func startLogging() {
        guard csvHandle == nil else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let name = "iPhoneGps_" + df.string(from: Date()) + ".csv"
        let url = docs.appendingPathComponent(name)
        // Header: identical column names to box `Gps*.csv` so the existing
        // `CsvParsers.parseGpsStream` reads it. The `Time [10ms]` ticks are
        // synthesised from the log-start monotonic offset.
        let header = "Time [10ms],UTC,Lat [deg],Lon [deg],Alt [m],SpeedKMh,Course [deg],Fix,NumSat,HDOP\n"
        do {
            FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            csvHandle = h
            csvFileURL = url
            csvStartMonoMs = Self.monotonicMs()
            isLogging = true
            logPath = url.path
            loggedRows = 0
        } catch {
            status = "CSV log open failed: \(error.localizedDescription)"
        }
    }

    func stopLogging() {
        guard let h = csvHandle else { return }
        try? h.close()
        csvHandle = nil
        isLogging = false
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        if isReading {
            switch authStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                status = "Waiting for first fix…"
                manager.startUpdatingLocation()
            case .denied, .restricted:
                isReading = false
                status = "Location access denied — enable it in Settings → Privacy → Location"
            default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Newest-first: CoreLocation can deliver a batch (especially after
        // backgrounding); we publish the freshest and write all to CSV.
        guard let newest = locations.last else { return }
        // Negative horizontal accuracy = "no fix" per Apple docs.
        let validFix = newest.horizontalAccuracy >= 0
        if validFix {
            latestLocation = newest
            fixAvailable = true
            status = "Reading \(String(format: "%.1f", hz)) Hz · accuracy ±\(Int(newest.horizontalAccuracy.rounded())) m"
        } else if !fixAvailable {
            status = "Waiting for first fix…"
        }
        recordArrival(newest.timestamp)
        sampleCount &+= UInt64(locations.count)
        for loc in locations {
            appendCsvRow(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let ns = error as NSError
        // kCLErrorLocationUnknown is transient; CL keeps trying.
        if ns.domain == kCLErrorDomain && ns.code == CLError.locationUnknown.rawValue { return }
        status = "Location error: \(ns.localizedDescription)"
    }

    // MARK: - Helpers

    private func recordArrival(_ t: Date) {
        arrivalTimes.append(t)
        if arrivalTimes.count > windowSize {
            arrivalTimes.removeFirst(arrivalTimes.count - windowSize)
        }
        guard arrivalTimes.count >= 2,
              let first = arrivalTimes.first,
              let last = arrivalTimes.last else { hz = 0; return }
        let span = last.timeIntervalSince(first)
        hz = span > 0 ? Double(arrivalTimes.count - 1) / span : 0
    }

    private func appendCsvRow(_ loc: CLLocation) {
        guard let h = csvHandle else { return }
        let ticks = max(0, (Self.monotonicMs() - csvStartMonoMs) / 10)
        let utc: String = {
            let f = DateFormatter()
            f.dateFormat = "HHmmss.SS"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f.string(from: loc.timestamp)
        }()
        // Doppler-derived speed is in m/s on iOS; convert to km/h to match
        // the box. CoreLocation reports `-1` for invalid speed/course.
        let speedKmh = loc.speed >= 0 ? loc.speed * 3.6 : Double.nan
        let courseDeg = loc.course >= 0 ? loc.course : Double.nan
        let fix = loc.horizontalAccuracy >= 0 ? 1 : 0
        let hdopProxy = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : Double.nan
        let row = [
            String(ticks),
            utc,
            fmt(loc.coordinate.latitude),
            fmt(loc.coordinate.longitude),
            fmt(loc.altitude),
            fmt(speedKmh),
            fmt(courseDeg),
            String(fix),
            "0",
            fmt(hdopProxy),
        ].joined(separator: ",") + "\n"
        if let data = row.data(using: .utf8) {
            try? h.write(contentsOf: data)
            loggedRows &+= 1
        }
    }

    private func fmt(_ v: Double) -> String {
        guard !v.isNaN else { return "" }
        return String(format: "%.6f", v)
    }

    private static func monotonicMs() -> Int64 {
        // `systemUptime` returns seconds since boot — monotonic for our
        // use case (ticks since log start) and survives mid-session
        // suspensions. Don't substitute `Date()`: NTP/manual clock jumps
        // would back-step the ticks column.
        return Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
