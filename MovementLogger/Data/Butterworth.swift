import Foundation

/// Butterworth low-pass filter + zero-phase `filtfilt` — Swift port of
/// `Butterworth.kt` / `butter.rs`. scipy.signal.butter + filtfilt for the
/// board animation's 2 Hz smoothing step. 4th-order design in the analog
/// s-plane via pole placement, bilinear-transformed to z-plane, then
/// direct-form I IIR.
///
/// `filtfilt` runs the filter forward then backward (reversed input) to
/// cancel the phase response — amplitude response squares so effective
/// order = 2N, output timing matches input.
enum Butterworth {

    struct Coeffs {
        let b: [Double]
        let a: [Double]
    }

    /// Design a 4th-order Butterworth low-pass filter normalised to
    /// `cutoffHz` at sampling rate `fsHz`. Returns 5-tap b and a.
    static func butter4Lowpass(cutoffHz: Double, fsHz: Double) -> Coeffs {
        let n = 4
        // Pre-warp cutoff for the bilinear transform
        let wd = 2.0 * .pi * cutoffHz
        let wa = 2.0 * tan(wd / (2.0 * fsHz)) * fsHz

        // Butterworth analog prototype poles on the left half of the unit
        // circle: p_k = exp(j·π·(2k + N + 1)/(2N)) for k in 0..N-1, scaled by wa.
        var polesReal = [Double](repeating: 0, count: n)
        var polesImag = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let theta = .pi * Double(2 * k + n + 1) / (2.0 * Double(n))
            polesReal[k] = wa * cos(theta)
            polesImag[k] = wa * sin(theta)
        }

        // Bilinear transform: z = (2·fs + s) / (2·fs − s)
        var zPolesR = [Double](repeating: 0, count: n)
        var zPolesI = [Double](repeating: 0, count: n)
        let k2 = 2.0 * fsHz
        for k in 0..<n {
            let pr = polesReal[k]
            let pi = polesImag[k]
            let numR = k2 + pr
            let numI = pi
            let denR = k2 - pr
            let denI = -pi
            let denom = denR * denR + denI * denI
            zPolesR[k] = (numR * denR + numI * denI) / denom
            zPolesI[k] = (numI * denR - numR * denI) / denom
        }

        // Denominator = prod(1 − z_pole·z⁻¹) via complex polynomial multiply.
        var polyR: [Double] = [1.0]
        var polyI: [Double] = [0.0]
        for k in 0..<n {
            var nextR = [Double](repeating: 0, count: polyR.count + 1)
            var nextI = [Double](repeating: 0, count: polyR.count + 1)
            for i in 0..<polyR.count {
                let r = polyR[i]
                let im = polyI[i]
                nextR[i] += r
                nextI[i] += im
                let pr = zPolesR[k]
                let pi = zPolesI[k]
                nextR[i + 1] += -pr * r + pi * im
                nextI[i + 1] += -pr * im - pi * r
            }
            polyR = nextR
            polyI = nextI
        }
        // a is purely real (pole pairs are conjugate). Take real part.
        var a = [Double](repeating: 0, count: 5)
        for i in 0..<5 { a[i] = polyR[i] }

        // Numerator (1 + z⁻¹)^4 binomial coefficients
        var b: [Double] = [1.0, 4.0, 6.0, 4.0, 1.0]

        // Normalise gain to unity at DC: scale b so sum(b)/sum(a) = 1.
        let sumB = b.reduce(0, +)
        let sumA = a.reduce(0, +)
        let gain = sumA / sumB
        for i in 0..<b.count { b[i] *= gain }

        return Coeffs(b: b, a: a)
    }

    /// Direct-form I IIR. `y[n] = (Σ b[k]·x[n-k] − Σ a[k]·y[n-k]) / a[0]`.
    static func lfilter(_ c: Coeffs, _ x: [Double]) -> [Double] {
        let n = x.count
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0
            for k in 0..<5 where i >= k { acc += c.b[k] * x[i - k] }
            for k in 1..<5 where i >= k { acc -= c.a[k] * y[i - k] }
            y[i] = acc / c.a[0]
        }
        return y
    }

    /// Zero-phase: forward-then-backward pass.
    static func filtfilt(_ c: Coeffs, _ x: [Double]) -> [Double] {
        let forward = lfilter(c, x)
        let reversed = Array(forward.reversed())
        let backward = lfilter(c, reversed)
        return Array(backward.reversed())
    }
}
