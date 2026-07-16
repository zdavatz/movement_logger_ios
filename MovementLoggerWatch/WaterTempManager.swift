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

    /// A dry spell must last this long before the held temperature is dropped.
    /// Clearing on the first `.notSubmerged` (the previous behaviour) blanked
    /// the reading for most of a swim: a swimmer's wrist breaks the surface
    /// every stroke, and the sensor's own temperature pushes are far too sparse
    /// to re-fill the gap — so the watch showed "—" while actually swimming.
    /// A walk back on land outlasts this window, so the stale reading still
    /// clears there (which is why the clearing exists at all).
    private static let dryGraceSec: TimeInterval = 60

    @ObservationIgnored private var manager: CMWaterSubmersionManager?
    @ObservationIgnored private var dryClear: DispatchWorkItem?

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
        DispatchQueue.main.async {
            self.dryClear?.cancel(); self.dryClear = nil
            self.temperatureC = nil
        }
    }

    // MARK: - submersion state → hold / expire the reading

    /// Wrist is under: keep the reading and call off any pending expiry.
    private func markSubmerged() {
        DispatchQueue.main.async {
            self.dryClear?.cancel(); self.dryClear = nil
        }
    }

    /// Wrist surfaced: start (but don't restart) the grace countdown. The
    /// sensor never signals "this reading is stale" on its own, so without an
    /// expiry `temperatureC` would hold the last value for the rest of the
    /// session and the walk back on land would log as "in the water".
    private func markDry() {
        DispatchQueue.main.async {
            guard self.dryClear == nil else { return }   // already counting down
            let w = DispatchWorkItem { [weak self] in
                self?.temperatureC = nil
                self?.dryClear = nil
            }
            self.dryClear = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dryGraceSec, execute: w)
        }
    }

    // MARK: - CMWaterSubmersionManagerDelegate

    func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {
        switch event.state {
        case .notSubmerged: markDry()
        case .submerged:    markSubmerged()
        default:            break        // .unknown — leave the current state alone
        }
    }

    func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterSubmersionMeasurement) {
        // Same decision via the depth channel.
        switch measurement.submersionState {
        case .notSubmerged: markDry()
        case .submergedShallow, .submergedDeep, .approachingMaxDepth, .pastMaxDepth:
            markSubmerged()
        default:            break        // .unknown / .sensorDepthError
        }
    }

    func manager(_ manager: CMWaterSubmersionManager, didUpdate temperature: CMWaterTemperature) {
        let celsius = temperature.temperature.converted(to: .celsius).value
        DispatchQueue.main.async {
            // A fresh reading means we're wet — cancel any pending expiry.
            self.dryClear?.cancel(); self.dryClear = nil
            self.temperatureC = celsius
        }
    }

    func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: Error) {}
}
