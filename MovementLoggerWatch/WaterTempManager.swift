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

    func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {}

    func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterSubmersionMeasurement) {}

    func manager(_ manager: CMWaterSubmersionManager, didUpdate temperature: CMWaterTemperature) {
        let celsius = temperature.temperature.converted(to: .celsius).value
        DispatchQueue.main.async { self.temperatureC = celsius }
    }

    func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: Error) {}
}
