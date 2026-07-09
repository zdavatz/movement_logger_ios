import Foundation
import CoreBluetooth
import Observation

/// Control-only CoreBluetooth central for the PumpTsueri MovementLogger box.
///
/// Deliberately much smaller than the iOS `BleClient`: the watch never syncs
/// files, so there's no LIST/READ state machine, no reconnect ladder, no
/// firmware update. It scans for the box, connects, and can issue exactly two
/// control flows — start a recording session, and stop it.
///
/// Threading: the `CBCentralManager` is created with `queue: nil`, so every
/// delegate callback runs on the main queue. All observable state is therefore
/// mutated on main — safe for SwiftUI — without any locks or actor hops.
@Observable
final class BoxBleClient: NSObject {

    enum Link: Equatable {
        case unknown, poweredOff, unavailable, idle, scanning, connecting, connected
    }

    /// Connection lifecycle, for the UI.
    private(set) var link: Link = .unknown
    /// Advertised name of the connected box (`PumpTsueri` / `STBoxFs`).
    private(set) var boxName: String? = nil
    /// One-line human status, surfaced in the UI / logs.
    private(set) var statusLine: String = "Starting Bluetooth…"

    /// True only when we hold a live link *and* the FileCmd characteristic —
    /// i.e. we can actually issue commands. This is the gate the session
    /// controller uses to decide box-vs-GPS.
    var isConnected: Bool { link == .connected && cmdChar != nil }

    // MARK: - CoreBluetooth internals (untracked)

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var cmdChar: CBCharacteristic?
    @ObservationIgnored private var dataChar: CBCharacteristic?
    @ObservationIgnored private var wantScan = false
    @ObservationIgnored private var onStartReply: ((Bool) -> Void)?
    @ObservationIgnored private var awaitingStartReply = false

    /// The box silently drops a FileCmd that arrives within ~2 s of a SET_TIME
    /// (it's busy appending the `# SYNC` anchor to SD). START_LOG also needs a
    /// brief settle after its write-without-response is queued. These are the
    /// two delays used by `startLog`.
    @ObservationIgnored private let startLogSettle: TimeInterval = 0.6
    @ObservationIgnored private let startReplyTimeout: TimeInterval = 6.0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning / connection

    /// Begin (or resume) looking for the box. Idempotent.
    func startScanning() {
        wantScan = true
        beginScanIfPossible()
    }

    private func beginScanIfPossible() {
        guard central.state == .poweredOn, wantScan, peripheral == nil else { return }
        link = .scanning
        statusLine = "Scanning for box…"
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func disconnect() {
        wantScan = false
        if central.isScanning { central.stopScan() }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: - Control commands

    /// Start an open-ended recording session on the box.
    ///
    /// Sequence (order matters — see the firmware):
    ///   1. `START_LOG(dur=0)` opens the session and its CSVs; the box replies
    ///      one status byte on FileData.
    ///   2. after a short settle, `SET_TIME(now)` stamps a `# SYNC` wall-clock
    ///      anchor into the freshly-opened CSVs (a no-op unless a session is
    ///      active, which is why it follows START_LOG).
    ///
    /// `reply(true)` fires when the box acknowledges START_LOG with status OK;
    /// `reply(false)` on an error byte or if no reply arrives in time.
    func startLog(reply: @escaping (Bool) -> Void) {
        guard let p = peripheral, let cmd = cmdChar else { reply(false); return }
        onStartReply = reply
        awaitingStartReply = true
        p.writeValue(FileSyncProtocol.startLogOpenEnded(), for: cmd, type: .withoutResponse)
        statusLine = "START_LOG sent"

        // Legacy firmware might not reply; don't hang the UI forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + startReplyTimeout) { [weak self] in
            guard let self, self.awaitingStartReply else { return }
            self.awaitingStartReply = false
            let cb = self.onStartReply; self.onStartReply = nil
            self.statusLine = "No START_LOG reply from box"
            cb?(false)
        }
    }

    /// Stop the active session. No FileData reply is expected (the firmware
    /// closes the file and the host re-checks via LIST — which the watch never
    /// does), so this is fire-and-forget.
    func stopLog() {
        guard let p = peripheral, let cmd = cmdChar else { return }
        p.writeValue(Data([FileSyncProtocol.opStopLog]), for: cmd, type: .withoutResponse)
        statusLine = "STOP_LOG sent"
    }

    private func sendSetTime() {
        guard let p = peripheral, let cmd = cmdChar else { return }
        let epochMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        p.writeValue(FileSyncProtocol.setTime(epochMs: epochMs), for: cmd, type: .withoutResponse)
        statusLine = "Box recording · clock anchored"
    }

    private func cleanupPeripheral() {
        peripheral = nil
        cmdChar = nil
        dataChar = nil
        boxName = nil
        awaitingStartReply = false
        if let cb = onStartReply { onStartReply = nil; cb(false) }
        if link != .poweredOff && link != .unavailable {
            link = wantScan ? .scanning : .idle
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BoxBleClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if link == .unknown || link == .poweredOff || link == .unavailable { link = .idle }
            statusLine = "Bluetooth ready"
            beginScanIfPossible()
        case .poweredOff:
            link = .poweredOff
            statusLine = "Bluetooth is off"
            cleanupPeripheral()
        case .unauthorized:
            link = .unavailable
            statusLine = "Bluetooth permission denied"
        case .unsupported:
            link = .unavailable
            statusLine = "Bluetooth unavailable"
        default:
            link = .unavailable
            statusLine = "Bluetooth resetting…"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        guard FileSyncProtocol.boxNames.contains(advName) else { return }
        central.stopScan()
        self.peripheral = peripheral
        self.boxName = advName
        peripheral.delegate = self
        link = .connecting
        statusLine = "Connecting to \(advName)…"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        statusLine = "Discovering services…"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        statusLine = "Connect failed — retrying"
        cleanupPeripheral()
        beginScanIfPossible()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        statusLine = "Box disconnected"
        cleanupPeripheral()
        beginScanIfPossible()
    }
}

// MARK: - CBPeripheralDelegate

extension BoxBleClient: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            statusLine = "Service discovery failed"
            return
        }
        for s in services {
            peripheral.discoverCharacteristics(
                [FileSyncProtocol.fileCmdUUID, FileSyncProtocol.fileDataUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case FileSyncProtocol.fileCmdUUID:
                cmdChar = c
            case FileSyncProtocol.fileDataUUID:
                dataChar = c
                peripheral.setNotifyValue(true, for: c)   // .connected set once notifying confirms
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == FileSyncProtocol.fileDataUUID else { return }
        if error == nil, characteristic.isNotifying, cmdChar != nil {
            link = .connected
            statusLine = "Box connected"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == FileSyncProtocol.fileDataUUID,
              let first = characteristic.value?.first else { return }

        // The only reply the watch tracks is START_LOG's status byte.
        if awaitingStartReply {
            awaitingStartReply = false
            let ok = (first == FileSyncProtocol.stOk)
            let cb = onStartReply; onStartReply = nil
            if ok {
                // A session (and its CSVs) is now open — anchor the clock after
                // the box has settled from the START_LOG write.
                DispatchQueue.main.asyncAfter(deadline: .now() + startLogSettle) { [weak self] in
                    self?.sendSetTime()
                }
            } else {
                statusLine = String(format: "Box START_LOG error 0x%02X", first)
            }
            cb?(ok)
        }
    }
}
