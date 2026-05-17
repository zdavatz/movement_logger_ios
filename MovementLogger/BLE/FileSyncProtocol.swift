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

    // Status bytes returned in single-byte FileData notifies.
    static let statusOK: UInt8 = 0x00
    static let statusBusy: UInt8 = 0xB0
    static let statusNotFound: UInt8 = 0xE1
    static let statusIOError: UInt8 = 0xE2
    static let statusBadRequest: UInt8 = 0xE3

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
    case listEntry(name: String, size: Int64)
    case listDone
    case readStarted(name: String, size: Int64)
    case readProgress(name: String, bytesDone: Int64)
    /// `base` is the offset the streamed segment started at (= the
    /// resume offset we requested). The consumer appends `content` to
    /// the local mirror at `base` (desktop v0.0.14 live-mirror model).
    case readDone(name: String, content: Data, base: Int64)
    case deleteDone(name: String)
    case error(String)
    /// One decoded SensorStream snapshot (0.5 Hz). Only emitted while
    /// connected to PumpLogger firmware that exposes the SensorStream
    /// characteristic; legacy PumpTsueri builds never produce this event.
    case sample(LiveSample)
}
