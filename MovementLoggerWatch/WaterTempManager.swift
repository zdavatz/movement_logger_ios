import Foundation
import CoreMotion
import Observation

/// Water temperature from the Apple Watch Ultra's submersion sensor
/// (`CMWaterSubmersionManager`, CoreMotion). Needs the "Shallow Depth &
/// Pressure" capability (entitlement `com.apple.developer.submerged-depth-and-pressure`)
/// and only delivers a reading **while the watch is actually in the water** —
/// otherwise `temperatureC` stays nil and the UI shows "—". Non-Ultra watches
/// report `waterSubmersionAvailable == false`, so this is a graceful no-op.
@Observable
final class WaterTempManager: NSObject, CMWaterSubmersionManagerDelegate {

    private(set) var temperatureC: Double? = nil

    @ObservationIgnored private var manager: CMWaterSubmersionManager?

    /// Begin listening for submersion temperature. Safe to call repeatedly.
    func start() {
        guard manager == nil, CMWaterSubmersionManager.waterSubmersionAvailable else { return }
        let m = CMWaterSubmersionManager()
        m.delegate = self
        manager = m
    }

    func stop() {
        manager?.delegate = nil
        manager = nil
        temperatureC = nil
    }

    // MARK: - CMWaterSubmersionManagerDelegate

    func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {
        // The sensor pushes a temperature only while submerged and never signals
        // "no longer valid" on its own, so `temperatureC` would otherwise HOLD
        // the last reading for the rest of the session — making the walk back on
        // land wrongly read as "in the water" in the ride CSV. Clear it the
        // moment the wrist surfaces.
        if event.state == .notSubmerged {
            DispatchQueue.main.async { self.temperatureC = nil }
        }
    }

    func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterSubmersionMeasurement) {
        // Same intent as above, via the depth/measurement channel: surfaced ⇒
        // drop the held temperature so only actually-submerged seconds log a
        // WaterTemp value.
        if measurement.submersionState == .notSubmerged {
            DispatchQueue.main.async { self.temperatureC = nil }
        }
    }

    func manager(_ manager: CMWaterSubmersionManager, didUpdate temperature: CMWaterTemperature) {
        let celsius = temperature.temperature.converted(to: .celsius).value
        DispatchQueue.main.async { self.temperatureC = celsius }
    }

    func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: Error) {}
}
