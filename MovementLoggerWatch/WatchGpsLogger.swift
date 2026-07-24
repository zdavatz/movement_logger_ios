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
    /// Top speed (km/h) seen this session — reset on `start()`. Only fixes that
    /// pass `qualifiesForTop` count; see there for why a raw running max lies.
    private(set) var maxSpeedKmh: Double = 0
    /// Current speed (km/h) of the freshest fix, for a live readout and the
    /// race uplink. Deliberately NOT filtered — it's a live sample that decays
    /// on the next fix, so a spike is transient rather than sticky.
    private(set) var speedKmh: Double = 0

    // MARK: top-speed gating (see `qualifiesForTop`)

    /// Ignore a fix this inaccurate for TOP. Mirrors the phone's
    /// `RideMapRenderer.maxPlausibleHdop`.
    private static let topMaxAccM = 50.0
    /// Nobody on a foil does this. Mirrors `maxPlausibleSpeedKmh`.
    private static let topClipKmh = 60.0
    /// A delivery gap this long means the receiver lost the fix.
    private static let topGapSec = 2.0
    /// …and for this long after re-acquiring (or after the session starts) its
    /// velocity solution is not to be trusted.
    private static let topSuppressSec = 10.0

    @ObservationIgnored private var lastFixAt: Date?
    @ObservationIgnored private var topSuppressUntil: Date?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var latest: CLLocation?
    /// Injected by SessionController: the Ultra's submersion water
    /// temperature (°C) while the wrist is in the water, else nil. Logged
    /// as the `WaterTemp [C]` column so rides carry it to the phone.
    @ObservationIgnored var waterTempProvider: (() -> Double?)? = nil
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var csvHandle: FileHandle?
    /// URL of the CSV for the current/just-finished ride — handed to
    /// WatchConnectivity to sync to the phone when the session ends.
    @ObservationIgnored private(set) var csvURL: URL?
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
        maxSpeedKmh = 0
        speedKmh = 0
        WindAtTop.shared.sessionStarted()
        // The receiver is still settling for the first seconds of a session —
        // same distrust as after a mid-ride dropout (the phone blacks out the
        // session's opening samples for exactly this reason).
        lastFixAt = nil
        topSuppressUntil = Date().addingTimeInterval(Self.topSuppressSec)
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
        // A delivery gap means the receiver lost the fix; distrust TOP for a
        // while after it comes back (below).
        let ts = newest.timestamp
        if let last = lastFixAt, ts.timeIntervalSince(last) > Self.topGapSec {
            topSuppressUntil = ts.addingTimeInterval(Self.topSuppressSec)
        }
        lastFixAt = ts

        // Speed / top speed (CLLocation.speed is m/s; -1 = invalid).
        if newest.speed >= 0 {
            speedKmh = newest.speed * 3.6
            if speedKmh > maxSpeedKmh, qualifiesForTop(newest, at: ts) {
                maxSpeedKmh = speedKmh
                // Stamp the wind blowing at this TOP moment (WIND metric).
                WindAtTop.shared.noteTop(newest, at: ts)
            }
        }
        // Feed the wind fetcher's prefetch/retry loop (throttled inside).
        if newest.horizontalAccuracy >= 0 {
            WindAtTop.shared.noteFix(newest)
        }
    }

    /// Whether this fix's speed may set the session TOP.
    ///
    /// TOP was a raw running max, so ONE bad sample owned the readout for the
    /// rest of the session — it never decays. On the 16.7.2026 evening ride that
    /// showed **26.4 km/h while the wearer was swimming**: the receiver froze for
    /// 44 s, re-acquired, and reported ~26 km/h for five straight seconds while
    /// the positions it returned moved 2–4 m/s (≈9 km/h). It is *not* catchable
    /// by accuracy — that fix claimed a healthy ±17.8 m — nor by demanding the
    /// speed be sustained, since it was sustained.
    ///
    /// What gives it away is the 44 s hole in front of it: a receiver that just
    /// re-acquired has a garbage velocity solution for a few seconds. So this
    /// mirrors the phone's `RideMapRenderer.robustTopSpeed` blackout rule —
    /// distrust everything within `topSuppressSec` of a `topGapSec` gap, and at
    /// the session start. Verified against all 10 watch rides: the evening ride
    /// reads 11.3 km/h vs the phone's independent post-hoc 11.0, and three other
    /// rides land exactly on the phone's number.
    ///
    /// The phone stays the authority (it can look both ways around a sample);
    /// this only has to stop the live readout being nonsense.
    private func qualifiesForTop(_ loc: CLLocation, at ts: Date) -> Bool {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= Self.topMaxAccM,
              loc.speed * 3.6 <= Self.topClipKmh else { return false }
        if let until = topSuppressUntil, ts <= until { return false }
        return true
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
        let header = "Time [10ms],UTC,Lat [deg],Lon [deg],Alt [m],SpeedKMh,Course [deg],Fix,NumSat,HDOP,WaterTemp [C]\n"
        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        csvHandle = try? FileHandle(forWritingTo: url)
        _ = try? csvHandle?.seekToEnd()   // append after the header row
        logName = name
        csvURL = url
        // Mark it in-flight so a re-send pass doesn't ship a half-written ride.
        WatchSync.shared.activeRide = url
    }

    private func closeCsv() {
        try? csvHandle?.close()
        csvHandle = nil
        WatchSync.shared.activeRide = nil
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
            fmt(waterTempProvider?() ?? nil),
        ].joined(separator: ",") + "\n"
        if let data = row.data(using: .utf8) {
            try? h.write(contentsOf: data)
            loggedRows &+= 1
        }
        // Race mode: mirror the same 1 Hz grid to the phone. No-op
        // unless the phone raised the relay flag and is reachable.
        if hasFix, let loc {
            WatchSync.shared.relayLiveFix(
                lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                kmh: speedKmh, deg: courseDeg, acc: loc.horizontalAccuracy)
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
