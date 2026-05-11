import Foundation

/// Quaternion → Euler conversion — Swift port of `EulerAngles.kt` / `euler.rs`.
/// Hamilton convention, ZYX order, quaternion layout [w, x, y, z].
///
/// Pitch is clamped to ±90° in the gimbal-lock region; callers shade those
/// zones rather than trust the sudden roll/yaw flips that the math produces
/// there.
enum EulerAngles {

    /// (roll°, pitch°, yaw°) for one quaternion.
    static func quatToEulerDeg(_ q: [Double]) -> (roll: Double, pitch: Double, yaw: Double) {
        precondition(q.count == 4)
        let qs = q[0], qi = q[1], qj = q[2], qk = q[3]

        let sinrCosp = 2.0 * (qs * qi + qj * qk)
        let cosrCosp = 1.0 - 2.0 * (qi * qi + qj * qj)
        let roll = atan2(sinrCosp, cosrCosp) * 180.0 / .pi

        let sinp = 2.0 * (qs * qj - qk * qi)
        let pitchRad: Double
        if abs(sinp) >= 1.0 {
            pitchRad = (sinp >= 0 ? 1.0 : -1.0) * .pi / 2.0
        } else {
            pitchRad = asin(sinp)
        }
        let pitch = pitchRad * 180.0 / .pi

        let sinyCosp = 2.0 * (qs * qk + qi * qj)
        let cosyCosp = 1.0 - 2.0 * (qj * qj + qk * qk)
        let yaw = atan2(sinyCosp, cosyCosp) * 180.0 / .pi

        return (roll, pitch, yaw)
    }

    /// Vectorised: returns parallel (roll[], pitch[], yaw[]) arrays.
    static func quatsToEulerDeg(_ quats: [[Double]]) -> (roll: [Double], pitch: [Double], yaw: [Double]) {
        let n = quats.count
        var roll = [Double](repeating: 0, count: n)
        var pitch = [Double](repeating: 0, count: n)
        var yaw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let r = quatToEulerDeg(quats[i])
            roll[i] = r.roll; pitch[i] = r.pitch; yaw[i] = r.yaw
        }
        return (roll, pitch, yaw)
    }

    /// Contiguous gimbal-lock regions (|pitch| > 85°) as half-open
    /// `[start, end)` index ranges. Callers use this to shade those zones
    /// red on Euler-angle plots.
    static func gimbalLockRegions(_ pitch: [Double]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var inRegion = false
        var start = 0
        for i in 0..<pitch.count {
            let gl = abs(pitch[i]) > 85.0
            if gl && !inRegion { start = i; inRegion = true }
            else if !gl && inRegion { out.append(start..<i); inRegion = false }
        }
        if inRegion { out.append(start..<pitch.count) }
        return out
    }
}
