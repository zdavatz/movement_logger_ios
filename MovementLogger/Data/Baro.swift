import Foundation

/// Board height above water via GPS-anchored water reference + temperature
/// compensation — Swift port of `Baro.kt` / `baro.rs`.
///
/// Why we need this: a pure baro-to-height conversion would drift with the
/// semi-sealed enclosure's thermal expansion. We anchor "P at water level"
/// to the pressure recorded while the GPS reports near-zero speed
/// (stationary on the water before / between rides), then read height
/// deviations relative to that reference.
enum Baro {

    private static let kelvinOffset: Double = 273.15
    /// Hypsometric coefficient near sea level — `dh ≈ −8434 × dP/P`, ~1 % to 100 m.
    private static let hypsometricH: Double = 8434.0
    private static let stationaryThresholdKmh: Double = 3.0

    /// Compute height above water in metres, aligned 1:1 with `sensors`.
    /// Falls back to a session-max-pressure reference when GPS is empty or
    /// never stationary. `speedKmh` is expected to be the smoothed GPS
    /// speed aligned with `gps` row-for-row.
    static func heightAboveWaterM(
        sensors: [SensorRow],
        gps: [GpsRow],
        speedKmh: [Double],
        baseTicks: Double
    ) -> [Double] {
        let n = sensors.count
        guard n > 0 else { return [] }

        // Temperature compensation: P_tc = P × T_ref / T (Kelvin)
        var tk = [Double](repeating: 0, count: n)
        for i in 0..<n { tk[i] = sensors[i].temperatureC + kelvinOffset }
        var sortedTk = tk
        sortedTk.sort()
        let refK = sortedTk[sortedTk.count / 2]
        var pressTc = [Double](repeating: 0, count: n)
        for i in 0..<n { pressTc[i] = sensors[i].pressureMb * (refK / tk[i]) }

        if gps.isEmpty || speedKmh.isEmpty {
            return fallbackHeightFromSessionMax(pressTc)
        }

        var sensSec = [Double](repeating: 0, count: n)
        for i in 0..<n { sensSec[i] = (sensors[i].ticks - baseTicks) / GpsMath.ticksPerSec }
        var gpsSec = [Double](repeating: 0, count: gps.count)
        for i in 0..<gps.count { gpsSec[i] = (gps[i].ticks - baseTicks) / GpsMath.ticksPerSec }

        // Step 1: TC'd pressure interpolated onto the GPS time grid.
        let pressAtGps = interpLinear(xNew: gpsSec, x: sensSec, y: pressTc)

        // Step 2: anchors where the rider is stationary.
        var anchorTimes: [Double] = []
        var anchorPress: [Double] = []
        anchorTimes.reserveCapacity(speedKmh.count)
        anchorPress.reserveCapacity(speedKmh.count)
        for i in 0..<speedKmh.count {
            if speedKmh[i] < stationaryThresholdKmh {
                anchorTimes.append(gpsSec[i])
                anchorPress.append(pressAtGps[i])
            }
        }
        if anchorTimes.isEmpty {
            return fallbackHeightFromSessionMax(pressTc)
        }
        let waterRefGps = interpLinear(xNew: gpsSec, x: anchorTimes, y: anchorPress)

        // Step 3: water reference projected back onto the sensor timeline.
        let waterRefSens = interpLinear(xNew: sensSec, x: gpsSec, y: waterRefGps)

        // Step 4: height = 8434 × (1 − P_tc / P_ref)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = hypsometricH * (1.0 - pressTc[i] / waterRefSens[i])
        }
        return out
    }

    private static func fallbackHeightFromSessionMax(_ pressTc: [Double]) -> [Double] {
        var pmax = -Double.infinity
        for p in pressTc where p > pmax { pmax = p }
        var out = [Double](repeating: 0, count: pressTc.count)
        for i in 0..<pressTc.count { out[i] = hypsometricH * (1.0 - pressTc[i] / pmax) }
        return out
    }

    /// Linear interpolation of `y(x)` onto `xNew`. `x` must be ascending;
    /// out-of-range queries clamp to edges. O(n + m) two-pointer walk.
    static func interpLinear(xNew: [Double], x: [Double], y: [Double]) -> [Double] {
        precondition(x.count == y.count)
        var out = [Double](repeating: 0, count: xNew.count)
        if x.isEmpty { return out }
        if x.count == 1 {
            for i in 0..<xNew.count { out[i] = y[0] }
            return out
        }
        let last = x.count - 1
        var j = 0
        for i in 0..<xNew.count {
            let xn = xNew[i]
            if xn <= x[0] { out[i] = y[0]; continue }
            if xn >= x[last] { out[i] = y[last]; continue }
            while j + 1 < x.count && x[j + 1] < xn { j += 1 }
            let x0 = x[j], x1 = x[j + 1]
            let t = x1 > x0 ? (xn - x0) / (x1 - x0) : 0.0
            out[i] = y[j] + (y[j + 1] - y[j]) * t
        }
        return out
    }
}
