import Foundation
import Observation

// =============================================================================
//  u-blox UBX survey over the BLE box-bridge (the "GPS Debug" feature).
//
//  Port of the desktop `gps-debug` survey (movement_logger_desktop
//  `gps-debug/src/survey.rs`) to Swift. The receiver is bridged over BLE:
//  the box relays raw UBX frames both ways (firmware opcodes 0x0D GPS_BRIDGE
//  / 0x0E GPS_TX, v0.0.17+). Once a second we send a set of zero-length UBX
//  poll requests (NAV-PVT / NAV-DOP / NAV-SAT / NAV-SIG / MON-RF); the replies
//  arrive as bridged FileData notifies, are reassembled by `UbxParser`, and
//  written to two CSVs matching the desktop schema exactly so the same tools
//  parse them.
//
//  Non-destructive: we only ever *poll* (empty-payload requests). The box's
//  firmware flips the receiver's UBX output on in the RAM layer only for the
//  duration of the bridge, so nothing is persisted on the module.
// =============================================================================

// MARK: - UBX wire helpers

enum Ubx {
    // (class, id) of the messages we poll.
    static let navPvt: (UInt8, UInt8) = (0x01, 0x07)
    static let navDop: (UInt8, UInt8) = (0x01, 0x04)
    static let navSat: (UInt8, UInt8) = (0x01, 0x35)
    static let navSig: (UInt8, UInt8) = (0x01, 0x43)
    static let monRf:  (UInt8, UInt8) = (0x0A, 0x38)

    static let polls: [(UInt8, UInt8)] = [navPvt, navDop, navSat, navSig, monRf]

    /// 8-bit Fletcher checksum over class..payload-end (UBX spec).
    static func checksum(_ body: [UInt8]) -> (UInt8, UInt8) {
        var a: UInt8 = 0, b: UInt8 = 0
        for x in body { a = a &+ x; b = b &+ a }
        return (a, b)
    }

    /// Build a poll request: target class/id with an empty payload. Asks the
    /// receiver to emit the current value once, regardless of its rate.
    static func pollFrame(_ m: (UInt8, UInt8)) -> Data {
        let body: [UInt8] = [m.0, m.1, 0x00, 0x00]
        let (a, b) = checksum(body)
        return Data([0xB5, 0x62, m.0, m.1, 0x00, 0x00, a, b])
    }
}

/// Incremental UBX frame extractor. Feed it raw bytes (across multiple BLE
/// notifies); it yields decoded `(class, id, payload)` frames as their
/// checksums verify. Non-UBX bytes (NMEA, noise) are skipped by the sync hunt.
struct UbxParser {
    private var state = 0
    private var cls: UInt8 = 0, id: UInt8 = 0
    private var len = 0
    private var payload: [UInt8] = []
    private var ckA: UInt8 = 0, ckB: UInt8 = 0

    mutating func feed(_ data: Data, into out: inout [(UInt8, UInt8, [UInt8])]) {
        for byte in data { push(byte, &out) }
    }

    private mutating func push(_ byte: UInt8, _ out: inout [(UInt8, UInt8, [UInt8])]) {
        switch state {
        case 0: if byte == 0xB5 { state = 1 }
        // Saw 0xB5. 0x62 completes the sync word; a repeated 0xB5 keeps us
        // armed (previous byte was a false sync); anything else resets.
        case 1: state = (byte == 0x62) ? 2 : (byte == 0xB5 ? 1 : 0)
        case 2: cls = byte; state = 3
        case 3: id = byte; state = 4
        case 4: len = Int(byte); state = 5
        case 5:
            len |= Int(byte) << 8
            payload.removeAll(keepingCapacity: true)
            if len > 4096 { state = 0 }            // guard a corrupt length
            else if len == 0 { state = 7 }
            else { state = 6 }
        case 6:
            payload.append(byte)
            if payload.count >= len { state = 7 }
        case 7: ckA = byte; state = 8
        case 8:
            ckB = byte
            var body: [UInt8] = [cls, id, UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)]
            body.append(contentsOf: payload)
            let (a, b) = Ubx.checksum(body)
            if a == ckA && b == ckB { out.append((cls, id, payload)) }
            state = 0
        default: state = 0
        }
    }
}

// MARK: - little-endian field readers

private func u16le(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
private func u32le(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}
private func i16le(_ b: [UInt8], _ o: Int) -> Int16 {
    Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o + 1]) << 8))
}
private func i32le(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: u32le(b, o)) }

// MARK: - decoded structures

struct NavPvt {
    var itow: UInt32 = 0
    var year = 0, month = 0, day = 0, hour = 0, min = 0, sec = 0, valid = 0
    var fixType = 0, gnssFixOk = false, numSv = 0
    var lonDeg = 0.0, latDeg = 0.0, heightM = 0.0, hmslM = 0.0
    var haccM = 0.0, vaccM = 0.0, saccMps = 0.0, pdop = 0.0
}
struct NavDop { var hdop = 0.0, vdop = 0.0 }
struct SatInfo { var gnss = 0, sv = 0, cno = 0, elev = 0, azim = 0; var prResM = 0.0; var qual = 0; var svUsed = false }
struct SigInfo { var gnss = 0, sv = 0, sig = 0, cno = 0; var prResM = 0.0; var qual = 0; var prUsed = false }
struct MonRf { var antStatus = 0, antPower = 0, noisePerMs = 0, agcCnt = 0, jamInd = 0, jammingState = 0 }

private func parseNavPvt(_ p: [UInt8]) -> NavPvt? {
    guard p.count >= 78 else { return nil }
    var v = NavPvt()
    v.itow = u32le(p, 0)
    v.year = u16le(p, 4); v.month = Int(p[6]); v.day = Int(p[7])
    v.hour = Int(p[8]); v.min = Int(p[9]); v.sec = Int(p[10]); v.valid = Int(p[11])
    v.fixType = Int(p[20]); v.gnssFixOk = (p[21] & 0x01) != 0; v.numSv = Int(p[23])
    v.lonDeg = Double(i32le(p, 24)) * 1e-7
    v.latDeg = Double(i32le(p, 28)) * 1e-7
    v.heightM = Double(i32le(p, 32)) / 1000.0
    v.hmslM = Double(i32le(p, 36)) / 1000.0
    v.haccM = Double(u32le(p, 40)) / 1000.0
    v.vaccM = Double(u32le(p, 44)) / 1000.0
    v.saccMps = Double(u32le(p, 68)) / 1000.0
    v.pdop = Double(u16le(p, 76)) * 0.01
    return v
}

private func parseNavDop(_ p: [UInt8]) -> NavDop? {
    guard p.count >= 18 else { return nil }
    return NavDop(hdop: Double(u16le(p, 12)) * 0.01, vdop: Double(u16le(p, 10)) * 0.01)
}

private func parseNavSat(_ p: [UInt8]) -> [SatInfo] {
    var v: [SatInfo] = []
    guard p.count >= 8 else { return v }
    let n = Int(p[5])
    for i in 0..<n {
        let o = 8 + i * 12
        if o + 12 > p.count { break }
        let flags = u32le(p, o + 8)
        v.append(SatInfo(gnss: Int(p[o]), sv: Int(p[o + 1]), cno: Int(p[o + 2]),
                         elev: Int(Int8(bitPattern: p[o + 3])),
                         azim: Int(i16le(p, o + 4)), prResM: Double(i16le(p, o + 6)) * 0.1,
                         qual: Int(flags & 0x07), svUsed: (flags & 0x08) != 0))
    }
    return v
}

private func parseNavSig(_ p: [UInt8]) -> [SigInfo] {
    var v: [SigInfo] = []
    guard p.count >= 8 else { return v }
    let n = Int(p[5])
    for i in 0..<n {
        let o = 8 + i * 16
        if o + 16 > p.count { break }
        let sigFlags = u16le(p, o + 10)
        v.append(SigInfo(gnss: Int(p[o]), sv: Int(p[o + 1]), sig: Int(p[o + 2]), cno: Int(p[o + 6]),
                         prResM: Double(i16le(p, o + 4)) * 0.1, qual: Int(p[o + 7]),
                         prUsed: (sigFlags & 0x08) != 0))
    }
    return v
}

private func parseMonRf(_ p: [UInt8]) -> MonRf? {
    guard p.count >= 4 else { return nil }
    let n = Int(p[1])
    guard n > 0, p.count >= 4 + 24 else { return nil }
    let o = 4   // first RF block (single-band MAX-M10S has one: L1)
    return MonRf(antStatus: Int(p[o + 2]), antPower: Int(p[o + 3]),
                 noisePerMs: u16le(p, o + 12), agcCnt: u16le(p, o + 14),
                 jamInd: Int(p[o + 16]), jammingState: Int(p[o + 1] & 0x03))
}

// MARK: - enum → text decoders (match the desktop CSV strings)

private func gnssName(_ id: Int) -> String {
    switch id { case 0: return "GPS"; case 1: return "SBAS"; case 2: return "Galileo"
    case 3: return "BeiDou"; case 4: return "IMES"; case 5: return "QZSS"
    case 6: return "GLONASS"; case 7: return "NavIC"; default: return "?" }
}
private func sigName(_ gnss: Int, _ sig: Int) -> String {
    switch (gnss, sig) {
    case (0, 0): return "L1C/A"; case (0, 3): return "L2CL"; case (0, 4): return "L2CM"
    case (1, 0): return "L1C/A"
    case (2, 0): return "E1C"; case (2, 1): return "E1B"; case (2, 5): return "E5bI"; case (2, 6): return "E5bQ"
    case (3, 0): return "B1ID1"; case (3, 1): return "B1ID2"; case (3, 2): return "B2ID1"; case (3, 3): return "B2ID2"
    case (5, 0): return "L1C/A"; case (5, 1): return "L1S"; case (5, 4): return "L2CM"; case (5, 5): return "L2CL"
    case (6, 0): return "L1OF"; case (6, 2): return "L2OF"
    case (7, 0): return "L5A"
    default: return "sig?" }
}
private func antStatusName(_ s: Int) -> String {
    switch s { case 0: return "INIT"; case 1: return "UNKNOWN"; case 2: return "OK"
    case 3: return "SHORT"; case 4: return "OPEN"; default: return "?" }
}
private func antPowerName(_ s: Int) -> String {
    switch s { case 0: return "OFF"; case 1: return "ON"; case 2: return "UNKNOWN"; default: return "?" }
}
private func jammingName(_ s: Int) -> String {
    switch s { case 0: return "unknown"; case 1: return "ok"; case 2: return "warning"
    case 3: return "critical"; default: return "?" }
}

// MARK: - one polled epoch

private struct Epoch {
    var pvt: NavPvt?
    var dop: NavDop?
    var sats: [SatInfo] = []
    var sigs: [SigInfo] = []
    var rf: MonRf?
}

// MARK: - survey engine / view state

/// Drives the once-a-second UBX poll/collect loop over the BLE bridge and
/// exposes observable state for `GpsDebugScreen`. Owned by `FileSyncViewModel`
/// (which wires `onSendBridge`/`onSendPoll` to its single `BleClient` and
/// forwards every `.ubxFrame` into `feed(_:)`).
/// Not `@MainActor`-isolated, but in practice single-threaded on the main run
/// loop: `feed(_:)` is called from `FileSyncViewModel.onEvent` (@MainActor),
/// `start`/`stop` from main-thread UI actions, and the poll `Timer` is added to
/// `RunLoop.main`, so its `tick()` also fires on main. No cross-thread mutation.
@Observable
final class GpsDebugModel {
    /// Antenna/position label — goes into both CSV filenames and a column so
    /// several runs can be A/B compared and concatenated later.
    var label: String = "antenna"
    private(set) var running = false
    private(set) var epochCount = 0
    /// Rolling one-line live summaries (newest last), capped.
    private(set) var log: [String] = []
    private(set) var epochCsvPath: String?
    private(set) var signalsCsvPath: String?

    /// Set by `FileSyncViewModel`: toggle the box bridge (0x0D) and forward a
    /// UBX poll frame (0x0E). Kept as closures so this stays decoupled from the
    /// private `BleClient`.
    var onSendBridge: ((Bool) -> Void)?
    var onSendPoll: ((Data) -> Void)?
    /// Notified whenever `running` flips, so the VM can gate keep-synced etc.
    var onRunningChanged: ((Bool) -> Void)?

    private var parser = UbxParser()
    private var cur = Epoch()
    private var timer: Timer?
    private var epochHandle: FileHandle?
    private var sigHandle: FileHandle?

    private static let maxLogLines = 200
    private static let epochHeader = "label,host_iso,iTOW_ms,utc_date,utc_time,timeValid,fixType,gnssFixOK,numSV_used,lat_deg,lon_deg,height_m,hMSL_m,hAcc_m,vAcc_m,sAcc_mps,pDOP,hDOP,vDOP,antStatus,antPower,noisePerMS,agcCnt,cwSuppression_jamInd,jammingState\n"
    private static let sigHeader = "label,host_iso,iTOW_ms,gnssId,gnss,svId,sigId,sig,cno_dbhz,elev_deg,azim_deg,qualityInd,svUsed,prUsed,prRes_m\n"

    private let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    // MARK: control

    /// Start a survey: open the two CSVs, turn the bridge on, and begin the
    /// 1 Hz poll loop. Caller (`FileSyncViewModel`) has already verified the
    /// link is connected and idle.
    func start() {
        guard !running else { return }
        let safe = sanitize(label)
        epochCount = 0
        log.removeAll()
        cur = Epoch()
        parser = UbxParser()
        openCsvs(safeLabel: safe)
        appendLog("BLE GPS survey — polling the u-blox over the box · label \(safe)")
        if let p = epochCsvPath { appendLog("epoch  -> \(p)") }
        if let p = signalsCsvPath { appendLog("signals-> \(p)") }
        running = true
        onRunningChanged?(true)
        onSendBridge?(true)
        sendPolls()   // prime the first collection window
        // Added to RunLoop.main → the block fires on the main thread.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop the survey: turn the bridge off, flush the last epoch, close files.
    func stop() {
        guard running else { return }
        timer?.invalidate(); timer = nil
        onSendBridge?(false)
        flushEpoch()                 // write whatever we collected in the last window
        appendLog("stopped after \(epochCount) epoch(s).")
        try? epochHandle?.close(); epochHandle = nil
        try? sigHandle?.close(); sigHandle = nil
        running = false
        onRunningChanged?(false)
    }

    /// Feed raw bridged UBX bytes (one FileData notify) into the parser and
    /// fold any complete frames into the current epoch.
    func feed(_ data: Data) {
        guard running else { return }
        var frames: [(UInt8, UInt8, [UInt8])] = []
        parser.feed(data, into: &frames)
        for (cls, id, pl) in frames {
            // Literal (class, id) patterns — tuples aren't Equatable so we can't
            // match against the `Ubx.nav*` constants directly.
            switch (cls, id) {
            case (0x01, 0x07): cur.pvt = parseNavPvt(pl)
            case (0x01, 0x04): cur.dop = parseNavDop(pl)
            case (0x01, 0x35): cur.sats = parseNavSat(pl)
            case (0x01, 0x43): cur.sigs = parseNavSig(pl)
            case (0x0A, 0x38): cur.rf  = parseMonRf(pl)
            default: break
            }
        }
    }

    // MARK: internals

    private func tick() {
        guard running else { return }
        // A poll set was sent one interval ago; write whatever landed in this
        // collection window (may be a "no NAV-PVT reply" line while the box is
        // still enabling UBX — same as the desktop survey), then re-poll.
        flushEpoch()
        cur = Epoch()
        sendPolls()
    }

    private func sendPolls() {
        for m in Ubx.polls { onSendPoll?(Ubx.pollFrame(m)) }
    }

    private func flushEpoch() {
        let host = isoFmt.string(from: Date())
        writeEpochRow(host: host)
        appendLog(liveSummary())
        epochCount += 1
    }

    private func writeEpochRow(host: String) {
        let itow = cur.pvt?.itow ?? 0
        if let pvt = cur.pvt {
            let dop = cur.dop ?? NavDop()
            let rf = cur.rf ?? MonRf()
            let date = String(format: "%04d-%02d-%02d", pvt.year, pvt.month, pvt.day)
            let time = String(format: "%02d:%02d:%02d", pvt.hour, pvt.min, pvt.sec)
            let row = "\(label),\(host),\(itow),\(date),\(time),0x\(String(format: "%02X", pvt.valid)),"
                + "\(pvt.fixType),\(pvt.gnssFixOk ? 1 : 0),\(pvt.numSv),"
                + String(format: "%.7f,%.7f,%.3f,%.3f,%.3f,%.3f,%.3f,",
                         pvt.latDeg, pvt.lonDeg, pvt.heightM, pvt.hmslM, pvt.haccM, pvt.vaccM, pvt.saccMps)
                + String(format: "%.2f,%.2f,%.2f,", pvt.pdop, dop.hdop, dop.vdop)
                + "\(antStatusName(rf.antStatus)),\(antPowerName(rf.antPower)),"
                + "\(rf.noisePerMs),\(rf.agcCnt),\(rf.jamInd),\(jammingName(rf.jammingState))\n"
            write(row, to: epochHandle)
        }

        // Per-signal rows: NAV-SIG is the per-signal truth; elev/azim/svUsed
        // come from the matching NAV-SAT satellite. Fall back to per-satellite
        // rows if the receiver answered NAV-SAT but not NAV-SIG.
        if !cur.sigs.isEmpty {
            for s in cur.sigs {
                let sat = cur.sats.first { $0.gnss == s.gnss && $0.sv == s.sv }
                let elev = sat.map { String($0.elev) } ?? ""
                let azim = sat.map { String($0.azim) } ?? ""
                let svUsed = (sat?.svUsed ?? false) ? 1 : 0
                let row = "\(label),\(host),\(itow),\(s.gnss),\(gnssName(s.gnss)),\(s.sv),\(s.sig),"
                    + "\(sigName(s.gnss, s.sig)),\(s.cno),\(elev),\(azim),\(s.qual),\(svUsed),"
                    + "\(s.prUsed ? 1 : 0),\(String(format: "%.1f", s.prResM))\n"
                write(row, to: sigHandle)
            }
        } else {
            for a in cur.sats {
                let row = "\(label),\(host),\(itow),\(a.gnss),\(gnssName(a.gnss)),\(a.sv),,,"
                    + "\(a.cno),\(a.elev),\(a.azim),\(a.qual),\(a.svUsed ? 1 : 0),,"
                    + "\(String(format: "%.1f", a.prResM))\n"
                write(row, to: sigHandle)
            }
        }
    }

    private func liveSummary() -> String {
        guard let p = cur.pvt else {
            return "(no NAV-PVT reply — receiver may be NMEA-only, or the box firmware lacks the GPS bridge)"
        }
        let maxCno = max(cur.sigs.map { $0.cno }.max() ?? 0, cur.sats.map { $0.cno }.max() ?? 0)
        let used = max(cur.sigs.filter { $0.prUsed }.count, cur.sats.filter { $0.svUsed }.count)
        let rf = cur.rf
        let astat = rf.map { antStatusName($0.antStatus) } ?? "?"
        let apow = rf.map { antPowerName($0.antPower) } ?? "?"
        let jam = rf.map { jammingName($0.jammingState) } ?? "?"
        return String(format: "%02d:%02d:%02d fix=%d ok=%d sv=%2d used=%2d maxCN0=%2d hAcc=%.1fm pDOP=%.1f | ant=%@/%@ jam=%@",
                      p.hour, p.min, p.sec, p.fixType, p.gnssFixOk ? 1 : 0,
                      p.numSv, used, maxCno, p.haccM, p.pdop, astat, apow, jam)
    }

    // MARK: CSV files

    private func openCsvs(safeLabel: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let epochURL = docs.appendingPathComponent("\(safeLabel)_gnss_epoch.csv")
        let sigURL = docs.appendingPathComponent("\(safeLabel)_gnss_signals.csv")
        try? Self.epochHeader.data(using: .utf8)?.write(to: epochURL)
        try? Self.sigHeader.data(using: .utf8)?.write(to: sigURL)
        epochHandle = try? FileHandle(forWritingTo: epochURL)
        sigHandle = try? FileHandle(forWritingTo: sigURL)
        epochHandle?.seekToEndOfFile()
        sigHandle?.seekToEndOfFile()
        epochCsvPath = epochURL.path
        signalsCsvPath = sigURL.path
    }

    private func write(_ s: String, to handle: FileHandle?) {
        guard let handle, let d = s.data(using: .utf8) else { return }
        handle.write(d)
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    private func sanitize(_ s: String) -> String {
        let cleaned = String(s.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return cleaned.isEmpty ? "antenna" : cleaned
    }
}
