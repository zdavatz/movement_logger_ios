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
/// Same UI shape (status / rate card / fix readout) so the tab feels
/// identical across platforms. This tab is now a **live readout only** —
/// the old built-in CSV recorder (`iPhoneGps_*`) was removed in favour of
/// the **Phone logger** card, which records GPS **and** motion
/// (`SensPhone_*`/`GpsPhone_*`) and is a strict superset. GpsCore itself
/// stays — Race mode, the phone-as-rider map, and the Phone logger all run
/// on it. Existing `iPhoneGps_*` files still parse + show in Rides/Replay.
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

    // --- Private ---
    private let manager: CLLocationManager
    private let windowSize = 10
    private var arrivalTimes: [Date] = []

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
            enableBackgroundDelivery()
            manager.startUpdatingLocation()
        case .denied, .restricted:
            isReading = false
            status = "Location access denied — enable it in Settings → Privacy → Location"
        @unknown default:
            isReading = false
            status = "Unknown authorization state"
        }
    }

    /// Keep fixes (and the race uplink) flowing with the screen locked.
    /// Requires the `location` UIBackgroundModes entry — setting
    /// `allowsBackgroundLocationUpdates` without it throws. The blue
    /// system indicator makes the background use visible to the user.
    private func enableBackgroundDelivery() {
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        isReading = false
        fixAvailable = false
        status = "Stopped"
        arrivalTimes.removeAll(keepingCapacity: true)
        hz = 0
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        if isReading {
            switch authStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                status = "Waiting for first fix…"
                enableBackgroundDelivery()
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
            // Race mode: no-op unless enabled with the iPhone source.
            RaceUplink.shared.sendFix(
                lat: newest.coordinate.latitude,
                lon: newest.coordinate.longitude,
                kmh: newest.speed >= 0 ? newest.speed * 3.6 : nil,
                deg: newest.course >= 0 ? newest.course : nil,
                acc: newest.horizontalAccuracy,
                from: .phone)
            // Phone-as-rider on the race map: no-op unless "Track this phone" is on.
            PhoneRider.shared.sendFix(
                lat: newest.coordinate.latitude,
                lon: newest.coordinate.longitude,
                kmh: newest.speed >= 0 ? newest.speed * 3.6 : nil,
                deg: newest.course >= 0 ? newest.course : nil,
                acc: newest.horizontalAccuracy)
        } else if !fixAvailable {
            status = "Waiting for first fix…"
        }
        recordArrival(newest.timestamp)
        sampleCount &+= UInt64(locations.count)
        for loc in locations {
            // Phone logger (SensPhone/GpsPhone pair): no-op unless recording.
            PhoneLogger.shared.onFix(loc)
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
}
