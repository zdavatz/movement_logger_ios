import Foundation

/// Madgwick 6DOF AHRS — Swift port of `Madgwick.kt` / `fusion.rs`. IMU-only
/// (acc + gyro), magnetometer deliberately skipped because the LIS2MDL drifts
/// and couples roll/pitch through the 9DOF gradient on this hardware.
///
/// Quaternion layout is [w, x, y, z]. Input units: acc in mg (any unit
/// works, only direction matters), gyro in mdps (converted to rad/s
/// internally).

private let degToRad: Double = .pi / 180.0

final class Madgwick {
    var beta: Double
    /// [w, x, y, z] — updated in place by `updateImu`.
    var q: [Double] = [1.0, 0.0, 0.0, 0.0]

    init(beta: Double) {
        self.beta = beta
    }

    /// Advance the filter by one sample. `dt` in seconds.
    func updateImu(gyroRad: [Double], acc: [Double], dt: Double) {
        precondition(gyroRad.count == 3 && acc.count == 3)
        var q0 = q[0], q1 = q[1], q2 = q[2], q3 = q[3]
        let gx = gyroRad[0], gy = gyroRad[1], gz = gyroRad[2]
        var ax = acc[0], ay = acc[1], az = acc[2]

        // Rate of change from gyro only
        var dQ0 = 0.5 * (-q1 * gx - q2 * gy - q3 * gz)
        var dQ1 = 0.5 * (q0 * gx + q2 * gz - q3 * gy)
        var dQ2 = 0.5 * (q0 * gy - q1 * gz + q3 * gx)
        var dQ3 = 0.5 * (q0 * gz + q1 * gy - q2 * gx)

        // Accelerometer correction
        let aNorm = sqrt(ax * ax + ay * ay + az * az)
        if aNorm > 1e-9 {
            ax /= aNorm; ay /= aNorm; az /= aNorm

            let _2q0 = 2.0 * q0
            let _2q1 = 2.0 * q1
            let _2q2 = 2.0 * q2
            let _2q3 = 2.0 * q3
            let _4q0 = 4.0 * q0
            let _4q1 = 4.0 * q1
            let _4q2 = 4.0 * q2
            let _8q1 = 8.0 * q1
            let _8q2 = 8.0 * q2
            let q0q0 = q0 * q0
            let q1q1 = q1 * q1
            let q2q2 = q2 * q2
            let q3q3 = q3 * q3

            let s0 = _4q0 * q2q2 + _2q2 * ax + _4q0 * q1q1 - _2q1 * ay
            let s1 = _4q1 * q3q3 - _2q3 * ax + 4.0 * q0q0 * q1 - _2q0 * ay - _4q1
                + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * az
            let s2 = 4.0 * q0q0 * q2 + _2q0 * ax + _4q2 * q3q3 - _2q3 * ay - _4q2
                + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * az
            let s3 = 4.0 * q1q1 * q3 - _2q1 * ax + 4.0 * q2q2 * q3 - _2q2 * ay

            let sNorm = sqrt(s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3)
            if sNorm > 1e-9 {
                let inv = 1.0 / sNorm
                dQ0 -= beta * s0 * inv
                dQ1 -= beta * s1 * inv
                dQ2 -= beta * s2 * inv
                dQ3 -= beta * s3 * inv
            }
        }

        q0 += dQ0 * dt
        q1 += dQ1 * dt
        q2 += dQ2 * dt
        q3 += dQ3 * dt

        let n = sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3)
        if n > 1e-9 {
            let inv = 1.0 / n
            q[0] = q0 * inv; q[1] = q1 * inv; q[2] = q2 * inv; q[3] = q3 * inv
        } else {
            q[0] = 1.0; q[1] = 0.0; q[2] = 0.0; q[3] = 0.0
        }
    }
}

enum Fusion {

    /// Run 6DOF fusion across all sensor samples. Returns one quaternion
    /// (length-4 `[Double]`) per input row. Sample rate is auto-detected
    /// from the tick delta.
    static func computeQuaternions(_ samples: [SensorRow], beta: Double) -> [[Double]] {
        guard !samples.isEmpty else { return [] }
        let dt = detectDtSeconds(samples)
        let f = Madgwick(beta: beta)
        var gyro = [Double](repeating: 0, count: 3)
        var acc = [Double](repeating: 0, count: 3)
        var out: [[Double]] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            gyro[0] = s.gyroX * 0.001 * degToRad
            gyro[1] = s.gyroY * 0.001 * degToRad
            gyro[2] = s.gyroZ * 0.001 * degToRad
            acc[0] = s.accX; acc[1] = s.accY; acc[2] = s.accZ
            f.updateImu(gyroRad: gyro, acc: acc, dt: dt)
            out.append(f.q)
        }
        return out
    }

    /// Per-sample dt in seconds from the median tick delta. 1 tick = 10 ms,
    /// so median 1 tick means 100 Hz sampling and dt = 0.01 s.
    static func detectDtSeconds(_ samples: [SensorRow]) -> Double {
        if samples.count < 2 { return 0.01 }
        var deltas = [Double](repeating: 0, count: samples.count - 1)
        for i in 0..<(samples.count - 1) {
            deltas[i] = samples[i + 1].ticks - samples[i].ticks
        }
        deltas.sort()
        let median = deltas[deltas.count / 2]
        return max(median * 0.01, 0.0001)
    }

    /// Board nose elevation (°) from one quaternion. Sensor is mounted with
    /// its Y-axis along the board nose direction (Breitachse); rotating
    /// body-frame Y into world frame gives `nose_z = 2·(qj·qk − qs·qi)`.
    static func noseZComponent(_ q: [Double]) -> Double {
        precondition(q.count == 4)
        let v = 2.0 * (q[2] * q[3] - q[0] * q[1])
        return min(max(v, -1.0), 1.0)
    }

    /// Full nose-angle series in degrees, with 1-second median smoothing
    /// and a 60-second rolling baseline subtraction (drift correction).
    static func noseAngleSeriesDeg(_ quats: [[Double]], sampleHz: Int) -> [Double] {
        let n = quats.count
        var raw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            raw[i] = asin(noseZComponent(quats[i])) * 180.0 / .pi
        }
        let w1 = max(sampleHz, 1)
        let smoothed = GpsMath.rollingMedian(raw, window: w1)
        let w60 = 60 * sampleHz
        let baseline = GpsMath.rollingMedian(smoothed, window: w60)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n { out[i] = smoothed[i] - baseline[i] }
        return out
    }
}
