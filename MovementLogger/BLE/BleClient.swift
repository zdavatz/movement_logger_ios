import Foundation
import CoreBluetooth
import UIKit

/// Single-worker BLE client for the PumpTsueri FileSync protocol.
///
/// Design mirrors the Kotlin/Android port and the Rust reference client
/// (`stbox-viz-gui/src/ble.rs`): CoreBluetooth delegate callbacks (on a
/// dedicated serial queue) marshal raw events into one AsyncStream; a single
/// Task consumes from that stream and mutates the per-op state machine
/// (Listing / Reading / Deleting). All state mutation stays on one task
/// without locks.
///
/// Notifications are subscribed once per connection. Per-op subscription
/// risks losing the first packet if the box notifies before we resume —
/// same reasoning as the Kotlin/Rust clients.
final class BleClient: NSObject {

    // ----- Public event stream ------------------------------------------------

    let events: AsyncStream<BleEvent>
    private let eventsCont: AsyncStream<BleEvent>.Continuation

    // ----- Internal worker stream (commands + raw delegate events + ticks) ---

    private enum RawEvent {
        case discovered(identifier: UUID, name: String, rssi: Int)
        case centralStateChanged(CBManagerState)
        case connected
        case disconnected(error: Error?)
        case servicesDiscovered(error: Error?)
        case characteristicsDiscovered(error: Error?)
        case notifyStateUpdated(charUUID: CBUUID, error: Error?)
        /// `charUUID` distinguishes FileData (FileSync) from SensorStream (Live tab).
        case notification(charUUID: CBUUID, data: Data)
        case scanTimedOut
        case tick
    }

    private enum WorkerEvent {
        case command(BleCmd)
        case raw(RawEvent)
    }

    private let workerStream: AsyncStream<WorkerEvent>
    private let workerCont: AsyncStream<WorkerEvent>.Continuation

    // ----- CoreBluetooth -----------------------------------------------------

    private let bleQueue = DispatchQueue(label: "ch.pumptsueri.movementlogger.ble")
    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var streamChar: CBCharacteristic?
    /// True once we've kicked off the SensorStream `setNotifyValue(true, …)`;
    /// resets on disconnect. Used to keep `onCharacteristicsDiscovered` (which
    /// fires once per discovered service) idempotent — it can be called
    /// multiple times during connect.
    private var streamSubscribeKicked: Bool = false
    private var op: CurrentOp = .idle
    private var scanning: Bool = false
    private var scanStopTask: Task<Void, Never>?
    private var centralReady: Bool = false

    /// 3-chunk reassembly state for the SensorStream MTU-fallback path
    /// (DESIGN.md §3). When the negotiated MTU is too small for a 46-byte
    /// single notify, the firmware splits the snapshot across three sequential
    /// notifies with first-byte sequence indices 0x00 / 0x01 / 0x02. iOS
    /// auto-negotiates MTU up to ~185 B so this path rarely triggers in
    /// practice, but the firmware can still chunk and we shouldn't drop those
    /// frames silently.
    private var streamAsm: Data = Data()
    private var streamAsmNext: UInt8 = 0

    // ----- Worker tasks ------------------------------------------------------

    private var workerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    // ----- Background-task assertion -----------------------------------------
    //
    // `bluetooth-central` in UIBackgroundModes lets BLE callbacks fire while the
    // app is in the background. To keep the runloop / worker Task / `Task.sleep`
    // timers alive during the quiet moments between BLE notifications (e.g. the
    // 500 ms LIST-inactivity wait, the post-START_LOG sleep, gaps between READ
    // chunks), we also hold a UIApplication background-task assertion while a
    // peripheral is connected. iOS extends that assertion as long as BLE traffic
    // keeps arriving, so a long READ doesn't get suspended even if the user
    // switches apps.
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    override init() {
        var ec: AsyncStream<BleEvent>.Continuation!
        self.events = AsyncStream(BleEvent.self, bufferingPolicy: .bufferingNewest(256)) { ec = $0 }
        self.eventsCont = ec

        var wc: AsyncStream<WorkerEvent>.Continuation!
        self.workerStream = AsyncStream(WorkerEvent.self, bufferingPolicy: .unbounded) { wc = $0 }
        self.workerCont = wc

        super.init()
        self.central = CBCentralManager(delegate: self, queue: bleQueue)

        self.workerTask = Task { [weak self] in await self?.workerLoop() }
        // Watchdog ticks are posted into the same worker stream so they're
        // serialised with everything else — keeps op-state mutation
        // single-threaded without locks.
        self.watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.watchdogTickMs))
                self?.workerCont.yield(.raw(.tick))
            }
        }
    }

    /// Submit a command. Returns immediately; results arrive on `events`.
    func send(_ cmd: BleCmd) {
        workerCont.yield(.command(cmd))
    }

    /// Tear everything down. After calling, no more events will be emitted.
    func close() {
        watchdogTask?.cancel()
        workerCont.finish()
        eventsCont.finish()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        endBackgroundAssertion()
    }

    // -------------------------------------------------------------------------
    //  Background-task assertion
    // -------------------------------------------------------------------------

    private func beginBackgroundAssertion() {
        // UIApplication APIs must be touched on the main actor.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.bgTaskID != .invalid { return }
            self.bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "ble-sync") { [weak self] in
                // Expiration handler — iOS is about to suspend us. End the
                // assertion so the system doesn't kill the app outright.
                self?.endBackgroundAssertion()
            }
        }
    }

    private func endBackgroundAssertion() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.bgTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.bgTaskID)
            self.bgTaskID = .invalid
        }
    }

    // -------------------------------------------------------------------------
    //  Worker loop
    // -------------------------------------------------------------------------

    private func workerLoop() async {
        for await event in workerStream {
            switch event {
            case .command(let c): await handleCommand(c)
            case .raw(let r): await handleRaw(r)
            }
        }
    }

    private func emit(_ e: BleEvent) {
        eventsCont.yield(e)
    }

    private func emitErr(_ msg: String) {
        emit(.error(msg))
    }

    private func emitStatus(_ msg: String) {
        emit(.status(msg))
    }

    // -------------------------------------------------------------------------
    //  Command dispatch
    // -------------------------------------------------------------------------

    private func handleCommand(_ cmd: BleCmd) async {
        switch cmd {
        case .scan: startScan()
        case .connect(let id): connect(identifier: id)
        case .disconnect: disconnectInner(emitEvent: true)
        case .list: sendList()
        case .read(let name, let size): sendRead(name: name, size: size)
        case .stopLog: sendStopLog()
        case .startLog(let dur): await sendStartLog(durationSeconds: dur)
        case .delete(let name): sendDelete(name: name)
        }
    }

    private func startScan() {
        guard centralReady else {
            emitErr("Bluetooth not ready — enable it in Settings")
            return
        }
        guard !scanning else {
            emitStatus("scan already running")
            return
        }
        discovered.removeAll()
        // Scan with nil services: foreground only, but matches the Android client
        // which filters by name in the callback. Specifying service UUIDs would
        // require knowing the parent service of FileCmd/FileData, which the firmware
        // exposes under the ST custom service block — we filter by name to mirror
        // the desktop and Android clients.
        central.scanForPeripherals(withServices: nil, options: nil)
        scanning = true
        emitStatus("scanning…")
        scanStopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.scanDurationMs))
            self?.workerCont.yield(.raw(.scanTimedOut))
        }
    }

    private func stopScan() {
        guard scanning else { return }
        central.stopScan()
        scanning = false
        scanStopTask?.cancel()
        scanStopTask = nil
        emit(.scanStopped)
    }

    private func connect(identifier: UUID) {
        guard peripheral == nil else {
            emitErr("already connected — disconnect first")
            return
        }
        guard let p = discovered[identifier] ?? central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            emitErr("device not in scan results: \(identifier.uuidString)")
            return
        }
        if scanning { stopScan() }
        peripheral = p
        p.delegate = self
        emitStatus("connecting…")
        central.connect(p, options: nil)
    }

    private func disconnectInner(emitEvent: Bool) {
        switch op {
        case .reading(let name, let expected, let content, _, _, _):
            emitErr("READ \(name) aborted by disconnect at \(content.count)/\(expected) B")
        case .listing:
            emitErr("LIST aborted by disconnect")
        case .deleting(let name, _):
            emitErr("DELETE \(name) aborted by disconnect")
        case .idle:
            break
        }
        op = .idle
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        cmdChar = nil
        dataChar = nil
        streamChar = nil
        streamSubscribeKicked = false
        streamAsm.removeAll(keepingCapacity: true)
        streamAsmNext = 0
        endBackgroundAssertion()
        if emitEvent { emit(.disconnected) }
    }

    private func writeCmdBytes(_ payload: Data) -> Bool {
        guard let p = peripheral else { emitErr("not connected"); return false }
        guard let c = cmdChar else { emitErr("FileCmd characteristic missing"); return false }
        p.writeValue(payload, for: c, type: .withoutResponse)
        return true
    }

    private func sendList() {
        guard case .idle = op else {
            emitErr("another op is in flight — wait or Disconnect"); return
        }
        if !writeCmdBytes(Data([FileSyncProtocol.opList])) { return }
        op = .listing(line: "", lastProgress: now(), rowsSeen: 0)
        emitStatus("LIST sent")
    }

    private func sendRead(name: String, size: Int64) {
        guard case .idle = op else {
            emitErr("another op is in flight — wait or Disconnect"); return
        }
        var payload = Data([FileSyncProtocol.opRead])
        payload.append(Data(name.utf8))
        if !writeCmdBytes(payload) { return }
        op = .reading(name: name, expected: size, content: Data(), lastEmit: 0,
                      lastProgress: now(), firstPacket: true)
        emit(.readStarted(name: name, size: size))
    }

    private func sendDelete(name: String) {
        guard case .idle = op else {
            emitErr("another op is in flight — wait or Disconnect"); return
        }
        var payload = Data([FileSyncProtocol.opDelete])
        payload.append(Data(name.utf8))
        if !writeCmdBytes(payload) { return }
        op = .deleting(name: name, lastProgress: now())
        emitStatus("DELETE \(name) sent")
    }

    private func sendStopLog() {
        if !writeCmdBytes(Data([FileSyncProtocol.opStopLog])) { return }
        emitStatus("STOP_LOG sent")
    }

    private func sendStartLog(durationSeconds: Int) async {
        let d = UInt32(bitPattern: Int32(durationSeconds))
        let payload = Data([
            FileSyncProtocol.opStartLog,
            UInt8(d         & 0xFF),
            UInt8((d >>  8) & 0xFF),
            UInt8((d >> 16) & 0xFF),
            UInt8((d >> 24) & 0xFF),
        ])
        if !writeCmdBytes(payload) { return }
        // Mirror the Rust/Kotlin clients: write-without-response returns once bytes
        // are queued, not when transmitted. If the caller queues a Disconnect right
        // behind us, we'd tear down before the opcode hits the air.
        try? await Task.sleep(for: .milliseconds(500))
        emitStatus("START_LOG sent (\(durationSeconds)s) — box rebooting to LOG mode")
    }

    // -------------------------------------------------------------------------
    //  Raw event handling
    // -------------------------------------------------------------------------

    private func handleRaw(_ raw: RawEvent) async {
        switch raw {
        case .discovered(let id, let name, let rssi):
            emit(.discovered(identifier: id, name: name, rssi: rssi))
        case .centralStateChanged(let s):
            onCentralStateChanged(s)
        case .connected:
            emitStatus("connected — discovering services")
            peripheral?.discoverServices(nil)
        case .disconnected(let err):
            if let err = err { emitErr("disconnected: \(err.localizedDescription)") }
            disconnectInner(emitEvent: true)
        case .servicesDiscovered(let err):
            onServicesDiscovered(error: err)
        case .characteristicsDiscovered(let err):
            onCharacteristicsDiscovered(error: err)
        case .notifyStateUpdated(let charUUID, let err):
            onNotifyStateUpdated(charUUID: charUUID, error: err)
        case .notification(let charUUID, let data):
            onNotification(charUUID: charUUID, data: data)
        case .scanTimedOut:
            stopScan()
        case .tick:
            tickWatchdog()
        }
    }

    private func onCentralStateChanged(_ s: CBManagerState) {
        switch s {
        case .poweredOn:
            centralReady = true
            emitStatus("Bluetooth ready")
        case .poweredOff:
            centralReady = false
            emitErr("Bluetooth is off — enable it in Settings")
        case .unauthorized:
            emitErr("Bluetooth permission denied — enable it in Settings → Privacy → Bluetooth")
        case .unsupported:
            emitErr("BLE unsupported on this device")
        case .resetting, .unknown:
            centralReady = false
        @unknown default:
            centralReady = false
        }
    }

    private func onServicesDiscovered(error: Error?) {
        if let error = error {
            emitErr("service discovery failed: \(error.localizedDescription)")
            disconnectInner(emitEvent: true); return
        }
        guard let p = peripheral else { return }
        let services = p.services ?? []
        if services.isEmpty {
            emitErr("PumpTsueri firmware exposes no services")
            disconnectInner(emitEvent: true); return
        }
        for svc in services {
            p.discoverCharacteristics(nil, for: svc)
        }
    }

    private func onCharacteristicsDiscovered(error: Error?) {
        if let error = error {
            emitErr("characteristic discovery failed: \(error.localizedDescription)")
            disconnectInner(emitEvent: true); return
        }
        guard let p = peripheral else { return }
        for svc in (p.services ?? []) {
            for ch in (svc.characteristics ?? []) {
                if ch.uuid == FileSyncProtocol.fileCmdUUID { cmdChar = ch }
                if ch.uuid == FileSyncProtocol.fileDataUUID { dataChar = ch }
                if ch.uuid == FileSyncProtocol.streamUUID { streamChar = ch }
            }
        }
        // Wait until both required characteristics are found across all
        // service-discovery callbacks. didDiscoverCharacteristicsFor fires
        // once per service; we may not have both characteristics yet on the
        // first call.
        guard let data = dataChar, cmdChar != nil else { return }
        p.setNotifyValue(true, for: data)
        // BleEvent.Connected emitted from notifyStateUpdated on success.

        // SensorStream is optional — only PumpLogger firmware exposes it.
        // Subscribe in parallel; CoreBluetooth queues the GATT op internally.
        // Soft-fail: a missing or unsubscribable stream char never blocks
        // FileSync — the Live tab just stays empty.
        if let s = streamChar, !streamSubscribeKicked {
            streamSubscribeKicked = true
            p.setNotifyValue(true, for: s)
        } else if streamChar == nil {
            emitStatus("SensorStream characteristic not advertised — legacy firmware, Live tab will be empty")
        }
    }

    private func onNotifyStateUpdated(charUUID: CBUUID, error: Error?) {
        switch charUUID {
        case FileSyncProtocol.fileDataUUID:
            if let error = error {
                emitErr("subscribe failed: \(error.localizedDescription)")
                disconnectInner(emitEvent: true)
            } else {
                op = .idle
                // Keep the app alive in the background for the whole session.
                // Paired with the `bluetooth-central` UIBackgroundMode so that
                // long READs continue when the user switches apps.
                beginBackgroundAssertion()
                emit(.connected(boxId: peripheral?.identifier.uuidString ?? ""))
            }
        case FileSyncProtocol.streamUUID:
            if let error = error {
                emitStatus("SensorStream subscribe failed (\(error.localizedDescription)) — Live tab will be empty")
            } else {
                emitStatus("SensorStream subscribed (live data at 0.5 Hz)")
            }
        default:
            break
        }
    }

    private func onNotification(charUUID: CBUUID, data: Data) {
        if charUUID == FileSyncProtocol.streamUUID {
            handleStreamNotify(data)
            return
        }
        // FileData path — drive the in-flight op's state machine.
        switch op {
        case .idle:
            break  // stray notify between ops — harmless
        case .listing:
            handleListNotify(data)
        case .reading:
            handleReadNotify(data)
        case .deleting:
            handleDeleteNotify(data)
        }
    }

    /// SensorStream notification handler — single 46-byte notify when the
    /// negotiated ATT MTU is large enough, 3-chunk fallback (seq bytes
    /// 0x00/0x01/0x02) when it isn't. Malformed packets drop silently; the
    /// stream auto-resyncs on the next 0x00 start.
    private func handleStreamNotify(_ bytes: Data) {
        if bytes.count == LiveSample.wireSize {
            // Single-notify path. Reset any in-flight chunked frame so a
            // mid-frame MTU upgrade doesn't leave the asm in a bad state.
            streamAsm.removeAll(keepingCapacity: true)
            streamAsmNext = 0
            if let s = LiveSample.parse(bytes) {
                emit(.sample(s))
            }
            return
        }
        guard !bytes.isEmpty else { return }
        let seq = bytes[bytes.startIndex]
        let body = bytes.dropFirst()
        switch seq {
        case 0x00:
            streamAsm.removeAll(keepingCapacity: true)
            streamAsm.append(body)
            streamAsmNext = 1
        case 0x01:
            guard streamAsmNext == 1 else {
                streamAsm.removeAll(keepingCapacity: true); streamAsmNext = 0
                return
            }
            streamAsm.append(body)
            streamAsmNext = 2
        case 0x02:
            guard streamAsmNext == 2 else {
                streamAsm.removeAll(keepingCapacity: true); streamAsmNext = 0
                return
            }
            streamAsm.append(body)
            if streamAsm.count == LiveSample.wireSize,
               let s = LiveSample.parse(streamAsm) {
                emit(.sample(s))
            }
            streamAsm.removeAll(keepingCapacity: true); streamAsmNext = 0
        default:
            streamAsm.removeAll(keepingCapacity: true); streamAsmNext = 0
        }
    }

    private func handleListNotify(_ value: Data) {
        guard case var .listing(line, _, rowsSeen) = op else { return }
        for b in value {
            if b == UInt8(ascii: "\n") {
                if line.isEmpty {
                    op = .idle
                    emit(.listDone)
                    return
                }
                if let (n, sz) = parseListRow(line) {
                    emit(.listEntry(name: n, size: sz))
                    rowsSeen += 1
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(Character(UnicodeScalar(b)))
            }
        }
        op = .listing(line: line, lastProgress: now(), rowsSeen: rowsSeen)
    }

    private func handleReadNotify(_ value: Data) {
        guard case .reading(let name, let expected, var content, var lastEmit, _, let firstPacket) = op else { return }

        // Status-byte detection: only the first packet, exactly 1 byte, and that
        // byte must be a recognised error code. Avoids false positives on tiny
        // CSV/log files (which start with ASCII text, well below 0x80).
        if firstPacket, value.count == 1, FileSyncProtocol.isStatusByte(value[value.startIndex]) {
            let b = value[value.startIndex]
            emitErr("READ \(name): \(FileSyncProtocol.statusMessage(b)) " +
                "(0x\(String(format: "%02X", b)))")
            op = .idle
            return
        }

        content.append(value)
        let done = Int64(content.count)

        // Progress throttling: every ~4 KB or at EOF. BLE FileSync runs
        // ~1-3 KB/s so this updates the bar every 1-4 s.
        if done - lastEmit >= Self.progressChunkBytes || done >= expected {
            lastEmit = done
            emit(.readProgress(name: name, bytesDone: done))
        }

        if done >= expected {
            let bytes = content.prefix(Int(expected))
            emit(.readDone(name: name, content: Data(bytes)))
            op = .idle
        } else {
            op = .reading(name: name, expected: expected, content: content,
                          lastEmit: lastEmit, lastProgress: now(), firstPacket: false)
        }
    }

    private func handleDeleteNotify(_ value: Data) {
        guard case .deleting(let name, _) = op else { return }
        guard let s = value.first else { return }
        if s == FileSyncProtocol.statusOK {
            emit(.deleteDone(name: name))
        } else {
            emitErr("DELETE \(name): \(FileSyncProtocol.statusMessage(s)) " +
                "(0x\(String(format: "%02X", s)))")
        }
        op = .idle
    }

    private func parseListRow(_ line: String) -> (String, Int64)? {
        guard let commaIdx = line.lastIndex(of: ",") else { return nil }
        let name = String(line[..<commaIdx])
        let sizeStr = line[line.index(after: commaIdx)...]
        guard let size = Int64(sizeStr) else { return nil }
        return (name, size)
    }

    // -------------------------------------------------------------------------
    //  Watchdog
    // -------------------------------------------------------------------------

    private func tickWatchdog() {
        let n = now()
        // LIST inactivity-done fallback: ≥1 row received and no new bytes for
        // LIST_INACTIVITY_DONE → assume we missed the terminator and finish.
        if case .listing(_, let lastProgress, let rowsSeen) = op,
           rowsSeen > 0, n - lastProgress > Self.listInactivityDoneMs {
            op = .idle
            emit(.listDone)
            return
        }
        let stale: Bool
        switch op {
        case .listing(_, let lp, _): stale = n - lp > Self.opIdleTimeoutMs
        case .reading(_, _, _, _, let lp, _): stale = n - lp > Self.opIdleTimeoutMs
        case .deleting(_, let lp): stale = n - lp > Self.opIdleTimeoutMs
        case .idle: stale = false
        }
        guard stale else { return }
        switch op {
        case .listing: emitErr("LIST timed out — no notifies for 20 s")
        case .reading(let name, let expected, let content, _, _, _):
            emitErr("READ \(name) timed out at \(content.count)/\(expected) B — no notifies for 20 s")
        case .deleting(let name, _): emitErr("DELETE \(name) timed out — no notify for 20 s")
        case .idle: break
        }
        op = .idle
    }

    // -------------------------------------------------------------------------
    //  Internal types
    // -------------------------------------------------------------------------

    private enum CurrentOp {
        case idle
        case listing(line: String, lastProgress: Int64, rowsSeen: Int)
        case reading(name: String, expected: Int64, content: Data,
                     lastEmit: Int64, lastProgress: Int64, firstPacket: Bool)
        case deleting(name: String, lastProgress: Int64)
    }

    private func now() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // -------------------------------------------------------------------------
    //  Tunables
    // -------------------------------------------------------------------------

    private static let scanDurationMs: Int = 5_000
    private static let watchdogTickMs: Int = 200
    private static let opIdleTimeoutMs: Int64 = 20_000
    private static let listInactivityDoneMs: Int64 = 500
    private static let progressChunkBytes: Int64 = 4 * 1024
}

// MARK: - CBCentralManagerDelegate

extension BleClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        workerCont.yield(.raw(.centralStateChanged(central.state)))
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        guard FileSyncProtocol.boxNames.contains(name) else { return }
        // Retain the CBPeripheral so we can connect to it later.
        discovered[peripheral.identifier] = peripheral
        workerCont.yield(.raw(.discovered(
            identifier: peripheral.identifier, name: name, rssi: RSSI.intValue
        )))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        workerCont.yield(.raw(.connected))
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        workerCont.yield(.raw(.disconnected(error: error)))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        workerCont.yield(.raw(.disconnected(error: error)))
    }
}

// MARK: - CBPeripheralDelegate

extension BleClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        workerCont.yield(.raw(.servicesDiscovered(error: error)))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        workerCont.yield(.raw(.characteristicsDiscovered(error: error)))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Both FileData (FileSync) and SensorStream (Live) subscribe via CCCD;
        // route the ack by characteristic UUID so the worker can update the
        // right state-machine slot.
        let u = characteristic.uuid
        guard u == FileSyncProtocol.fileDataUUID || u == FileSyncProtocol.streamUUID else { return }
        workerCont.yield(.raw(.notifyStateUpdated(charUUID: u, error: error)))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let u = characteristic.uuid
        guard u == FileSyncProtocol.fileDataUUID || u == FileSyncProtocol.streamUUID,
              let value = characteristic.value else { return }
        workerCont.yield(.raw(.notification(charUUID: u, data: value)))
    }
}
