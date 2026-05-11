import Foundation

/// GPS post-processing — Swift port of `GpsMath.kt` / `gps.rs`.
///
/// The u-blox MAX-M10S Doppler-based `Speed [km/h]` column in `Gps*.csv`
/// is unreliable on this hardware (~0.1 km/h while position deltas
/// showed sustained 10-30 km/h flight). All consumers should use the
/// position-derived speed from `positionDerivedSpeedKmh`.
enum GpsMath {

    private static let earthRadiusM: Double = 6_371_000.0

    /// Box's ThreadX time base: 1 tick = 10 ms.
    static let ticksPerSec: Double = 100.0

    /// Default acceleration threshold for `rejectAccOutliers` (km/h per s).
    static let defaultMaxAccelKmhPerS: Double = 15.0

    static func haversineM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let lat1r = lat1 * .pi / 180.0
        let lat2r = lat2 * .pi / 180.0
        let dlat = (lat2 - lat1) * .pi / 180.0
        let dlon = (lon2 - lon1) * .pi / 180.0
        let s1 = sin(dlat / 2.0)
        let s2 = sin(dlon / 2.0)
        let a = s1 * s1 + cos(lat1r) * cos(lat2r) * s2 * s2
        return 2.0 * earthRadiusM * asin(sqrt(a))
    }

    /// Position-derived speed per row (km/h). The first row is 0.
    static func positionDerivedSpeedKmh(_ gps: [GpsRow]) -> [Double] {
        let n = gps.count
        var out = [Double](repeating: 0, count: n)
        guard n >= 2 else { return out }
        for i in 1..<n {
            let dist = haversineM(gps[i - 1].lat, gps[i - 1].lon, gps[i].lat, gps[i].lon)
            let dt = (gps[i].ticks - gps[i - 1].ticks) / ticksPerSec
            if dt > 0.05 {
                out[i] = (dist / dt) * 3.6
            }
        }
        return out
    }

    /// Reject unphysical jumps by comparing |Δspeed| against a maximum
    /// plausible longitudinal acceleration. Pumpfoil/SUPfoil paddle-starts
    /// produce ~1-3 m/s², so anything above ~4 m/s² (~15 km/h/s) is almost
    /// certainly a multipath-induced position jump. Keeps the previous valid
    /// sample as baseline so a glitch doesn't poison everything downstream.
    static func rejectAccOutliers(
        _ gps: [GpsRow],
        rawKmh: [Double],
        maxAccelKmhPerS: Double = defaultMaxAccelKmhPerS
    ) -> [Double] {
        let n = rawKmh.count
        var out = rawKmh
        guard n > 0 else { return out }
        var prevT = Double.nan
        var prevV = Double.nan
        for i in 0..<n {
            let t = gps[i].ticks / ticksPerSec
            let v = out[i]
            if !prevT.isNaN && !prevV.isNaN {
                let dt = max(t - prevT, 0.05)
                let accel = abs(v - prevV) / dt
                // Only flag high-speed jumps — going 0 → 10 km/h in 1 s is a
                // plausible paddle stroke (2.8 m/s²). 5 → 35 km/h in 1 s is not.
                if accel > maxAccelKmhPerS && v > 15.0 {
                    out[i] = .nan
                    continue
                }
            }
            prevT = t
            prevV = v
        }
        return out
    }

    /// Clip implausible glitches (>60 km/h on a pumpfoil is always a bad fix)
    /// + NaN holes, linearly interpolate, then 5-sample rolling median.
    static func smoothSpeedKmh(_ raw: [Double]) -> [Double] {
        var clipped = [Double](repeating: 0, count: raw.count)
        for i in 0..<raw.count {
            let v = raw[i]
            clipped[i] = (!v.isFinite || v > 60.0) ? .nan : v
        }
        linearInterpolateInPlace(&clipped)
        return rollingMedian(clipped, window: 5)
    }

    /// Fill `NaN` holes by linear interpolation between the surrounding
    /// finite samples. Leading/trailing NaN runs are filled with the
    /// nearest finite value; all-NaN input becomes all-zero.
    static func linearInterpolateInPlace(_ arr: inout [Double]) {
        let n = arr.count
        guard n > 0 else { return }
        var lastIdx = -1
        var lastVal = 0.0
        for i in 0..<n {
            if arr[i].isFinite {
                if lastIdx >= 0 && i - lastIdx > 1 {
                    let span = Double(i - lastIdx)
                    let v0 = lastVal
                    let v1 = arr[i]
                    for k in (lastIdx + 1)..<i {
                        let t = Double(k - lastIdx) / span
                        arr[k] = v0 + (v1 - v0) * t
                    }
                }
                lastIdx = i
                lastVal = arr[i]
            }
        }
        guard let firstIdx = (0..<n).first(where: { arr[$0].isFinite }) else {
            for i in 0..<n { arr[i] = 0 }
            return
        }
        let firstVal = arr[firstIdx]
        for i in 0..<firstIdx { arr[i] = firstVal }
        var lv = 0.0
        for i in 0..<n {
            if arr[i].isFinite { lv = arr[i] } else { arr[i] = lv }
        }
    }

    /// Centred rolling-median. Dispatches between a copy-and-sort impl for
    /// tiny windows and an incremental sorted-array impl for big windows
    /// (e.g. the 60 s × 100 Hz = 6000-sample baseline used by the fusion's
    /// nose-angle drift correction).
    ///
    /// Both impls pick `sorted[len/2]` so they agree on even-length windows.
    static func rollingMedian(_ x: [Double], window: Int) -> [Double] {
        let w = max(window, 1)
        return (x.count < 64 || w < 32)
            ? rollingMedianSimple(x, window: w)
            : rollingMedianFast(x, window: w)
    }

    static func rollingMedianSimple(_ x: [Double], window: Int) -> [Double] {
        let n = x.count
        let w = max(window, 1)
        let half = w / 2
        var out = [Double](repeating: 0, count: n)
        // Centred window at index i covers [i-half, i+half+1), so for even w
        // the range is `w + 1` wide — buffer one slot beyond `w` to handle it.
        var buf = [Double](repeating: 0, count: w + 1)
        for i in 0..<n {
            let lo = max(i - half, 0)
            let hi = min(i + half + 1, n)
            let len = hi - lo
            for k in 0..<len { buf[k] = x[lo + k] }
            buf[..<len].sort()
            out[i] = buf[len / 2]
        }
        return out
    }

    /// Incremental sorted-array rolling median. The window is kept sorted
    /// in a `[Double]`; insertions use binary-search + `insert(at:)` (O(w)
    /// per slide). For a 6000-sample window the inner shifts are ~48 KB
    /// memcpy each, which on Apple Silicon is sub-microsecond — practical
    /// for typical session sizes.
    static func rollingMedianFast(_ x: [Double], window: Int) -> [Double] {
        let n = x.count
        guard n > 0 else { return [] }
        let w = max(window, 1)
        let half = w / 2
        var out = [Double](repeating: 0, count: n)
        var sorted: [Double] = []
        sorted.reserveCapacity(w + 1)

        let initialHi = min(half + 1, n)
        for k in 0..<initialHi {
            sortedInsert(&sorted, x[k])
        }
        out[0] = sorted[sorted.count / 2]

        for i in 1..<n {
            let newR = i + half
            if newR < n {
                sortedInsert(&sorted, x[newR])
            }
            let oldL = i - half - 1
            if oldL >= 0 {
                sortedRemove(&sorted, x[oldL])
            }
            out[i] = sorted[sorted.count / 2]
        }
        return out
    }

    /// Binary-search insert into a sorted array.
    private static func sortedInsert(_ a: inout [Double], _ v: Double) {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        a.insert(v, at: lo)
    }

    /// Binary-search remove of (one occurrence of) value `v` from a sorted array.
    /// Precondition: `v` is present.
    private static func sortedRemove(_ a: inout [Double], _ v: Double) {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        a.remove(at: lo)
    }
}
