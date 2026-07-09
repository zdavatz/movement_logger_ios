import Foundation
import CoreBluetooth

/// Wire protocol for the PumpTsueri SensorTile.box's BLE FileSync service.
///
/// This is the slim, control-only subset the watch needs — start/stop a
/// recording session and anchor the box clock. The authoritative spec lives in
/// the firmware (`movement_logger_firmware/Src/ble.c`); the full host client is
/// `movement_logger_ios/MovementLogger/BLE/FileSyncProtocol.swift`.
enum FileSyncProtocol {
    /// Advertised local names to match. `PumpTsueri` is the legacy firmware;
    /// `STBoxFs` is the newer PumpLogger firmware. Match either.
    static let boxNames: Set<String> = ["PumpTsueri", "STBoxFs"]

    /// FileCmd — host writes opcodes here (write-without-response).
    static let fileCmdUUID = CBUUID(string: "00000080-0010-11e1-ac36-0002a5d5c51b")
    /// FileData — box notifies replies here (1-byte status for the control ops
    /// we use).
    static let fileDataUUID = CBUUID(string: "00000040-0010-11e1-ac36-0002a5d5c51b")

    // Opcodes (first byte of a FileCmd write).
    static let opStopLog:  UInt8 = 0x04   // (none) — no FileData reply
    static let opStartLog: UInt8 = 0x05   // [<dur:u32-LE>] 0 = until STOP_LOG. → 1-byte status
    static let opSetMode:  UInt8 = 0x06   // <u8> 0=auto 1=manual → 1-byte status
    static let opSetTime:  UInt8 = 0x08   // <epoch_ms:u64-LE> → stamps # SYNC anchor, fire-and-forget

    // FileData status bytes.
    static let stOk:       UInt8 = 0x00
    static let stBusy:     UInt8 = 0xB0
    static let stIoError:  UInt8 = 0xE2
    static let stBadReq:   UInt8 = 0xE3

    /// START_LOG payload for an open-ended session (`dur = 0`): the box records
    /// until an explicit STOP_LOG (or power loss).
    static func startLogOpenEnded() -> Data {
        Data([opStartLog, 0, 0, 0, 0])
    }

    /// SET_TIME payload carrying the host wall-clock in epoch milliseconds.
    static func setTime(epochMs: Int64) -> Data {
        var le = UInt64(bitPattern: epochMs).littleEndian
        var payload = Data([opSetTime])
        withUnsafeBytes(of: &le) { payload.append(contentsOf: $0) }
        return payload
    }
}
