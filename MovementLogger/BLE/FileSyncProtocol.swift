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
    case error(String)
    /// One decoded SensorStream snapshot (0.5 Hz). Only emitted while
    /// connected to PumpLogger firmware that exposes the SensorStream
    /// characteristic; legacy PumpTsueri builds never produce this event.
    case sample(LiveSample)
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
}
