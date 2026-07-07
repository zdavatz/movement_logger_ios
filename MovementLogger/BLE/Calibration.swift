import Foundation

/// Box-persisted board-orientation calibration blob (firmware v0.0.37+).
///
/// Wire format + semantics: firmware `DESIGN.md` →
/// *Box-persisted calibration (`CAL_GET` / `CAL_SET`)*. Mirror of the desktop
/// reference in `stbox-viz-gui/src/calibration.rs` and Kotlin/Android port
/// so a "Zero here" / nosePlusY / heading-bias set on ANY host survives on
/// the next connect from a different one.
///
/// Two responsibilities:
/// - `decode(blob)` — parse a 32-byte `CAL_GET` reply into per-field
///   `Optional`s. `nil` on any field means "the box has NOT set this yet
///   (valid_mask bit clear)" — the host should fall back to its local
///   `AgentConfig` / defaults.
/// - `encode(input)` — build a 32-byte payload for `CAL_SET`. Only fields
///   passed as `.some(_)` have their `valid_mask` bit set; the box's merge
///   leaves unset fields alone so a host can push a single new value
///   without knowing the box's current others.
enum Calibration {

    static let blobSize: Int = 32
    static let layoutVersion: UInt8 = 0x01

    static let maskNosePlusY:   UInt8 = 0x01
    static let maskMagOffset:   UInt8 = 0x02
    static let maskAngleZero:   UInt8 = 0x04
    static let maskHeadingBias: UInt8 = 0x08

    /// The decoded calibration as the app models it. `nil` per field means
    /// "box didn't have this yet" — the local `AgentConfig` value stands.
    struct Decoded: Equatable {
        var nosePlusY: Bool? = nil
        /// Hard-iron offset in mG per axis (X, Y, Z).
        var magOffsetMg: [Double]? = nil
        /// [pitch, roll, yaw] in degrees.
        var angleZeroRef: [Double]? = nil
        /// Unix epoch ms when "Zero here" was captured; `nil` if never zeroed.
        /// Distinct from `angleZeroRef` being `nil` (which means the whole
        /// zero-tare bit is clear) — this one is `nil` when the bit IS set
        /// but the box has no wall-clock stamp yet.
        var angleZeroAtEpochMs: Int64? = nil
        var headingBiasDeg: Double? = nil
    }

    /// Fields to include in a `CAL_SET` write. Any `.some(_)` sets its
    /// valid_mask bit; the box's merge overwrites just those fields.
    struct EncodeInput {
        var nosePlusY: Bool? = nil
        var magOffsetMg: [Double]? = nil
        /// Pair the ref with the epoch — a `.some(ref)` implies "the zero-tare
        /// bit is being set" so the epoch (defaults to 0 if not passed)
        /// travels alongside in the same 8-byte slot.
        var angleZeroRef: [Double]? = nil
        var angleZeroAtEpochMs: Int64? = nil
        var headingBiasDeg: Double? = nil
    }

    /// Encode a partial-update CAL_SET payload. Returns exactly `blobSize`
    /// bytes (any field passed as `nil` is zero-filled AND its valid_mask
    /// bit is cleared, so the box's merge leaves that field untouched).
    static func encode(_ input: EncodeInput) -> Data {
        var b = [UInt8](repeating: 0, count: blobSize)
        b[0] = layoutVersion
        var mask: UInt8 = 0

        if let pos = input.nosePlusY {
            mask |= maskNosePlusY
            b[2] = pos ? 1 : 0
        }
        if let mo = input.magOffsetMg, mo.count == 3 {
            mask |= maskMagOffset
            for i in 0..<3 {
                let vi = clampI16(mo[i])
                let off = 4 + i * 2
                let u = UInt16(bitPattern: vi)
                b[off]     = UInt8(u & 0xFF)
                b[off + 1] = UInt8((u >> 8) & 0xFF)
            }
        }
        if let zr = input.angleZeroRef, zr.count == 3 {
            mask |= maskAngleZero
            for i in 0..<3 {
                // Tenths of a degree: ±3276.7° range, plenty.
                let vi = clampI16(zr[i] * 10.0)
                let off = 10 + i * 2
                let u = UInt16(bitPattern: vi)
                b[off]     = UInt8(u & 0xFF)
                b[off + 1] = UInt8((u >> 8) & 0xFF)
            }
            // Epoch travels in the same "zero-tare" bit. Missing epoch → 0
            // (the layout's own "never zeroed" sentinel), which is
            // deliberately DIFFERENT from "there IS an epoch = 0".
            let epoch = input.angleZeroAtEpochMs ?? 0
            let e = UInt64(bitPattern: epoch)
            for i in 0..<8 {
                b[16 + i] = UInt8((e >> (8 * UInt64(i))) & 0xFF)
            }
        }
        if let bd = input.headingBiasDeg {
            mask |= maskHeadingBias
            let vi = clampI16(bd * 10.0)
            let u = UInt16(bitPattern: vi)
            b[24] = UInt8(u & 0xFF)
            b[25] = UInt8((u >> 8) & 0xFF)
        }

        b[1] = mask
        return Data(b)
    }

    /// Decode a 32-byte `CAL_GET` reply. Fields whose valid_mask bit is
    /// clear come back as `nil` — caller falls back to its own local
    /// `AgentConfig`. Returns `nil` on the two malformed cases (short blob
    /// or unknown layout version) — legacy firmware doesn't reply at all,
    /// so we don't see stale layouts here.
    static func decode(_ blob: Data) -> Decoded? {
        guard blob.count == blobSize else { return nil }
        let b = [UInt8](blob)
        guard b[0] == layoutVersion else { return nil }
        let mask = b[1]
        var d = Decoded()

        if mask & maskNosePlusY != 0 {
            d.nosePlusY = b[2] != 0
        }
        if mask & maskMagOffset != 0 {
            var a = [Double](repeating: 0, count: 3)
            for i in 0..<3 {
                let off = 4 + i * 2
                let v = Int16(bitPattern: UInt16(b[off]) | (UInt16(b[off + 1]) << 8))
                a[i] = Double(v)
            }
            d.magOffsetMg = a
        }
        if mask & maskAngleZero != 0 {
            var a = [Double](repeating: 0, count: 3)
            for i in 0..<3 {
                let off = 10 + i * 2
                let v = Int16(bitPattern: UInt16(b[off]) | (UInt16(b[off + 1]) << 8))
                a[i] = Double(v) / 10.0    // tenths → degrees
            }
            d.angleZeroRef = a
            var e: UInt64 = 0
            for i in 0..<8 {
                e |= UInt64(b[16 + i]) << (8 * UInt64(i))
            }
            // 0 = "the zero-tare bit is set but the box has no wall-clock
            // stamp yet" — treat as `nil` so the UI can decide whether to
            // display a "zeroed just now" note or omit it.
            d.angleZeroAtEpochMs = (e == 0) ? nil : Int64(bitPattern: e)
        }
        if mask & maskHeadingBias != 0 {
            let v = Int16(bitPattern: UInt16(b[24]) | (UInt16(b[25]) << 8))
            d.headingBiasDeg = Double(v) / 10.0
        }
        return d
    }

    private static func clampI16(_ x: Double) -> Int16 {
        let r = x.rounded()
        if r >= Double(Int16.max) { return Int16.max }
        if r <= Double(Int16.min) { return Int16.min }
        return Int16(r)
    }
}
