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
    private var battChar: CBCharacteristic?
    /// True while the u-blox GPS bridge (opcode 0x0D) is active. FileData
    /// notifies then carry raw UBX frames for the GPS Debug survey instead of
    /// FileSync payloads, so they bypass the `op` state machine. Reset on
    /// disconnect.
    private var bridgeActive: Bool = false
    /// True once we've kicked off the SensorStream `setNotifyValue(true, …)`;
    /// resets on disconnect. Used to keep `onCharacteristicsDiscovered` (which
    /// fires once per discovered service) idempotent — it can be called
    /// multiple times during connect.
    private var streamSubscribeKicked: Bool = false
    /// True once we've kicked off the BatteryStatus subscribe + one-shot read.
    /// Reset on disconnect; keeps `onCharacteristicsDiscovered` idempotent.
    private var battSubscribeKicked: Bool = false
    private var op: CurrentOp = .idle
    private var scanning: Bool = false
    /// Monotonic deadline (`now()` clock, ms) until which file commands must
    /// hold off because the box is still digesting a SET_TIME. The firmware
    /// holds exactly one pending command; right after `0x08` it's busy
    /// appending the `# SYNC` anchor to the open CSV on SD and **silently
    /// drops** the next FileCmd that arrives too soon — so a LIST/READ tapped
    /// a few hundred ms after connect would never be answered and trip the
    /// 20 s watchdog. Confirmed on Android's wire trace: LIST timed out only
    /// when it followed `0x08` by ~0.5 s, and always succeeded with a ≥1.8 s
    /// gap. `awaitCmdSettle()` enforces the gap. 0 = no pending settle.
    private var setTimeSettleUntil: Int64 = 0
    /// Identifier of the box we last successfully subscribed to — the
    /// reconnect target after an unexpected mid-transfer drop.
    private var lastConnectedId: UUID?
    /// Bounded auto-reconnect state machine (desktop v0.0.11–13). Driven
    /// by the 200 ms watchdog tick so it composes with the single-worker
    /// model without new concurrency. nil = not reconnecting.
    private var reconnect: ReconnectState?
    private struct ReconnectState {
        let id: UUID
        var attempt: Int
        var phase: Phase
        var nextAtMs: Int64
        enum Phase { case waiting, scanning, connecting }
    }
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
    // peripheral is connected. A single `beginBackgroundTask` only grants a
    // finite slice (~30 s on modern iOS) and is NOT auto-extended by BLE
    // traffic — so we RENEW it: the expiration handler immediately starts a
    // fresh assertion before ending the old one, keeping the worker alive
    // across the lock screen for the whole connected session (gated by
    // `bgRenew` so a Disconnect/close stops the chain).
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    /// While true, an expiring background assertion re-arms a new one. Set on
    /// connect, cleared on disconnect/close so the renewal chain terminates.
    private var bgRenew: Bool = false

    override init() {
        var ec: AsyncStream<BleEvent>.Continuation!
        self.events = AsyncStream(BleEvent.self, bufferingPolicy: .bufferingNewest(256)) { ec = $0 }
        self.eventsCont = ec

        var wc: AsyncStream<WorkerEvent>.Continuation!
        self.workerStream = AsyncStream(WorkerEvent.self, bufferingPolicy: .unbounded) { wc = $0 }
        self.workerCont = wc

        super.init()
        // State Preservation & Restoration: iOS will relaunch the app in the
        // background (or hand state back on cold launch) when the previously-
        // connected box reconnects in range or fires a notification on a
        // subscribed characteristic. The identifier must be stable across
        // launches AND unique per app. See `centralManager(_:willRestoreState:)`
        // below for the restore hook. Paired with the `bluetooth-central`
        // UIBackgroundMode and the BG sync agent (`Sync/`).
        self.central = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            ]
        )

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
            self.bgRenew = true
            if self.bgTaskID != .invalid { return }
            self.startBgAssertionOnMain()
        }
    }

    /// Start one background-task assertion. Its expiration handler re-arms a
    /// fresh assertion (when `bgRenew`) BEFORE ending the old one, so there's
    /// never a window with zero assertions where iOS could suspend us. Must
    /// run on the main thread (UIKit invokes the expiration handler on main).
    private func startBgAssertionOnMain() {
        let app = UIApplication.shared
        self.bgTaskID = app.beginBackgroundTask(withName: "ble-sync") { [weak self] in
            guard let self = self else { return }
            let expiring = self.bgTaskID
            self.bgTaskID = .invalid
            if self.bgRenew { self.startBgAssertionOnMain() }
            if expiring != .invalid { app.endBackgroundTask(expiring) }
        }
    }

    private func endBackgroundAssertion() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.bgRenew = false
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
        // Hold file commands until the post-SET_TIME settle elapses (see
        // `setTimeSettleUntil`). Connection-control + the time write itself
        // never wait — only the FileCmd ops the box would otherwise drop.
        switch cmd {
        case .list, .read, .delete, .setLogMode, .getLogMode, .setGpsPower, .getGpsPower,
             .getCalibration, .setCalibration:
            await awaitCmdSettle()
        default: break
        }
        switch cmd {
        case .scan: startScan()
        case .connect(let id): connect(identifier: id)
        case .disconnect:
            // User-initiated: cancel any auto-reconnect and forget the
            // box so a deliberate disconnect doesn't bounce back.
            reconnect = nil
            lastConnectedId = nil
            disconnectInner(emitEvent: true)
        case .list: sendList()
        case .read(let name, let size, let offset):
            sendRead(name: name, size: size, offset: offset)
        case .stopLog: sendStopLog()
        case .startLog(let dur): await sendStartLog(durationSeconds: dur)
        case .delete(let name): sendDelete(name: name)
        case .setLogMode(let m): sendSetMode(manual: m)
        case .getLogMode: sendGetMode()
        case .getFirmwareVersion: sendGetFirmwareVersion()
        case .setTime(let ms): sendSetTime(epochMs: ms)
        case .uploadFirmware(let image, let sha): startFwUpload(image: image, sha256: sha)
        case .abortFirmware: abortFwUpload(reason: "cancelled by user")
        case .gpsBridge(let on): sendGpsBridge(on: on)
        case .ubxPoll(let frame): sendUbxPoll(frame: frame)
        case .setGpsPower(let on): sendSetGpsPower(on: on)
        case .getGpsPower: sendGetGpsPower()
        case .getCalibration: sendGetCalibration()
        case .setCalibration(let blob): sendSetCalibration(blob: blob)
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
        case .reading(let name, let expected, let base, let content, _, _, _):
            // Hand back the partial so the resume continues from the
            // true break point (appended to the mirror), then surface
            // the abort (desktop v0.0.9 disconnect_inner).
            emit(.readAborted(name: name, content: content, base: base))
            emitErr("READ \(name) aborted by disconnect at \(base + Int64(content.count))/\(expected) B")
        case .listing:
            emitErr("LIST aborted by disconnect")
        case .deleting(let name, _):
            emitErr("DELETE \(name) aborted by disconnect")
        case .modeReq(let isSet, _, _):
            emitErr("\(isSet ? "SET_MODE" : "GET_MODE") aborted by disconnect")
        case .gpsPwrReq(let isSet, _, _):
            emitErr("\(isSet ? "GPS_POWER" : "GPS_GET_POWER") aborted by disconnect")
        case .calibrationReq(let isSet, _, _):
            // A mid-CAL_GET/CAL_SET link drop is benign: the client keeps its
            // local AgentConfig, and the next connect's chain re-runs GET_CAL
            // (and any queued SET from a local calibration change re-sends
            // itself when the user next touches it). Log only — no error
            // banner about a mid-teardown calibration RPC.
            emitStatus("\(isSet ? "CAL_SET" : "CAL_GET") aborted by disconnect")
        case .gettingVersion:
            // Resolve the firmware-version query as unknown so a mid-query
            // disconnect doesn't leave the update check hanging (mirrors the
            // desktop's mid-query FirmwareVersion(None) path). Not an error —
            // a lost link during the connect-time probe is benign.
            emit(.firmwareVersion(nil))
        case .uploadingFirmware(_, _, let offset, _, _, let phase, _):
            // A disconnect during COMMIT is the EXPECTED success path: the
            // box swaps banks + resets, dropping the link within ~200 ms.
            // Treat it as success. A drop in begin/data is a real failure —
            // the staged image is incomplete and the box stays on old fw.
            if phase == .commit {
                emit(.fwUploadDone(success: true,
                                   message: "firmware accepted — box is rebooting"))
            } else {
                emit(.fwUploadDone(success: false,
                                   message: "firmware upload interrupted at \(offset) B (link lost)"))
            }
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
        battChar = nil
        battSubscribeKicked = false
        streamAsm.removeAll(keepingCapacity: true)
        streamAsmNext = 0
        bridgeActive = false
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

    /// Turn the u-blox GPS bridge on/off (opcode 0x0D). Fire-and-forget — the
    /// box sends no FileData reply to the command itself; UBX reply frames
    /// arrive later as bridged FileData notifies. Starting requires an idle op
    /// (the survey and a FileSync READ can't share the FileData channel).
    private func sendGpsBridge(on: Bool) {
        if on {
            guard case .idle = op else {
                emitErr("another op is in flight — stop it before GPS Debug"); return
            }
        }
        if !writeCmdBytes(Data([FileSyncProtocol.opGpsBridge, on ? 1 : 0])) {
            bridgeActive = false   // link gone → nothing is bridging anymore
            return
        }
        bridgeActive = on
        emitStatus(on ? "GPS bridge on" : "GPS bridge off")
    }

    /// Forward one raw UBX poll frame to the u-blox (opcode 0x0E). No-op unless
    /// the bridge is active. Poll frames are tiny (8 B) so a single
    /// write-without-response fits any negotiated MTU.
    private func sendUbxPoll(frame: Data) {
        guard bridgeActive, !frame.isEmpty else { return }
        var payload = Data([FileSyncProtocol.opUbxPoll])
        payload.append(frame)
        _ = writeCmdBytes(payload)
    }

    private func sendRead(name: String, size: Int64, offset: Int64) {
        guard case .idle = op else {
            emitErr("another op is in flight — wait or Disconnect"); return
        }
        // Opcode payload: 0x02 + name + NUL + 4-byte LE start offset.
        // The firmware seeks to `offset` before streaming, so a resumed
        // or grown file continues mid-file. offset is u32 on the wire —
        // SD files are well under 4 GiB.
        var payload = Data([FileSyncProtocol.opRead])
        payload.append(Data(name.utf8))
        payload.append(0x00)
        var le = UInt32(clamping: offset).littleEndian
        withUnsafeBytes(of: &le) { payload.append(contentsOf: $0) }
        if !writeCmdBytes(payload) { return }
        op = .reading(name: name, expected: size, base: offset, content: Data(),
                      lastEmit: offset, lastProgress: now(), firstPacket: true)
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
        // write-without-response returns once bytes are queued, not when
        // transmitted — settle before any follow-up command.
        try? await Task.sleep(for: .milliseconds(500))
        // Current firmware does NOT reboot on START_LOG: it opens a
        // session and auto-stops after the duration. (Legacy PumpTsueri
        // rebooted; we no longer rely on that.)
        emitStatus("START_LOG sent (\(durationSeconds)s)")
    }

    private func sendSetMode(manual: Bool) {
        if case .idle = op {} else {
            emitErr("SET_MODE rejected — another op in flight")
            return
        }
        let payload = Data([FileSyncProtocol.opSetMode, manual ? 1 : 0])
        if !writeCmdBytes(payload) { return }
        op = .modeReq(isSet: true, manual: manual, lastProgress: now())
        emitStatus("SET_MODE \(manual ? "manual" : "auto") sent")
    }

    private func sendGetMode() {
        if case .idle = op {} else {
            emitErr("GET_MODE rejected — another op in flight")
            return
        }
        if !writeCmdBytes(Data([FileSyncProtocol.opGetMode])) { return }
        op = .modeReq(isSet: false, manual: false, lastProgress: now())
    }

    /// GPS_POWER (0x11) — twin of `sendSetMode`. One status-byte reply demuxed
    /// by the `.gpsPwrReq` op; on OK the box is now in the requested state.
    private func sendSetGpsPower(on: Bool) {
        if case .idle = op {} else {
            emitErr("GPS_POWER rejected — another op in flight")
            return
        }
        let payload = Data([FileSyncProtocol.opGpsPower, on ? 1 : 0])
        if !writeCmdBytes(payload) { return }
        op = .gpsPwrReq(isSet: true, on: on, lastProgress: now())
        emitStatus("GPS_POWER \(on ? "on" : "off") sent")
    }

    /// GPS_GET_POWER (0x12) — twin of `sendGetMode`. Reply is one byte 0/1.
    private func sendGetGpsPower() {
        if case .idle = op {} else {
            emitErr("GPS_GET_POWER rejected — another op in flight")
            return
        }
        if !writeCmdBytes(Data([FileSyncProtocol.opGpsGetPower])) { return }
        op = .gpsPwrReq(isSet: false, on: false, lastProgress: now())
    }

    /// CAL_GET (0x13). Fetch the box's persisted board-orientation calibration
    /// blob so a "Zero here" / nosePlusY / heading-bias set on ANY host is
    /// visible to this one on the next connect. Firmware v0.0.37+; legacy
    /// silently ignores it → the `.calibrationReq` op times out and emits
    /// `.calibration(nil)`. Best-effort like `sendGetGpsPower`: self-guards on
    /// `op == .idle`, never trampling a LIST/READ; the caller re-queues after
    /// the current op completes. Reply is a single 32-byte FileData notify.
    private func sendGetCalibration() {
        if case .idle = op {} else {
            emitErr("CAL_GET rejected — another op in flight")
            return
        }
        if !writeCmdBytes(Data([FileSyncProtocol.opCalGet])) { return }
        op = .calibrationReq(isSet: false, blob: Data(count: 32), lastProgress: now())
    }

    /// CAL_SET (0x14 + 32-byte blob). Push the per-field-encoded blob (see
    /// `Calibration.encode`) to the box for merge into `CAL.CFG`. Box replies
    /// one status byte; the `.calibrationReq` op demuxes it and, on OK,
    /// re-emits `.calibration(blob)` with the just-pushed blob so the client
    /// mirrors the values as authoritative without a second GET round-trip.
    /// Rejected while another op is in flight — same as `sendSetGpsPower`.
    private func sendSetCalibration(blob: Data) {
        guard blob.count == 32 else {
            emitErr("CAL_SET: internal — blob must be 32 bytes")
            return
        }
        if case .idle = op {} else {
            emitErr("CAL_SET rejected — another op in flight")
            return
        }
        var payload = Data([FileSyncProtocol.opCalSet])
        payload.append(blob)
        if !writeCmdBytes(payload) { return }
        let mask = blob.count >= 2 ? blob[blob.startIndex + 1] : 0
        emitStatus(String(format: "CAL_SET sent (mask=0x%02X)", mask))
        op = .calibrationReq(isSet: true, blob: blob, lastProgress: now())
    }

    /// GET_VERSION (0x10) — exact twin of `sendGetMode`: self-guard on an idle
    /// op (so it can't trample an in-flight LIST/READ — the reply is demuxed by
    /// `op`), write the single opcode byte, and park the op. The box answers
    /// with one FileData notify carrying the ASCII version string; legacy
    /// firmware never replies, so the `gettingVersion` watchdog arm emits
    /// `.firmwareVersion(nil)`.
    private func sendGetFirmwareVersion() {
        if case .idle = op {} else {
            emitErr("GET_VERSION rejected — another op in flight")
            return
        }
        if !writeCmdBytes(Data([FileSyncProtocol.opGetVersion])) { return }
        op = .gettingVersion(lastProgress: now())
    }

    /// SET_TIME `0x08 + epoch_ms(u64-LE)`: hand the box the phone's wall
    /// clock so it stamps a `# SYNC` anchor into the open Sens/Gps CSVs.
    /// Deliberately *fire-and-forget* — it does NOT occupy a `CurrentOp`
    /// slot: the host never needs the reply, and legacy firmware that
    /// doesn't implement 0x08 never answers (so tracking it would stall the
    /// op for the full 20 s watchdog window). The box's OK byte, if any,
    /// lands while `op == .idle` and is harmlessly ignored. Skipped if an
    /// op is mid-flight so a stray marker can't interleave with a READ.
    private func sendSetTime(epochMs: Int64) {
        guard case .idle = op else { return }
        var le = UInt64(bitPattern: epochMs).littleEndian
        var payload = Data([FileSyncProtocol.opSetTime])
        withUnsafeBytes(of: &le) { payload.append(contentsOf: $0) }
        if !writeCmdBytes(payload) { return }
        // Box is now busy writing the # SYNC anchor; hold the next FileCmd
        // for the settle window so the firmware doesn't drop it.
        setTimeSettleUntil = now() + Self.setTimeSettleMs
        emitStatus("SET_TIME sent — box clock anchored to phone")
    }

    /// Block until the post-SET_TIME settle window elapses. The worker is
    /// single-op, so stalling here can't starve a concurrent transfer — it
    /// just spaces the time write from the following command. Only ever
    /// waits once per connect (the deadline isn't re-armed).
    private func awaitCmdSettle() async {
        let wait = setTimeSettleUntil - now()
        if wait > 0 {
            try? await Task.sleep(for: .milliseconds(Int(wait)))
        }
    }

    // -------------------------------------------------------------------------
    //  Firmware update (OTA over FileCmd/FileData)
    // -------------------------------------------------------------------------
    //
    // Handshake: FW_BEGIN (erases the inactive bank, ~1 s) → a stream of
    // FW_DATA chunks, each ACK-gated on a 4-byte next-offset reply before the
    // next is sent → FW_COMMIT (verifies the SHA, swaps banks, resets — the
    // link drops within ~200 ms, which we treat as success). Single-in-flight
    // through the same `.uploadingFirmware` op slot as READ; the box rejects
    // concurrent ops with BUSY.

    /// Per-FW_DATA payload byte budget: opcode(1) + offset(4) = 5 header bytes
    /// subtracted from the negotiated write length, clamped to 244 (the
    /// firmware's receive buffer). Smaller is fine, just slower.
    private func fwChunkBytes() -> Int {
        let maxWrite = peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 23
        let usable = min(244, maxWrite) - 5
        return max(1, usable)
    }

    private func startFwUpload(image: Data, sha256: Data) {
        guard case .idle = op else {
            emitErr("another op is in flight — wait or Disconnect"); return
        }
        guard sha256.count == 32 else {
            emit(.fwUploadDone(success: false, message: "internal error: SHA-256 must be 32 bytes"))
            return
        }
        guard !image.isEmpty else {
            emit(.fwUploadDone(success: false, message: "firmware image is empty"))
            return
        }
        // FW_BEGIN: 0x09 + image_len(u32-LE) + sha256(32) = 37 bytes.
        var payload = Data([FileSyncProtocol.opFwBegin])
        var lenLE = UInt32(clamping: image.count).littleEndian
        withUnsafeBytes(of: &lenLE) { payload.append(contentsOf: $0) }
        payload.append(sha256)
        if !writeCmdBytes(payload) {
            emit(.fwUploadDone(success: false, message: "not connected"))
            return
        }
        op = .uploadingFirmware(image: image, sha256: sha256, offset: 0,
                                lastEmit: 0, retries: 0, phase: .begin,
                                lastProgress: now())
        emit(.fwUploadStarted(total: Int64(image.count)))
        emitStatus("FW_BEGIN sent (\(image.count) B) — erasing bank…")
    }

    /// Send the FW_DATA chunk at the current `offset`. Returns false if the
    /// write itself failed (no peripheral / no characteristic).
    @discardableResult
    private func sendFwChunk() -> Bool {
        guard case .uploadingFirmware(let image, _, let offset, _, _, _, _) = op else { return false }
        let n = min(fwChunkBytes(), image.count - Int(offset))
        guard n > 0 else { return false }
        let start = image.index(image.startIndex, offsetBy: Int(offset))
        let end = image.index(start, offsetBy: n)
        var payload = Data([FileSyncProtocol.opFwData])
        var offLE = UInt32(clamping: offset).littleEndian
        withUnsafeBytes(of: &offLE) { payload.append(contentsOf: $0) }
        payload.append(image[start..<end])
        return writeCmdBytes(payload)
    }

    /// FW_COMMIT — verify + swap + reset. The box drops the link right after
    /// the 0xA0 reply; the disconnect-after-commit is treated as success.
    private func sendFwCommit() {
        if !writeCmdBytes(Data([FileSyncProtocol.opFwCommit])) {
            // Lost the link before COMMIT could be written. If we'd already
            // staged the whole image the box may still commit on its own
            // timeout, but we can't know — report a clean failure.
            finishFwUpload(success: false, message: "lost connection before commit")
            return
        }
        emitStatus("FW_COMMIT sent — box verifying image…")
    }

    /// Best-effort FW_ABORT, then drop the op locally. Safe to call even if
    /// the write fails (e.g. the link is already down).
    private func abortFwUpload(reason: String) {
        guard case .uploadingFirmware = op else { return }
        _ = writeCmdBytes(Data([FileSyncProtocol.opFwAbort]))
        finishFwUpload(success: false, message: "firmware upload aborted (\(reason))")
    }

    /// Resolve the op and emit the terminal event exactly once.
    private func finishFwUpload(success: Bool, message: String) {
        guard case .uploadingFirmware = op else { return }
        op = .idle
        emit(.fwUploadDone(success: success, message: message))
    }

    private func handleFwNotify(_ value: Data) {
        guard case .uploadingFirmware(let image, let sha, let offset,
                                      let lastEmit, _, let phase, _) = op else { return }
        switch phase {
        case .begin:
            // FW_BEGIN reply: single status byte. 0x00 = bank erased, ready.
            guard let b = value.first else { return }
            if b == FileSyncProtocol.statusOK {
                emitStatus("bank erased — streaming firmware…")
                op = .uploadingFirmware(image: image, sha256: sha, offset: 0,
                                        lastEmit: 0, retries: 0, phase: .data,
                                        lastProgress: now())
                if !sendFwChunk() {
                    finishFwUpload(success: false, message: "not connected")
                }
            } else {
                finishFwUpload(success: false,
                               message: "FW_BEGIN: \(FileSyncProtocol.fwErrorMessage(b))")
            }

        case .data:
            // SUCCESS = 4-byte LE next-expected offset; ERROR = 1 byte.
            // Disambiguate purely by length.
            if value.count == 4 {
                var done = Int64(ackOffset(value))
                if done > Int64(image.count) { done = Int64(image.count) }
                // Coalesce progress emits to every `fwProgressChunkBytes`, but
                // ONLY advance the emit-watermark when we actually emit — else
                // `done - lastEmit` never accumulates and the bar sticks at 0 %
                // until the final byte (each chunk bumping lastEmit to `done`).
                var emitted = lastEmit
                if done - lastEmit >= Self.fwProgressChunkBytes || done >= Int64(image.count) {
                    emit(.fwUploadProgress(bytesDone: done, total: Int64(image.count)))
                    emitted = done
                }
                if done >= Int64(image.count) {
                    // Whole image staged — move to COMMIT.
                    op = .uploadingFirmware(image: image, sha256: sha, offset: done,
                                            lastEmit: done, retries: 0, phase: .commit,
                                            lastProgress: now())
                    sendFwCommit()
                } else {
                    op = .uploadingFirmware(image: image, sha256: sha, offset: done,
                                            lastEmit: emitted, retries: 0,
                                            phase: .data, lastProgress: now())
                    if !sendFwChunk() {
                        finishFwUpload(success: false, message: "not connected")
                    }
                }
            } else if let b = value.first {
                // 1-byte error: 0xE7 bad-seq / 0xE5 flash-fail are fatal.
                finishFwUpload(success: false,
                               message: "FW_DATA @\(offset): \(FileSyncProtocol.fwErrorMessage(b))")
            }

        case .commit:
            // FW_COMMIT reply: 0xA0 = ready (box reboots), else error.
            guard let b = value.first else { return }
            if b == FileSyncProtocol.fwReady {
                finishFwUpload(success: true,
                               message: "firmware accepted — box is rebooting")
            } else {
                finishFwUpload(success: false,
                               message: "FW_COMMIT: \(FileSyncProtocol.fwErrorMessage(b))")
            }
        }
    }

    /// Decode a 4-byte little-endian ACK offset from a FW_DATA reply.
    private func ackOffset(_ value: Data) -> UInt32 {
        var v: UInt32 = 0
        for (i, byte) in value.prefix(4).enumerated() {
            v |= UInt32(byte) << (8 * i)
        }
        return v
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
            if lastConnectedId != nil, reconnect == nil {
                // Auto-reconnect on ANY unexpected drop for a known box, not
                // just mid-READ. A lock-screen suspend can drop an *idle*
                // link; without this it would hard-disconnect straight to the
                // Connect screen. `armReconnect` is a no-op when
                // `lastConnectedId` is nil — a user-initiated Disconnect
                // clears it first (see `.disconnect`), so a deliberate
                // disconnect still ends cleanly instead of bouncing back. A
                // mid-READ partial is still preserved: `armReconnect` →
                // `disconnectInner(emitEvent: false)` emits `.readAborted`.
                armReconnect()
            } else if reconnect == nil {
                disconnectInner(emitEvent: true)
            }
            // else: a stray disconnect callback while already reconnecting
            // — tickReconnect owns the lifecycle, ignore.
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
                if ch.uuid == FileSyncProtocol.batteryUUID { battChar = ch }
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

        // BatteryStatus is optional (same soft-fail contract as SensorStream).
        // Subscribe for the ~1/min + on-transition notifies AND fire one
        // readValue so the meter isn't blank for up to a minute after connect.
        // The read reply arrives on the SAME didUpdateValueFor path as a notify.
        if let b = battChar, !battSubscribeKicked {
            battSubscribeKicked = true
            p.setNotifyValue(true, for: b)
            p.readValue(for: b)
        } else if battChar == nil {
            emitStatus("BatteryStatus characteristic not advertised — legacy firmware, battery meter will be empty")
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
                // Subscribe confirmed = we're back. Remember the box for
                // any future reconnect, and if a reconnect was running
                // clear it (success) — the `.connected` below drives the
                // VM's mirror-resume (desktop auto_reconnect success).
                lastConnectedId = peripheral?.identifier
                if reconnect != nil {
                    reconnect = nil
                    emitStatus("auto-reconnected — resuming transfer")
                }
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
        case FileSyncProtocol.batteryUUID:
            if let error = error {
                emitStatus("BatteryStatus subscribe failed (\(error.localizedDescription)) — battery meter will be empty")
            } else {
                emitStatus("BatteryStatus subscribed (~1/min)")
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
        if charUUID == FileSyncProtocol.batteryUUID {
            handleBatteryNotify(data)
            return
        }
        // GPS-bridge mode: FileData notifies carry raw u-blox UBX frames, not
        // FileSync payloads — divert them to the survey and never touch `op`.
        if bridgeActive {
            emit(.ubxFrame(data))
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
        case .modeReq:
            handleModeNotify(data)
        case .gpsPwrReq:
            handleGpsPwrNotify(data)
        case .gettingVersion:
            handleVersionNotify(data)
        case .calibrationReq:
            handleCalibrationNotify(data)
        case .uploadingFirmware:
            handleFwNotify(data)
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

    /// BatteryStatus notify/read handler — always a single 8-byte packet
    /// (well under any MTU, so no chunked path). Same handler for the
    /// on-connect one-shot READ result and the ~1/min notifies.
    private func handleBatteryNotify(_ bytes: Data) {
        if let b = BatterySample.parse(bytes) {
            emit(.battery(b))
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
        guard case .reading(let name, let expected, let base, var content, var lastEmit, _, let firstPacket) = op else { return }

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
        // `done` is the absolute byte position in the file: the resume
        // base plus what this segment has received. EOF is the box's
        // full size, not the segment length.
        let done = base + Int64(content.count)

        // Progress throttling: every ~4 KB or at EOF. BLE FileSync runs
        // ~1-3 KB/s so this updates the bar every 1-4 s.
        if done - lastEmit >= Self.progressChunkBytes || done >= expected {
            lastEmit = done
            emit(.readProgress(name: name, bytesDone: done))
        }

        if done >= expected {
            let take = Int(expected - base)
            let bytes = take >= 0 ? content.prefix(take) : content.prefix(0)
            emit(.readDone(name: name, content: Data(bytes), base: base))
            op = .idle
        } else {
            op = .reading(name: name, expected: expected, base: base, content: content,
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

    private func handleModeNotify(_ value: Data) {
        guard case .modeReq(let isSet, let manual, _) = op else { return }
        guard let b = value.first else { return }
        if isSet {
            // Reply is a status byte. OK ⇒ the box is now in `manual`.
            if b == FileSyncProtocol.statusOK {
                emit(.logMode(manual: manual))
                emitStatus("log mode set to \(manual ? "manual" : "auto")")
            } else {
                emitErr("SET_MODE: \(FileSyncProtocol.statusMessage(b)) " +
                    "(0x\(String(format: "%02X", b)))")
            }
        } else {
            // GET_MODE reply: 0 = auto, 1 = manual.
            emit(.logMode(manual: b != 0))
        }
        op = .idle
    }

    private func handleGpsPwrNotify(_ value: Data) {
        guard case .gpsPwrReq(let isSet, let on, _) = op else { return }
        guard let b = value.first else { return }
        if isSet {
            // Reply is a status byte. OK ⇒ the box is now in the requested state.
            if b == FileSyncProtocol.statusOK {
                emit(.gpsPower(on: on))
                emitStatus("GPS turned \(on ? "on" : "off")")
            } else {
                emitErr("GPS_POWER: \(FileSyncProtocol.statusMessage(b)) " +
                    "(0x\(String(format: "%02X", b)))")
            }
        } else {
            // GET reply: 0 = off, 1 = on.
            emit(.gpsPower(on: b != 0))
        }
        op = .idle
    }

    /// CAL_GET / CAL_SET reply — demuxed by the `.calibrationReq` op's
    /// `isSet`:
    /// - GET (0x13): expect a 32-byte blob → emit `.calibration(replyBytes)`.
    ///   Anything shorter/longer → treat as `nil` (a firmware bug or wire
    ///   desync) so a stray notify doesn't lock the op; the client falls back
    ///   to its local AgentConfig.
    /// - SET (0x14): expect a single status byte. 0x00 OK ⇒ re-emit
    ///   `.calibration(sentBlob)` with the just-pushed blob so the receiver
    ///   mirrors it as authoritative without a second GET round-trip.
    ///   Anything else surfaces as an error and the client keeps its
    ///   optimistic local update (the state on the box is unchanged).
    private func handleCalibrationNotify(_ value: Data) {
        guard case .calibrationReq(let isSet, let sent, _) = op else { return }
        if isSet {
            if let b = value.first {
                if b == FileSyncProtocol.statusOK {
                    emit(.calibration(sent))
                    let mask = sent.count >= 2 ? sent[sent.startIndex + 1] : 0
                    emitStatus(String(format: "CAL_SET OK (mask=0x%02X)", mask))
                } else {
                    let msg = FileSyncProtocol.statusMessage(b)
                    emitErr("CAL_SET: \(msg) (0x\(String(format: "%02X", b)))")
                }
            }
        } else {
            if value.count == 32 {
                emit(.calibration(value))
            } else {
                // Wire desync or firmware bug — treat like the timeout: the
                // client falls back to its local AgentConfig.
                emit(.calibration(nil))
            }
        }
        op = .idle
    }

    /// GET_VERSION reply: the firmware sends the ASCII version string with no
    /// NUL terminator, e.g. `"0.0.29"`. Decode UTF-8 and trim; an empty or
    /// garbled decode yields `nil` so a bad reply reads as "unknown" (→ offer
    /// update) rather than a bogus version. Mirrors the desktop `ble.rs`
    /// GettingVersion notify arm.
    private func handleVersionNotify(_ value: Data) {
        guard case .gettingVersion = op else { return }
        let v = String(decoding: value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        emit(.firmwareVersion(v.isEmpty ? nil : v))
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

    /// Begin a bounded auto-reconnect after an unexpected mid-transfer
    /// drop/stall (desktop `auto_reconnect`). Tears the half-dead link
    /// down *without* a public `.disconnected` (we intend to come back),
    /// then lets `tickReconnect` drive rescan→connect rounds. No-op if
    /// we never had a connected box or a reconnect is already running.
    private func armReconnect() {
        guard let id = lastConnectedId, reconnect == nil else { return }
        // Tell the VM the link is down BEFORE disconnectInner emits the
        // `.readAborted` + `.error` (which would otherwise pump the next
        // queued READ into the dead link and orphan its progress row).
        emit(.reconnecting)
        disconnectInner(emitEvent: false)
        reconnect = ReconnectState(id: id, attempt: 1, phase: .waiting,
                                   nextAtMs: now() + Self.reconnectWaitMs)
        emitStatus("link lost — auto-reconnecting (attempt 1/\(Self.reconnectAttempts))…")
    }

    /// One step of the reconnect state machine, called from the 200 ms
    /// tick. waiting → kick a refresh scan; scanning → stop scan + start
    /// a connect; connecting → time out and retry. Success is detected
    /// elsewhere (subscribe-confirmed clears `reconnect`).
    private func tickReconnect() {
        guard var rc = reconnect, now() >= rc.nextAtMs else { return }
        let n = now()
        switch rc.phase {
        case .waiting:
            central.scanForPeripherals(withServices: nil, options: nil)
            scanning = true
            rc.phase = .scanning
            rc.nextAtMs = n + Self.reconnectScanMs
            reconnect = rc
        case .scanning:
            if scanning { central.stopScan(); scanning = false }
            if let p = discovered[rc.id]
                ?? central.retrievePeripherals(withIdentifiers: [rc.id]).first {
                peripheral = p
                p.delegate = self
                central.connect(p, options: nil)
                rc.phase = .connecting
                rc.nextAtMs = n + Self.reconnectConnectMs
                reconnect = rc
            } else {
                failReconnectAttempt(&rc, n)
            }
        case .connecting:
            // Subscribe-confirmed would have cleared `reconnect`; we're
            // here so the attempt timed out. Drop and retry.
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil
            failReconnectAttempt(&rc, n)
        }
    }

    private func failReconnectAttempt(_ rc: inout ReconnectState, _ n: Int64) {
        rc.attempt += 1
        // Bounded only when Keep-synced is off. With Keep-synced on the
        // user has opted into mirror-everything-you-can, so we never
        // surrender — same regime as desktop's Auto Mode (v0.0.19).
        if !keepSyncedActive && rc.attempt > Self.reconnectAttempts {
            reconnect = nil
            emitStatus("auto-reconnect exhausted — reconnect manually")
            emit(.disconnected)
            return
        }
        rc.phase = .waiting
        rc.nextAtMs = n + Self.reconnectWaitMs
        reconnect = rc
        if keepSyncedActive {
            emitStatus("auto-reconnecting (attempt \(rc.attempt), keep-synced)…")
        } else {
            emitStatus("auto-reconnecting (attempt \(rc.attempt)/\(Self.reconnectAttempts))…")
        }
    }

    private func tickWatchdog() {
        tickReconnect()
        if reconnect != nil { return }
        let n = now()
        // LIST inactivity-done fallback: ≥1 row received and no new bytes for
        // LIST_INACTIVITY_DONE → assume we missed the terminator and finish.
        if case .listing(_, let lastProgress, let rowsSeen) = op,
           rowsSeen > 0, n - lastProgress > Self.listInactivityDoneMs {
            op = .idle
            emit(.listDone)
            return
        }
        // FW_DATA has a dedicated resend-on-timeout path (the box is
        // idempotent for offset < cursor) handled below, before the generic
        // stale handling. FW_BEGIN/COMMIT fall through to the generic timeout.
        if case .uploadingFirmware(_, _, _, _, _, let phase, let lp) = op,
           phase == .data, n - lp > Self.fwDataTimeoutMs {
            tickFwDataResend(n)
            return
        }
        let stale: Bool
        switch op {
        case .listing(_, let lp, _): stale = n - lp > Self.opIdleTimeoutMs
        case .reading(_, _, _, _, _, let lp, _): stale = n - lp > Self.opIdleTimeoutMs
        case .deleting(_, let lp): stale = n - lp > Self.opIdleTimeoutMs
        case .modeReq(_, _, let lp): stale = n - lp > Self.modeReqTimeoutMs
        case .gpsPwrReq(_, _, let lp): stale = n - lp > Self.modeReqTimeoutMs
        case .gettingVersion(let lp): stale = n - lp > Self.modeReqTimeoutMs
        case .calibrationReq(_, _, let lp): stale = n - lp > Self.modeReqTimeoutMs
        case .uploadingFirmware(_, _, _, _, _, _, let lp): stale = n - lp > Self.fwBeginCommitTimeoutMs
        case .idle: stale = false
        }
        guard stale else { return }
        var stalledRead = false
        switch op {
        case .listing: emitErr("LIST timed out — no notifies for 20 s")
        case .reading(let name, let expected, let base, let content, _, _, _):
            // Stalled (CB still thinks it's connected). Hand back the
            // partial so the resume continues from here, not the last
            // completed segment (desktop v0.0.12 tick_watchdog).
            emit(.readAborted(name: name, content: content, base: base))
            emitErr("READ \(name) timed out at \(base + Int64(content.count))/\(expected) B — no notifies for 20 s")
            stalledRead = true
        case .deleting(let name, _): emitErr("DELETE \(name) timed out — no notify for 20 s")
        case .modeReq(let isSet, _, _):
            emitErr("\(isSet ? "SET_MODE" : "GET_MODE") timed out — no reply for \(Self.modeReqTimeoutMs / 1000) s (firmware may not support this opcode)")
        case .gpsPwrReq(let isSet, _, _):
            emitErr("\(isSet ? "GPS_POWER" : "GPS_GET_POWER") timed out — no reply for \(Self.modeReqTimeoutMs / 1000) s (firmware may not support GPS on/off)")
        case .gettingVersion:
            // Legacy firmware (≤ v0.0.28) never replies to GET_VERSION. Emit
            // nil (unknown → the check offers the update) rather than an error:
            // a non-answer is expected legacy behaviour, not a fault. Never
            // reconnects — the link is fine.
            emit(.firmwareVersion(nil))
        case .calibrationReq(let isSet, _, _):
            // Legacy firmware (< v0.0.37) never replies to CAL_GET / CAL_SET.
            // Drop to Idle without reconnecting; on a GET-side timeout emit
            // `.calibration(nil)` so the client stops waiting and falls back
            // to its local AgentConfig. On a SET-side timeout stay silent —
            // the client keeps its optimistic local update, and re-sending
            // it later is a normal path (not an error to surface).
            if !isSet { emit(.calibration(nil)) }
        case .uploadingFirmware(_, _, let offset, _, _, let phase, _):
            // FW_BEGIN (bank erase can take ~1 s but not 30 s) or FW_COMMIT
            // (SHA pass) never answered. FW_DATA is resent above, not here.
            let what = phase == .begin ? "FW_BEGIN (bank erase)" : "FW_COMMIT (verify)"
            emit(.fwUploadDone(success: false,
                               message: "\(what) timed out at \(offset) B — no reply"))
        case .idle: break
        }
        op = .idle
        // Stalled READ with the box still nominally connected (the case
        // Peter hit — no formal disconnect). Tear the half-dead link
        // down ourselves and auto-reconnect so the mirror resume can
        // continue (desktop v0.0.12). Partial is already handed back.
        if stalledRead, lastConnectedId != nil, reconnect == nil {
            armReconnect()
        }
    }

    /// FW_DATA timed out (no ACK notify within `fwDataTimeoutMs`). The box is
    /// idempotent for an offset below its cursor, so re-sending the SAME chunk
    /// is safe. Bounded retries; exhaustion fails the upload (best-effort
    /// FW_ABORT so the box drops the stale staging).
    private func tickFwDataResend(_ n: Int64) {
        guard case .uploadingFirmware(let image, let sha, let offset, let lastEmit,
                                      let retries, .data, _) = op else { return }
        if retries >= Self.fwMaxRetries {
            abortFwUpload(reason: "no ACK after \(Self.fwMaxRetries) resends at \(offset) B")
            return
        }
        op = .uploadingFirmware(image: image, sha256: sha, offset: offset,
                                lastEmit: lastEmit, retries: retries + 1, phase: .data,
                                lastProgress: n)
        emitStatus("FW_DATA @\(offset) — no ACK, resending (\(retries + 1)/\(Self.fwMaxRetries))")
        if !sendFwChunk() {
            finishFwUpload(success: false, message: "not connected")
        }
    }

    // -------------------------------------------------------------------------
    //  Internal types
    // -------------------------------------------------------------------------

    private enum CurrentOp {
        case idle
        case listing(line: String, lastProgress: Int64, rowsSeen: Int)
        case reading(name: String, expected: Int64, base: Int64, content: Data,
                     lastEmit: Int64, lastProgress: Int64, firstPacket: Bool)
        case deleting(name: String, lastProgress: Int64)
        /// SET_MODE / GET_MODE: both get one FileData reply byte.
        /// `isSet` true = SET (reply is a status byte; on OK the box is
        /// now in `manual`), false = GET (reply is 0/1 = the mode).
        case modeReq(isSet: Bool, manual: Bool, lastProgress: Int64)
        /// GPS_POWER / GPS_GET_POWER: both get one FileData reply byte, exactly
        /// like `modeReq`. `isSet` true = SET (reply is a status byte; on OK the
        /// box is now `on`), false = GET (reply is 0/1 = the power state).
        case gpsPwrReq(isSet: Bool, on: Bool, lastProgress: Int64)
        /// CAL_GET (0x13) or CAL_SET (0x14) in flight — waiting for the FileData
        /// reply. `isSet` true = SET (reply is one status byte; on OK the box
        /// merged our blob into `CAL.CFG` and we re-emit `.calibration(blob)`
        /// with the just-pushed bytes as authoritative), false = GET (reply is
        /// the 32-byte blob → `.calibration(replyBytes)`). `blob` carries the
        /// sent bytes for the SET path so the reply handler can echo them back.
        case calibrationReq(isSet: Bool, blob: Data, lastProgress: Int64)
        /// GET_VERSION: the box replies with one FileData notify carrying the
        /// ASCII firmware version. Legacy firmware never answers → the watchdog
        /// times it out (same bound as GET_MODE) and emits
        /// `.firmwareVersion(nil)`. Never reconnects (the link is fine).
        case gettingVersion(lastProgress: Int64)
        /// Firmware OTA in flight. `offset` is the next byte to send (==
        /// the box's last ACK), `phase` tracks the FW_BEGIN → FW_DATA →
        /// FW_COMMIT handshake. ACK-gated: one chunk outstanding at a time,
        /// the next is only sent from the 4-byte ACK notify.
        case uploadingFirmware(image: Data, sha256: Data, offset: Int64,
                               lastEmit: Int64, retries: Int, phase: FwPhase,
                               lastProgress: Int64)
    }

    /// Stage of the firmware handshake the worker is awaiting a reply for.
    private enum FwPhase { case begin, data, commit }

    private func now() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // -------------------------------------------------------------------------
    //  Tunables
    // -------------------------------------------------------------------------

    /// CoreBluetooth restoration identifier. Stable across launches so iOS
    /// can hand back the same `[CBPeripheral]` set on relaunch. Reverse-DNS
    /// scoped to the app's bundle id to avoid collisions if a future binary
    /// adds a second central.
    private static let restoreIdentifier: String = "ch.pumptsueri.movementlogger.ble"

    private static let scanDurationMs: Int = 5_000
    private static let watchdogTickMs: Int = 200
    private static let opIdleTimeoutMs: Int64 = 20_000
    /// GET/SET_MODE is a single-byte reply that returns in well under a second
    /// when supported. Firmware that doesn't implement 0x07 never answers, so
    /// the connect-time GET_MODE would otherwise hold the single-op worker for
    /// the full 20 s — blocking the user's first `List files` with "another op
    /// is in flight". Time it out fast so the worker frees up and SET_TIME +
    /// LIST proceed within a few seconds of connect.
    private static let modeReqTimeoutMs: Int64 = 4_000
    private static let listInactivityDoneMs: Int64 = 500
    /// How long the box stays busy after SET_TIME (0x08) before it can
    /// service the next FileCmd. Measured ≥1.8 s works, ~0.5 s fails; 2 s
    /// gives margin for an SD flush. One-time per connect.
    private static let setTimeSettleMs: Int64 = 2_000
    // Auto-reconnect tunables.
    //
    // Two regimes (mirrors desktop v0.0.19): bounded when Keep-synced is
    // OFF (manual sync, give up after RECONNECT_ATTEMPTS so we don't
    // ratchet forever), *unbounded* when ON — the user explicitly opted
    // into "keep syncing whenever possible" and the box's firmware self-
    // heals across 20+ recovery cycles. Decided by `keepSyncedActive` on
    // `failReconnectAttempt`.
    //
    // `reconnectConnectMs` is 60 s on purpose: iOS holds the pending
    // `central.connect()` even while the app is suspended (lock screen,
    // background) and only fires `didConnect` when the peripheral
    // actually advertises again. The previous 10 s budget tripped a
    // false-timeout every wake — the worker's `Task.sleep` watchdog
    // doesn't run during suspension but `DispatchTime.now()` keeps
    // ticking, so by the time the worker resumes, the 10 s "deadline"
    // had elapsed and we cancelled a perfectly good pending connect.
    // 60 s + iOS event-driven wake = lock-screen-safe.
    private static let reconnectAttempts = 30
    private static let reconnectWaitMs: Int64 = 2_000
    private static let reconnectScanMs: Int64 = 3_000
    // 60 s was one slow cycle per failed attempt (~65 s with the wait+scan);
    // a brief RF drop where the box re-advertises in seconds then waited a
    // full minute to be retried. 18 s catches the box's connectable window
    // ~3× faster while still allowing for a box that takes a few seconds to
    // start advertising again after the link drops.
    private static let reconnectConnectMs: Int64 = 18_000

    /// `true` when the user has opted into Keep-synced (mirrored from
    /// `AgentConfig`). Drives the unbounded-vs-bounded reconnect choice.
    /// Read from `failReconnectAttempt` so a mid-loop toggle is honoured.
    private var keepSyncedActive: Bool {
        AgentConfig.keepSynced && AgentConfig.logModeManual != true
    }
    private static let progressChunkBytes: Int64 = 4 * 1024

    // Firmware-update tunables.
    /// Emit a progress event at most every ~512 B. The box's OTA ACK path is
    /// slow (~150 B/s on old firmware), so a coarse throttle would leave the
    /// bar visibly frozen for many seconds — keep the step small enough that
    /// each ACK-advance shows up.
    private static let fwProgressChunkBytes: Int64 = 512
    /// Per-FW_DATA ACK wait before a resend. Kept short: on old box firmware
    /// the ACK notify is occasionally *dropped* (not merely slow), and only a
    /// resend unsticks it — the whole transfer then paces at this timeout. A
    /// resend is idempotent (the box re-replies its current offset, never a
    /// bad-seq), so recovering a lost ACK in 1.5 s instead of 5 s roughly
    /// triples throughput on a flaky link. `fwMaxRetries` is raised to keep the
    /// same ~18 s total per-chunk tolerance before declaring the op dead.
    private static let fwDataTimeoutMs: Int64 = 1_500
    /// FW_BEGIN bank erase and FW_COMMIT SHA-pass can each take a few seconds;
    /// allow well over that before declaring the op dead.
    private static let fwBeginCommitTimeoutMs: Int64 = 15_000
    /// Resends of a single FW_DATA chunk before giving up. Paired with the
    /// 1.5 s `fwDataTimeoutMs` this is ~18 s of total per-chunk tolerance
    /// (matches the old 5 s × 5) so a genuine multi-second box stall still
    /// rides through without a false abort.
    private static let fwMaxRetries = 12
}

// MARK: - CBCentralManagerDelegate

extension BleClient: CBCentralManagerDelegate {
    /// iOS relaunched us with state for a previously-active peripheral.
    /// Called BEFORE `centralManagerDidUpdateState`. We adopt the restored
    /// `CBPeripheral` (re-attach our delegate, rebind characteristic refs)
    /// so a subsequent `didConnect` / notify lands on the same state
    /// machine the suspended worker had. If the peripheral is still
    /// connected, the next characteristic-value callback drives the op
    /// state machine directly; if disconnected, the foreground UI or BG
    /// agent can issue `.connect` against the same identifier.
    ///
    /// Restoration is best-effort: a missing characteristic just means we
    /// re-discover at the next connect, no functional change.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              !restored.isEmpty else { return }
        // Pick the first restored peripheral — we only ever maintain a
        // single connection in this app.
        let p = restored[0]
        p.delegate = self
        peripheral = p
        lastConnectedId = p.identifier
        discovered[p.identifier] = p
        for svc in (p.services ?? []) {
            for ch in (svc.characteristics ?? []) {
                if ch.uuid == FileSyncProtocol.fileCmdUUID { cmdChar = ch }
                if ch.uuid == FileSyncProtocol.fileDataUUID { dataChar = ch }
                if ch.uuid == FileSyncProtocol.streamUUID { streamChar = ch }
                if ch.uuid == FileSyncProtocol.batteryUUID { battChar = ch }
            }
        }
        // If we got the link back already connected (the usual case for
        // a wake-by-notify) re-emit `.connected` so the VM can react.
        // Otherwise wait for an explicit `.connect`. Keep this minimal —
        // the VM owns the resume logic via the existing event flow.
        if p.state == .connected, dataChar != nil {
            beginBackgroundAssertion()
            emit(.status("restored connection to \(p.identifier.uuidString)"))
            emit(.connected(boxId: p.identifier.uuidString))
        }
    }

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
        guard u == FileSyncProtocol.fileDataUUID || u == FileSyncProtocol.streamUUID
              || u == FileSyncProtocol.batteryUUID else { return }
        workerCont.yield(.raw(.notifyStateUpdated(charUUID: u, error: error)))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let u = characteristic.uuid
        guard u == FileSyncProtocol.fileDataUUID || u == FileSyncProtocol.streamUUID
              || u == FileSyncProtocol.batteryUUID,
              let value = characteristic.value else { return }
        workerCont.yield(.raw(.notification(charUUID: u, data: value)))
    }
}
