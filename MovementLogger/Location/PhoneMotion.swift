import Foundation
import Observation
import CoreMotion

/// Phone board attitude + height for the phone-as-rider path — the iPhone's
/// equivalent of the watch's `WatchImuLogger` live-angle side. When the phone is
/// mounted on the board, `deviceMotion` gives fused, gravity-referenced
/// **pitch / roll / yaw** and `CMAltimeter` gives **height** (relative altitude);
/// `PhoneRider` folds them into its `typ:"board"` datagram so the phone plots on
/// the race map WITH angles, just like a watch rider. Runs only while tracking
/// with "board-mounted" on.
@Observable
final class PhoneMotion {
    static let shared = PhoneMotion()

    var pitchDeg = 0.0
    var rollDeg = 0.0
    var yawDeg = 0.0
    var hasZero = false
    var anglesLive = false
    /// Latest barometric readings (NaN until a sample / between runs).
    @ObservationIgnored var pressureHPa = Double.nan
    @ObservationIgnored var baroAltM = Double.nan

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private let queue: OperationQueue = {
        let q = OperationQueue(); q.name = "phone-motion"; q.maxConcurrentOperationCount = 1; return q
    }()
    @ObservationIgnored private var referenceAttitude: CMAttitude?   // tare
    @ObservationIgnored private var zeroPending = false
    @ObservationIgnored private var clearPending = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var sampleCount = 0

    private init() {}

    func start() {
        guard !running, motion.isDeviceMotionAvailable else { return }
        running = true
        motion.deviceMotionUpdateInterval = 1.0 / 25.0
        motion.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            self.handle(m)
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] d, _ in
                guard let self, let d else { return }
                self.pressureHPa = d.pressure.doubleValue * 10.0   // kPa → hPa
                self.baroAltM = d.relativeAltitude.doubleValue
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pressureHPa = .nan; baroAltM = .nan
        DispatchQueue.main.async { self.anglesLive = false }
    }

    func zero() { zeroPending = true; hasZero = true }
    func clearZero() { clearPending = true; hasZero = false }

    private func handle(_ m: CMDeviceMotion) {
        if clearPending { referenceAttitude = nil; clearPending = false }
        if zeroPending {
            referenceAttitude = m.attitude   // this frame reads identity
            zeroPending = false
            publish(0, 0, 0); return
        }
        let att = m.attitude
        if let ref = referenceAttitude, att !== ref { att.multiply(byInverseOf: ref) }
        publish(att.pitch * 180 / .pi, att.roll * 180 / .pi, att.yaw * 180 / .pi)
    }

    private func publish(_ p: Double, _ r: Double, _ y: Double) {
        sampleCount &+= 1
        guard sampleCount % 3 == 0 else { return }
        DispatchQueue.main.async {
            self.pitchDeg = p; self.rollDeg = r; self.yawDeg = y
            if !self.anglesLive { self.anglesLive = true }
        }
    }
}
