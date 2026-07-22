import Foundation
import CoreBluetooth

/// Wire protocol for the PumpTsueri SensorTile.box's BLE FileSync service.
/// Authoritative spec lives in the firmware source (`Core/Src/ble_filesync.c`)
/// and the desktop Rust client (`stbox-viz-gui/src/ble.rs`).
enum FileSyncProtocol {
    /// Accepted advertise names. `PumpTsueri` is the legacy SDDataLogFileX
    /// firmware; `STBoxFs` is the PumpLogger firmware (Peter's PR #18) which
    /// adds the SensorStream characteristic. Match either so one build handles
    /// both during the firmware transition.
    static let boxNames: [String] = ["PumpTsueri", "STBoxFs"]

    static let fileCmdUUID: CBUUID = CBUUID(string: "00000080-0010-11e1-ac36-0002a5d5c51b")
    static let fileDataUUID: CBUUID = CBUUID(string: "00000040-0010-11e1-ac36-0002a5d5c51b")
    /// SensorStream — 0.5 Hz packed 46-byte all-sensor snapshot. Optional;
    /// only PumpLogger firmware exposes it. Subscribing is enough to start
    /// the stream; the box has no STREAM_START opcode.
    static let streamUUID: CBUUID = CBUUID(string: "00000100-0010-11e1-ac36-0002a5d5c51b")
    /// BatteryStatus — 8-byte fuel-gauge snapshot (voltage / SoC / current /
    /// flags) from the STC3115. Read + notify; box notifies ~once/min and
    /// immediately on a low-batt transition. Optional, same as SensorStream —
    /// legacy PumpTsueri firmware doesn't expose it, so absence is tolerated.
    static let batteryUUID: CBUUID = CBUUID(string: "00000200-0010-11e1-ac36-0002a5d5c51b")

    // Opcodes (first byte of FileCmd write).
    static let opList: UInt8 = 0x01
    static let opRead: UInt8 = 0x02
    static let opDelete: UInt8 = 0x03
    static let opStopLog: UInt8 = 0x04
    static let opStartLog: UInt8 = 0x05
    /// SET_MODE `<u8>`: 0 = auto, 1 = manual. Persisted on the box.
    static let opSetMode: UInt8 = 0x06
    /// GET_MODE: box replies one byte 0 = auto, 1 = manual.
    static let opGetMode: UInt8 = 0x07
    /// SET_TIME `<epoch_ms:u64-LE>`: push the phone's wall-clock millis so the
    /// box (which has no RTC) stamps a `# SYNC epoch_ms=… tick_ms=…` anchor
    /// into the open Sens/Gps CSVs, pairing the phone epoch with its
    /// free-running ms counter. Sent on every connect; lets replay resolve
    /// absolute wall-clock without a GPS fix. Box replies one status byte we
    /// don't track (legacy firmware without 0x08 just ignores the write).
    static let opSetTime: UInt8 = 0x08

    // --- Firmware-update opcodes (OTA over the same FileCmd/FileData chars) ---
    //
    // The box stages a new firmware image into the inactive flash bank, then
    // verifies + swaps + resets on COMMIT. Single-in-flight through the same
    // worker state machine as READ (concurrent ops get rejected with BUSY).
    /// FW_BEGIN `[image_len:u32-LE][sha256:32]` — erase the inactive bank and
    /// arm staging. Box replies one status byte (0x00 ready, else error).
    static let opFwBegin: UInt8 = 0x09
    /// FW_DATA `[offset:u32-LE][bytes…]` — write one chunk at `offset`. Box
    /// replies a 4-byte LE next-expected-offset ACK, or a 1-byte error.
    static let opFwData: UInt8 = 0x0A
    /// FW_COMMIT (no payload) — verify the staged SHA, swap banks, reset. Box
    /// replies 0xA0 (FW_READY) then drops the link, or a 1-byte error.
    static let opFwCommit: UInt8 = 0x0B
    /// FW_ABORT (no payload) — discard the staged image. Box replies 0x00.
    static let opFwAbort: UInt8 = 0x0C

    // --- GPS-bridge opcodes (u-blox UBX survey tunnelled over BLE) ------------
    //
    // The box relays raw u-blox UBX frames over the same FileCmd/FileData chars
    // so the GPS Debug survey can poll the receiver without a cable. Firmware
    // v0.0.17+ (`gps.c` GPS_BridgeSet / GPS_BridgeTx). Legacy firmware silently
    // ignores 0x0D → the survey simply shows "no NAV-PVT reply".
    /// GPS_BRIDGE `<u8>` 1 = on / 0 = off. While on, the box forwards raw UBX
    /// reply frames as FileData notifies; no FileData reply to the command
    /// itself. Fire-and-forget.
    static let opGpsBridge: UInt8 = 0x0D
    /// GPS_TX `[raw UBX bytes]` — forward the survey's UBX poll frames straight
    /// to the u-blox UART. Replies arrive as bridged FileData notifies.
    static let opUbxPoll: UInt8 = 0x0E

    /// GET_VERSION: box replies with ONE FileData notify carrying the ASCII
    /// firmware version string (e.g. `"0.0.29"`, no NUL terminator). Exact
    /// send/reply shape as GET_MODE (0x07). Firmware v0.0.29+; legacy firmware
    /// (≤ v0.0.28) doesn't implement 0x10 and sends no reply → the query times
    /// out (same bound as GET_MODE) and the box version reads as unknown, which
    /// the firmware-update check treats as "older than the latest release".
    static let opGetVersion: UInt8 = 0x10

    /// GPS_POWER `<u8>` 1 = on, 0 = off. Turns the box's u-blox receiver on or
    /// off to save battery when GPS is faulty/unused — off drops it into
    /// UBX-RXM-PMREQ backup (~tens of µA vs ~25 mA). Persisted on the box and
    /// re-applied at boot. Reply is one status byte, exactly like SET_MODE.
    /// Firmware v0.0.35+; legacy firmware ignores 0x11 → the op times out and
    /// the toggle stays at its last-known state.
    static let opGpsPower: UInt8 = 0x11
    /// GPS_GET_POWER: box replies one byte 1 = on, 0 = off. Twin of GET_MODE.
    static let opGpsGetPower: UInt8 = 0x12

    /// CAL_GET (firmware v0.0.37+). Fetch the box's persisted board-orientation
    /// calibration blob so a "Zero here" / nosePlusY / heading-bias set on any
    /// host survives on the next connect from a different one. Box replies with
    /// a single 32-byte FileData notify carrying the blob (layout in
    /// `Calibration.swift`). Legacy firmware silently ignores 0x13.
    static let opCalGet: UInt8 = 0x13
    /// CAL_SET `[32-byte blob]` (firmware v0.0.37+). Push a per-field-encoded
    /// blob (see `Calibration.encode`) — only fields whose `valid_mask` bit is
    /// set have their box-side value overwritten; the merge leaves everything
    /// else alone. Box replies one status byte (0x00 = OK). Legacy firmware
    /// silently ignores 0x14.
    static let opCalSet: UInt8 = 0x14

    // --- BT-off GPS A/B test (firmware v0.0.57+, issue #10) -------------------
    //
    // "Does the BLE radio degrade GPS reception?" BLE_QUIET arms a timed window
    // in which the box records ~3 s of BT-on pre-samples, disconnects, holds
    // its BLE chip in hardware reset (radio provably silent) for the requested
    // duration while sampling its GPS RF metrics at 1 Hz — also into the box
    // ERRLOG as `gps_rfq:` lines — then re-inits + re-advertises. The phone
    // auto-reconnects and fetches the recording; the BT-on vs BT-off C/N0
    // delta is the verdict.
    /// BLE_QUIET `[dur_s:u16-LE]` — arm the window (clamped 5–120 s on the
    /// box). Replies one status byte (0x00 armed / 0xB0 busy), then the box
    /// disconnects ~3 s later. Legacy firmware (< v0.0.57) never replies.
    static let opBleQuiet: UInt8 = 0x15
    /// BLE_QUIET_RESULT (no payload) — fetch the recorded window after the
    /// reconnect: one 8-byte header (`'Q'`, version, sample_size, count
    /// u16-LE, dur_s u16-LE, reserved), then `count` samples of `sample_size`
    /// bytes packed into MTU-sized notifies. 0xB0 while the window (incl. its
    /// ~5 s post phase) still runs.
    static let opBleQuietResult: UInt8 = 0x16

    // Status bytes returned in single-byte FileData notifies.
    static let statusOK: UInt8 = 0x00
    static let statusBusy: UInt8 = 0xB0
    static let statusNotFound: UInt8 = 0xE1
    static let statusIOError: UInt8 = 0xE2
    static let statusBadRequest: UInt8 = 0xE3

    // Firmware-update status bytes (in single-byte FW_* error notifies).
    /// FW_COMMIT success: image verified, box is swapping banks + resetting.
    static let fwReady: UInt8 = 0xA0
    /// FW_COMMIT: staged SHA-256 didn't match — image rejected, box stayed
    /// on the old firmware.
    static let fwHashMismatch: UInt8 = 0xE4
    /// FW_BEGIN bank-erase failed / FW_DATA / FW_COMMIT flash write failed.
    static let fwFlashFail: UInt8 = 0xE5
    /// FW_BEGIN: image is larger than the inactive bank can hold.
    static let fwTooBig: UInt8 = 0xE6
    /// FW_DATA: offset didn't match the box's cursor (bad sequence), or
    /// FW_COMMIT: fewer bytes staged than `image_len` (short image).
    static let fwBadSeq: UInt8 = 0xE7

    static func isStatusByte(_ b: UInt8) -> Bool {
        b == statusBusy || b == statusNotFound || b == statusIOError || b == statusBadRequest
    }

    static func statusMessage(_ b: UInt8) -> String {
        switch b {
        case statusBusy: return "BUSY (logging in progress, send STOP_LOG first)"
        case statusNotFound: return "NOT_FOUND"
        case statusIOError: return "IO_ERROR"
        case statusBadRequest: return "BAD_REQUEST"
        default: return "unknown error"
        }
    }

    /// Human-readable reason for a firmware-update error byte.
    static func fwErrorMessage(_ b: UInt8) -> String {
        switch b {
        case statusBusy:      return "box busy (logging or another op in progress)"
        case fwHashMismatch:  return "image rejected (hash mismatch)"
        case fwFlashFail:     return "flash write failed"
        case fwTooBig:        return "image too big for the box's firmware bank"
        case fwBadSeq:        return "bad sequence / short image"
        case statusBadRequest: return "bad request (malformed FW command)"
        default: return "unknown firmware error (0x\(String(format: "%02X", b)))"
        }
    }
}

enum BleCmd {
    case scan
    case connect(identifier: UUID)
    case disconnect
    case list
    /// `size` is the full file length from the prior LIST (EOF marker).
    /// `offset` is the byte position to resume/grow from (0 = whole
    /// file) — the firmware seeks there before streaming, so an
    /// interrupted or grown file continues instead of restarting.
    /// Wire: `0x02 + name + 0x00 + offset(u32-LE)` (firmware `ble.c`
    /// READ handler; port of desktop v0.0.11/#8).
    case read(name: String, size: Int64, offset: Int64)
    case stopLog
    case startLog(durationSeconds: Int)
    case delete(name: String)
    /// Persist the box log-mode (false = auto, true = manual).
    case setLogMode(manual: Bool)
    /// Query the box's current log-mode; reply arrives as `.logMode`.
    case getLogMode
    /// Query the box's firmware version (0x10). Reply arrives as
    /// `.firmwareVersion(String?)`; legacy firmware (≤ v0.0.28) never replies
    /// so the op times out and emits `.firmwareVersion(nil)` (unknown). Exact
    /// twin of `getLogMode` — a single-byte FileCmd whose one-notify reply is
    /// demuxed by the worker's `op` state machine.
    case getFirmwareVersion
    /// Push the phone's current wall-clock millis to the box so it stamps a
    /// time-sync anchor into the open Sens/Gps CSVs. Fire-and-forget — no
    /// tracked reply (so legacy firmware that ignores 0x08 never stalls us).
    case setTime(epochMs: Int64)
    /// Upload a firmware image to the box's inactive flash bank, then verify +
    /// swap + reset (OTA). `image` is the exact `.bin` bytes; `sha256` is its
    /// SHA-256 digest (32 bytes). Drives the FW_BEGIN → FW_DATA… → FW_COMMIT
    /// handshake through the single-op state machine; progress + result arrive
    /// as `.fwUploadProgress` / `.fwUploadDone` events.
    case uploadFirmware(image: Data, sha256: Data)
    /// Abort an in-flight firmware upload (best-effort FW_ABORT). Cancels the
    /// `.uploadingFirmware` op locally regardless of the box's reply.
    case abortFirmware
    /// Start/stop the u-blox GPS bridge (0x0D). While on, the box relays raw
    /// UBX reply frames as FileData notifies for the GPS Debug survey. Sending
    /// `on: false` also clears the local bridge routing flag.
    case gpsBridge(on: Bool)
    /// Forward one raw UBX poll frame to the u-blox over the bridge (0x0E).
    case ubxPoll(Data)
    /// Turn the box's GPS receiver on/off to save battery (0x11). Persisted on
    /// the box. Reply arrives as `.gpsPower`; a single-byte op demuxed by the
    /// worker like `setLogMode`.
    case setGpsPower(on: Bool)
    /// Query the box's current GPS power state (0x12); reply arrives as
    /// `.gpsPower`. Legacy firmware never answers → the op times out (unknown).
    case getGpsPower
    /// Fetch the box's persisted calibration blob (0x13). Reply arrives as
    /// `.calibration(Data?)` — `nil` on legacy firmware / timeout. Firmware
    /// v0.0.37+.
    case getCalibration
    /// Push a 32-byte calibration blob (0x14) — see `Calibration.encode`.
    /// Reply arrives as `.calibration(Data?)` (with the sent blob on OK, so
    /// the receiver mirrors it as authoritative without a second GET
    /// round-trip). Firmware v0.0.37+.
    case setCalibration(blob: Data)
    /// BLE_QUIET (0x15) — arm the box's BT-off GPS A/B window for
    /// `durationSeconds`. The box ACKs with a status byte (→ `.quietArmed`),
    /// then disconnects; the client auto-reconnects once the box's radio is
    /// back and fetches the recording with `fetchQuietResult`. Legacy
    /// firmware (< v0.0.57) never replies → the op times out and emits
    /// `.quietResult(durS: 0, samples: nil)`.
    case bleQuiet(durationSeconds: Int)
    /// BLE_QUIET_RESULT (0x16) — fetch the recorded RF samples after the
    /// reconnect. Reply arrives as `.quietResult`.
    case fetchQuietResult
}

/// One 1 Hz RF sample from the box's BT-off window (16 B on the wire, field
/// order pinned in firmware DESIGN.md §"BLE quiet window"). `phase`: 0 = BT
/// on (pre), 1 = BT off, 2 = BT back on (post). `avg6X10` = mean C/N0 of the
/// 6 strongest GPS+Galileo satellites ×10 (0 = no data); `rfFresh` = the
/// MON-RF EMI fields (noise/agc/jam/ant) had a reply within 15 s.
struct QuietSample {
    let phase: Int
    let tS: Int
    let fixType: Int
    let usedSv: Int
    let avg6X10: Int
    let min6: Int
    let max6: Int
    let noise: Int
    let agc: Int
    let jamInd: Int
    let jamState: Int
    let antStatus: Int
    let rfFresh: Bool

    static let wireSize = 16

    /// Parse one sample at byte offset `off`; the caller strides by the
    /// box-declared sample size (≥ `wireSize`) so future firmware may grow
    /// the record without breaking this parser.
    static func parse(_ b: [UInt8], at off: Int) -> QuietSample? {
        guard off + wireSize <= b.count else { return nil }
        func u8(_ i: Int) -> Int { Int(b[off + i]) }
        func u16(_ i: Int) -> Int { u8(i) | (u8(i + 1) << 8) }
        return QuietSample(
            phase: u8(0), tS: u8(1), fixType: u8(2), usedSv: u8(3),
            avg6X10: u16(4), min6: u8(6), max6: u8(7),
            noise: u16(8), agc: u16(10),
            jamInd: u8(12), jamState: u8(13), antStatus: u8(14),
            rfFresh: u8(15) != 0
        )
    }
}

enum BleEvent {
    case status(String)
    case discovered(identifier: UUID, name: String, rssi: Int)
    case scanStopped
    /// `boxId` is the connected peripheral's stable per-install UUID
    /// (`CBPeripheral.identifier`), used as the sync-state DB partition key
    /// — the iOS analogue of the desktop's btleplug peripheral id.
    case connected(boxId: String)
    case disconnected
    /// A bounded auto-reconnect has begun (mid-transfer drop / stall). The
    /// link is actually DOWN even though we suppress `.disconnected` to keep
    /// the UI on the connected screen — so the consumer must stop issuing new
    /// ops (a READ sent now fails "not connected" and orphans its progress
    /// row). Cleared by the next `.connected` (success) or `.disconnected`
    /// (reconnect exhausted).
    case reconnecting
    case listEntry(name: String, size: Int64)
    case listDone
    case readStarted(name: String, size: Int64)
    case readProgress(name: String, bytesDone: Int64)
    /// `base` is the offset the streamed segment started at (= the
    /// resume offset we requested). The consumer appends `content` to
    /// the local mirror at `base` (desktop v0.0.14 live-mirror model).
    case readDone(name: String, content: Data, base: Int64)
    /// A READ was cut short by a link drop / 20 s stall. Carries the
    /// partial segment so the consumer appends it to the mirror — the
    /// resume then continues from the *true* break point, not the last
    /// completed segment (desktop v0.0.9/#6). Followed by an `error`.
    case readAborted(name: String, content: Data, base: Int64)
    case deleteDone(name: String)
    /// The box's current log-mode, from a GET_MODE reply or a confirmed
    /// SET_MODE. `manual == false` → auto (logs on boot), `true` →
    /// manual (idle until START_LOG).
    case logMode(manual: Bool)
    /// The box's firmware version from a GET_VERSION (0x10) reply, trimmed
    /// ASCII (e.g. `"0.0.29"`), or `nil` when the box is legacy firmware that
    /// never answered (the query timed out) or sent a garbled reply. `nil` is
    /// "unknown" and the firmware-update check treats it as older than the
    /// latest release.
    case firmwareVersion(String?)
    /// The box's GPS power state, from a GET (0x12) reply or a confirmed SET
    /// (0x11). `on == true` → receiver active, `false` → in backup mode to save
    /// battery. Legacy firmware that never answers leaves the toggle unknown.
    case gpsPower(on: Bool)
    case error(String)
    /// One decoded SensorStream snapshot (0.5 Hz). Only emitted while
    /// connected to PumpLogger firmware that exposes the SensorStream
    /// characteristic; legacy PumpTsueri builds never produce this event.
    case sample(LiveSample)
    /// One decoded BatteryStatus snapshot (~1/min, plus one on-connect READ
    /// seed). Only emitted on firmware exposing the BatteryStatus
    /// characteristic; legacy PumpTsueri builds never produce this.
    case battery(BatterySample)
    /// A firmware upload started; `total` is the image byte length.
    case fwUploadStarted(total: Int64)
    /// Firmware-upload progress — `bytesDone` of `total` staged so far.
    case fwUploadProgress(bytesDone: Int64, total: Int64)
    /// Firmware upload finished. `success == true` means the box accepted
    /// the image and is rebooting into it (reconnect in a few seconds);
    /// `false` carries a human-readable failure reason in `message`.
    case fwUploadDone(success: Bool, message: String)
    /// One raw u-blox UBX reply frame relayed by the box while the GPS bridge
    /// is active. Consumed by the GPS Debug survey; never touches the FileSync
    /// op state machine.
    case ubxFrame(Data)
    /// The box's calibration blob, from a CAL_GET (0x13) reply or a confirmed
    /// CAL_SET (0x14) round-trip. `Some(blob)` = the box's current 32-byte
    /// blob (receiver should `Calibration.decode` it to drive local state);
    /// `nil` = legacy firmware / GET timed out — the receiver keeps its local
    /// `AgentConfig`.
    case calibration(Data?)
    /// The box accepted BLE_QUIET (0x15) and goes radio-silent for
    /// `durationSeconds` after ~3 s of pre-samples. The disconnect that
    /// follows is expected — the client auto-reconnects once the box's chip
    /// re-inits.
    case quietArmed(durationSeconds: Int)
    /// The BT-off window recording, from a BLE_QUIET_RESULT (0x16) reply.
    /// `samples == nil` = the fetch failed (op timeout / legacy firmware /
    /// link drop) — the `gps_rfq:` lines in the box ERRLOG still carry the
    /// data. An empty array is a valid "window recorded nothing" reply.
    case quietResult(durationSeconds: Int, samples: [QuietSample]?)
}
