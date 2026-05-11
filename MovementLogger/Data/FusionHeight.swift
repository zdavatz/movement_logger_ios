import Foundation

/// Complementary baro + accelerometer fusion for vertical position —
/// Swift port of `FusionHeight.kt` / `fusion_height.rs`.
///
/// Pure baro after TC-correction has ~10-20 cm noise floor, so 1 Hz pump
/// strokes (5-15 cm amplitude) are at the edge of visibility. Integrated
/// world-frame vertical acc has sub-cm noise but drifts. Mixing the two
/// with an α-β filter gives short-term cleanliness of acc and long-term
/// absolute level of baro.
///
///     pos_pred = pos + vel·dt + 0.5·a·dt²
///     vel_pred = vel + a·dt
///     r        = baro_height − pos_pred
///     pos      = pos_pred + α·r
///     vel      = vel_pred + (β/dt)·r
///
/// With α = 0.02, β = α²/2 the crossover is ~0.3 Hz: below baro dominates,
/// above (including 1 Hz pump) acc dominates.
enum FusionHeight {

    private static let gravityMs2: Double = 9.80665
    private static let mgToMs2: Double = gravityMs2 / 1000.0

    static func fusedHeightM(
        sensors: [SensorRow],
        quats: [[Double]],
        baroHeight: [Double],
        sampleHz: Double
    ) -> [Double] {
        let n = sensors.count
        precondition(quats.count == n)
        precondition(baroHeight.count == n)
        guard n > 0 else { return [] }

        let dt = 1.0 / sampleHz
        let alpha = 0.02
        let beta = alpha * alpha * 0.5

        var pos = baroHeight[0]
        var vel = 0.0
        var out = [Double](repeating: 0, count: n)
        var aBody = [Double](repeating: 0, count: 3)

        for i in 0..<n {
            aBody[0] = sensors[i].accX * mgToMs2
            aBody[1] = sensors[i].accY * mgToMs2
            aBody[2] = sensors[i].accZ * mgToMs2

            let aWorld = rotateBodyToWorld(quats[i], aBody)
            let aUp = aWorld[2] - gravityMs2

            let posPred = pos + vel * dt + 0.5 * aUp * dt * dt
            let velPred = vel + aUp * dt
            let r = baroHeight[i] - posPred
            pos = posPred + alpha * r
            vel = velPred + (beta / dt) * r
            out[i] = pos
        }
        return out
    }

    /// Rotate a body-frame vector into the world frame using a Madgwick
    /// quaternion [w, x, y, z]. Standard q·v·q⁻¹ identity, written out.
    static func rotateBodyToWorld(_ q: [Double], _ v: [Double]) -> [Double] {
        precondition(q.count == 4 && v.count == 3)
        let qw = q[0], qx = q[1], qy = q[2], qz = q[3]
        let t0 = 2.0 * (qy * v[2] - qz * v[1])
        let t1 = 2.0 * (qz * v[0] - qx * v[2])
        let t2 = 2.0 * (qx * v[1] - qy * v[0])
        return [
            v[0] + qw * t0 + (qy * t2 - qz * t1),
            v[1] + qw * t1 + (qz * t0 - qx * t2),
            v[2] + qw * t2 + (qx * t1 - qy * t0),
        ]
    }
}
