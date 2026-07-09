import Foundation
import CoreLocation
import Observation

/// Fallback recorder used when no box is connected: samples the watch's own
/// GNSS via CoreLocation and writes exactly **one row per second** until
/// stopped.
///
/// Adapted from `movement_logger_ios/MovementLogger/Location/GpsCore.swift`.
/// Two deliberate differences from the iOS version:
///  - A 1 Hz wall-clock timer drives the CSV, not CoreLocation's own delivery
///    cadence — so the file has a steady one-sample-per-second grid using the
///    freshest fix, matching the requirement precisely (CoreLocation's native
///    rate jitters around 1 Hz).
///  - `allowsBackgroundLocationUpdates` is enabled so fixes keep flowing while
///    the wrist is down; this only actually works while a `WorkoutKeepAlive`
///    session holds the app awake (see `WKBackgroundModes` in Info.plist).
///
/// The CSV column layout matches the box's `Gps*.csv` schema so the existing
/// desktop / iOS Replay parsers read it unchanged. `NumSat` is left 0 (Apple
/// doesn't expose it) and `HDOP` carries `horizontalAccuracy` in metres.
@Observable
final class WatchGpsLogger: NSObject, CLLocationManagerDelegate {

    private(set) var authStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isLogging = false
    private(set) var fixAvailable = false
    private(set) var loggedRows: UInt64 = 0
    private(set) var status = "Idle"
    private(set) var logName: String? = nil

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var latest: CLLocation?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var csvHandle: FileHandle?
    @ObservationIgnored private var startUptimeMs: Int64 = 0
    /// Set by `start()`, cleared by `stop()`. Lets us begin updates from the
    /// authorization callback if permission was still pending at Start.
    @ObservationIgnored private var wantLog = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        authStatus = manager.authorizationStatus
    }

    // MARK: - Controls

    func start() {
        guard !isLogging else { return }
        wantLog = true
        loggedRows = 0
        fixAvailable = false
        switch authStatus {
        case .notDetermined:
            status = "Requesting location permission…"
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            wantLog = false
            status = "Location denied — enable it in the Watch Settings"
        @unknown default:
            wantLog = false
            status = "Location unavailable"
        }
    }

    func stop() {
        wantLog = false
        manager.stopUpdatingLocation()
        tickTimer?.invalidate()
        tickTimer = nil
        closeCsv()
        isLogging = false
        fixAvailable = false
        status = "Stopped"
    }

    private func beginUpdates() {
        guard !isLogging else { return }
        status = "Waiting for GPS fix…"
        // NB: do NOT set `manager.allowsBackgroundLocationUpdates = true` on
        // watchOS — it throws unless `WKBackgroundModes` contains `location`,
        // which the App Store rejects (error 90362). This app runs in the
        // foreground during an active workout session, so background location
        // isn't needed; setting it was the crash on Start.
        manager.startUpdatingLocation()
        openCsv()
        startUptimeMs = Self.uptimeMs()
        isLogging = true

        // One row per second, driven off the run loop (kept alive by the
        // workout session in the background).
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.writeRow() }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        guard wantLog, !isLogging else { return }
        switch authStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            wantLog = false
            status = "Location denied — enable it in the Watch Settings"
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        latest = newest
        if newest.horizontalAccuracy >= 0 {
            fixAvailable = true
            status = "Recording · ±\(Int(newest.horizontalAccuracy.rounded())) m"
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let ns = error as NSError
        if ns.domain == kCLErrorDomain && ns.code == CLError.locationUnknown.rawValue { return }
        status = "Location error: \(ns.localizedDescription)"
    }

    // MARK: - CSV

    private func openCsv() {
        guard csvHandle == nil else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let name = "WatchGps_" + Self.stamp(Date()) + ".csv"
        let url = docs.appendingPathComponent(name)
        let header = "Time [10ms],UTC,Lat [deg],Lon [deg],Alt [m],SpeedKMh,Course [deg],Fix,NumSat,HDOP\n"
        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        csvHandle = try? FileHandle(forWritingTo: url)
        _ = try? csvHandle?.seekToEnd()   // append after the header row
        logName = name
    }

    private func closeCsv() {
        try? csvHandle?.close()
        csvHandle = nil
    }

    /// Emit one row for the current second using the freshest fix. Called on a
    /// 1 s timer, so the CSV has a steady per-second grid even if CoreLocation
    /// delivers irregularly. If no fix yet, the row records `Fix=0` so the
    /// cadence (and elapsed alignment) is preserved.
    private func writeRow() {
        guard let h = csvHandle else { return }
        let ticks = max(0, (Self.uptimeMs() - startUptimeMs) / 10)
        let loc = latest
        let hasFix = (loc?.horizontalAccuracy ?? -1) >= 0
        let speedKmh = (loc?.speed ?? -1) >= 0 ? (loc!.speed * 3.6) : Double.nan
        let courseDeg = (loc?.course ?? -1) >= 0 ? loc!.course : Double.nan
        let hdop = hasFix ? loc!.horizontalAccuracy : Double.nan
        let row = [
            String(ticks),
            Self.utc(loc?.timestamp ?? Date()),
            fmt(loc?.coordinate.latitude),
            fmt(loc?.coordinate.longitude),
            fmt(loc?.altitude),
            fmt(speedKmh),
            fmt(courseDeg),
            hasFix ? "1" : "0",
            "0",
            fmt(hdop),
        ].joined(separator: ",") + "\n"
        if let data = row.data(using: .utf8) {
            try? h.write(contentsOf: data)
            loggedRows &+= 1
        }
    }

    // MARK: - Helpers

    private func fmt(_ v: Double?) -> String {
        guard let v, !v.isNaN else { return "" }
        return String(format: "%.6f", v)
    }

    private static func utc(_ t: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss.SS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: t)
    }

    private static func stamp(_ t: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: t)
    }

    /// Monotonic milliseconds since boot — immune to NTP / manual clock jumps
    /// that would otherwise back-step the `Time [10ms]` tick column.
    private static func uptimeMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
