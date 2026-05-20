import SwiftUI
import CoreBluetooth

struct FileSyncScreen: View {
    /// Owned by `MainNav` so the Live tab can observe the same instance
    /// (shared SensorStream samples). When this screen is shown stand-alone
    /// in previews / tests, `MainNav` wraps it with a freshly-constructed
    /// view model.
    @Bindable var vm: FileSyncViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let s = vm.sessionRunning {
                        SessionBanner(running: s, onCleared: vm.clearSession)
                    }
                    ConnectionBar(vm: vm)
                    if vm.transferInterrupted && vm.connection != .connected {
                        TransferInterruptedBanner()
                    }
                    Divider()
                    content
                    Divider()
                    LogSection(logFileURL: vm.logFileURL)
                }
                .padding(16)
            }
            .navigationTitle("Movement Logger \(appVersionString())")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.connection {
        case .disconnected: DiscoveredList(vm: vm)
        case .connecting: CenteredSpinner(label: "connecting…")
        case .connected: FilesPanel(vm: vm)
        }
    }
}

// MARK: - Connection bar

private struct ConnectionBar: View {
    @Bindable var vm: FileSyncViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch vm.connection {
                case .disconnected:
                    Button(action: vm.scan) {
                        Text(vm.scanning ? "Scanning…" : "Scan for PumpTsueri")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.scanning)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("connecting…")
                case .connected:
                    Button(action: vm.listFiles) {
                        Text(vm.listing ? "Listing…" : "List files")
                    }
                    .buttonStyle(.borderedProminent)
                    // Disable while ANY worker op is in flight — keep-synced
                    // READs hold the worker busy for minutes on a big file,
                    // and tap-while-busy would just collide with the "another
                    // op is in flight" rejection.
                    .disabled(vm.listing || vm.syncing || !vm.downloads.isEmpty)
                    Button(action: vm.syncNow) {
                        Text(vm.syncing ? "Syncing…" : "Sync now")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.listing || vm.syncing || !vm.downloads.isEmpty)
                    // Disconnect is back so one person can sync, drop the
                    // link, and hand the box to the next person to sync.
                    // STOP_LOG stays removed: with the always-on firmware
                    // it would silently kill recording until a power-cycle.
                    Button("Disconnect", action: vm.disconnect)
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            if vm.connection == .connected {
                HStack {
                    Toggle(isOn: Binding(
                        get: { vm.keepSynced },
                        set: { vm.setKeepSynced($0) }
                    )) {
                        Text("Keep synced").font(.footnote)
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    Spacer()
                }
                if let status = vm.syncStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(vm.syncing ? Color.accentColor : .secondary)
                }
                // Show the current sync READ + the pass-position so the user
                // can tell that keep-synced IS working even while the file
                // list is empty. Cumulative byte-progress bar is the
                // headline number — per-file progress is the secondary row
                // below it.
                if vm.syncing {
                    SyncProgressRow(
                        currentName: vm.syncInFlight,
                        currentFileProgress: vm.syncInFlight.flatMap { vm.downloads[$0] },
                        completed: max(0, vm.syncPassTotal - vm.syncQueue.count - (vm.syncInFlight != nil ? 1 : 0)) + (vm.syncInFlight != nil ? 1 : 0),
                        total: vm.syncPassTotal,
                        bytesDone: vm.syncCumulativeBytes,
                        bytesTotal: vm.syncPassTotalBytes,
                        fraction: vm.syncCumulativeFraction)
                }
                LogModeSelector(vm: vm)
                if vm.logModeManual == true {
                    SessionStarter(vm: vm)
                }
            }
        }
    }
}

/// In-flight sync-pass progress.
///
/// Two layers of progress, headline first:
///   - Overall byte-progress bar (`bytesDone / bytesTotal`) — the
///     denominator includes every file's full size, the numerator is
///     completed files + the in-flight file's `bytesDone`. So the bar
///     tracks data actually pulled, not file-count.
///   - Current file row underneath: name + per-file %% + per-file
///     byte progress bar. Disappears between files (brief idle gap
///     between two queued READs).
private struct SyncProgressRow: View {
    let currentName: String?
    let currentFileProgress: DownloadProgress?
    let completed: Int
    let total: Int
    let bytesDone: Int64
    let bytesTotal: Int64
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(total > 0 ? "Syncing — \(completed) of \(total) files"
                                   : "Syncing — \(completed) files")
                        .font(.footnote.weight(.semibold))
                    Text("\(humanBytes(bytesDone)) / \(humanBytes(bytesTotal))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
            }
            ProgressView(value: fraction)
            if let name = currentName, let p = currentFileProgress {
                Divider().padding(.vertical, 2)
                HStack(spacing: 8) {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(humanBytes(p.bytesDone)) / \(humanBytes(p.total))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: p.fraction)
                    .tint(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Auto / Manual box log-mode. AUTO = the box opens a session on every
/// cold boot (data-safe default). MANUAL = it boots idle and only
/// records after Start session, for the chosen duration — the box can
/// then be powered yet not recording, so it's opt-in. `nil` = not yet
/// known (legacy firmware that ignores GET_MODE, or the reply hasn't
/// arrived); neither button is highlighted until the box answers.
private struct LogModeSelector: View {
    @Bindable var vm: FileSyncViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log mode").font(.footnote)
                Button {
                    vm.setLogMode(false)
                } label: { Text("Auto") }
                .buttonStyle(.bordered)
                .tint(vm.logModeManual == false ? .accentColor : .secondary)
                Button {
                    vm.setLogMode(true)
                } label: { Text("Manual") }
                .buttonStyle(.bordered)
                .tint(vm.logModeManual == true ? .accentColor : .secondary)
                Spacer()
            }
            Text(logModeHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var logModeHint: String {
        switch vm.logModeManual {
        case .some(false): return "Box records automatically on power-on."
        case .some(true):  return "Box stays idle on power-on — start a session below."
        case .none:        return "Querying box… (legacy firmware can't report this)"
        }
    }
}

private struct SessionStarter: View {
    @Bindable var vm: FileSyncViewModel
    // Local text state so partial edits ("18", "180", "1800") aren't clamped
    // back as the user types. Reseeds when the model value changes.
    @State private var text: String = ""

    var body: some View {
        HStack {
            TextField("Duration", text: $text)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onChange(of: text) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(5))
                    if filtered != newValue { text = filtered }
                    if let n = Int(filtered) { vm.setSessionDuration(n) }
                }
            Text("s · \(humanDuration(vm.sessionDurationSeconds))")
                .foregroundStyle(.secondary)
                .font(.footnote)
            Spacer()
            Button("Start session", action: vm.startSession)
                .buttonStyle(.borderedProminent)
                .disabled(!(1...86_400).contains(vm.sessionDurationSeconds))
        }
        .onAppear { if text.isEmpty { text = "\(vm.sessionDurationSeconds)" } }
    }
}

// MARK: - Session banner

private struct SessionBanner: View {
    let running: SessionRunning
    let onCleared: () -> Void
    @State private var now: Date = Date()

    var body: some View {
        let remaining = running.remaining(at: now)
        VStack(alignment: .leading, spacing: 4) {
            Text("LOG session running")
                .font(.headline)
            Text("\(formatRemaining(Int(remaining))) remaining of \(humanDuration(running.durationSeconds))")
                .font(.footnote)
            Text("Box is in LOG mode and invisible to Scan. Short-press the button on the box to abort early.")
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .task(id: running.startedAt) {
            while !Task.isCancelled {
                now = Date()
                if running.remaining(at: now) <= 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }
            onCleared()
        }
    }
}

// MARK: - Discovered list

private struct DiscoveredList: View {
    @Bindable var vm: FileSyncViewModel

    var body: some View {
        if vm.discovered.isEmpty {
            Text(vm.scanning ? "Scanning for PumpTsueri…" : "Tap Scan to look for the box.")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(vm.discovered) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.name).font(.headline)
                            Text("\(d.identifier.uuidString.prefix(8))…  ·  \(d.rssi) dBm")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") { vm.connect(d) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// MARK: - Files panel

private struct FilesPanel: View {
    @Bindable var vm: FileSyncViewModel

    var body: some View {
        VStack(spacing: 8) {
            if let err = vm.deleteError {
                DeleteErrorBanner(message: err) { vm.deleteError = nil }
            }
            if vm.files.isEmpty && !vm.listing {
                Text("Connected. Tap List files to see SD-card contents.")
                    .foregroundStyle(.secondary)
            } else if vm.listing && vm.files.isEmpty {
                CenteredSpinner(label: "listing files…")
            } else {
                // Newest first: the per-session counter in the name
                // (SensNNN.csv) is the recency proxy — higher = later.
                let sensor = vm.files.filter { isSensorData($0.name) }
                    .sorted { recencyKey($0.name) > recencyKey($1.name) }
                let debug = vm.files.filter { !isSensorData($0.name) }
                    .sorted { recencyKey($0.name) > recencyKey($1.name) }
                if !sensor.isEmpty {
                    GroupHeader(title: "Sensor", count: sensor.count)
                    ForEach(sensor) { FileRow(file: $0, vm: vm) }
                }
                if !debug.isEmpty {
                    GroupHeader(title: "Debug", count: debug.count)
                    ForEach(debug) { FileRow(file: $0, vm: vm) }
                }
            }
        }
    }
}

/// Amber banner shown while disconnected after a transfer was cut by a
/// link drop / stall. Port of the desktop v0.0.9 resume banner — the
/// partial is already safe in the mirror, so reconnecting resumes
/// automatically and skips every file already complete.
private struct TransferInterruptedBanner: View {
    var body: some View {
        Text("⚠ Transfer interrupted (BLE link lost). Scan and reconnect "
             + "to the same box — the sync resumes automatically and "
             + "skips files already saved.")
            .font(.footnote)
            .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(red: 1.0, green: 0.95, blue: 0.80),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(red: 0.85, green: 0.65, blue: 0.20), lineWidth: 1))
    }
}

/// Prominent dismissable banner for a DELETE the box rejected (BUSY /
/// NOT_FOUND / IO_ERROR / BAD_REQUEST). Port of the desktop's
/// `ble_delete_err` frame (v0.0.10) — without it a rejected delete only
/// shows in the log and looks like the tap did nothing.
private struct DeleteErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("⚠ \(message)")
                .font(.footnote)
                .foregroundStyle(Color(red: 0.67, green: 0.12, blue: 0.12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: onDismiss)
                .font(.footnote)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color(red: 1.0, green: 0.90, blue: 0.90),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 0.78, green: 0.31, blue: 0.31), lineWidth: 1))
    }
}

private struct GroupHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.bold))
            Text("(\(count))").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
    }
}

private struct FileRow: View {
    let file: RemoteFile
    @Bindable var vm: FileSyncViewModel
    @State private var viewing: Bool = false

    var body: some View {
        let progress = vm.downloads[file.name]
        let savedPath = vm.savedPaths[file.name]
        let deleteReason = deleteUnsupported(file.name)
        // Fully downloaded = local mirror has at least the box's size.
        let downloaded = file.size > 0 && (vm.localBytes[file.name] ?? 0) >= file.size
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(file.name).font(.headline)
                    Text(humanBytes(file.size)).font(.footnote).foregroundStyle(.secondary)
                    if let path = savedPath {
                        Text("saved → \(path)")
                            .font(.footnote)
                            .foregroundStyle(.tint)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if downloaded && progress == nil {
                    // Opens the same kind of sheet as the global Log button —
                    // text preview inline (CSV/log) with a Share button so
                    // the file can be exported to Files / Mail / AirDrop.
                    Button {
                        viewing = true
                    } label: {
                        Label("View", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(progress == nil ? "Download" : "…") { vm.download(file) }
                        .buttonStyle(.bordered)
                        .disabled(progress != nil)
                }
                Button("Delete") { vm.delete(file) }
                    .buttonStyle(.bordered)
                    .disabled(progress != nil || deleteReason != nil)
            }
            if let reason = deleteReason {
                Text("Can't delete: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let p = progress {
                ProgressView(value: p.fraction)
                Text("\(humanBytes(p.bytesDone)) / \(humanBytes(p.total)) (\(Int(p.fraction * 100))%)")
                    .font(.footnote)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $viewing) {
            DownloadedFileViewer(url: documentsURL(file.name))
        }
    }

    private func documentsURL(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent(name)
    }
}

/// Sheet shown when the user taps "View" on a fully-downloaded file in
/// the Sync tab. Text-shaped files (CSV / WAV header / etc.) get an
/// inline preview capped at ~256 KB; everything else falls back to a
/// summary + Share. The ShareLink in the toolbar always exports the
/// real file so AirDrop / Mail / Files all work regardless of the
/// content type. Mirrors `LogFileViewer` below.
private struct DownloadedFileViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var preview: String = ""
    @State private var isText: Bool = false
    @State private var fileSize: Int64 = 0
    @State private var truncated: Bool = false
    @State private var loading: Bool = true

    /// SwiftUI `Text` lays out the whole string at once and gets
    /// noticeably laggy past ~50 KB of monospaced content. A megabyte
    /// CSV stutters for seconds. Cap the preview tight — the Share
    /// button handles "I want the whole thing" cleanly.
    private static let previewCap: Int = 48 * 1024

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(32)
                } else if !isText {
                    Text("(binary file — \(humanBytes(fileSize)). Use the share button to export.)")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    if truncated {
                        Text("Showing first \(humanBytes(Int64(Self.previewCap))) of \(humanBytes(fileSize)) — use Share for the full file.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                    }
                    Text(preview.isEmpty ? "(empty file)" : preview)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        ShareLink(item: url)
                    }
                }
            }
            .task { await loadAsync() }
        }
    }

    /// Read + decode on a background queue so the sheet opens
    /// immediately. The `@State` writes flip back onto the main actor
    /// at the await boundary.
    private func loadAsync() async {
        let cap = Self.previewCap
        let result: (Int64, String, Bool, Bool) = await Task.detached(priority: .userInitiated) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard let h = try? FileHandle(forReadingFrom: url) else {
                return (size, "", false, false)
            }
            defer { try? h.close() }
            let bytes = (try? h.read(upToCount: cap)) ?? Data()
            let didTruncate = Int64(bytes.count) < size
            if !bytes.contains(0x00), let s = String(data: bytes, encoding: .utf8) {
                return (size, s, true, didTruncate)
            }
            return (size, "", false, false)
        }.value
        fileSize = result.0
        preview = result.1
        isText = result.2
        truncated = result.3
        loading = false
    }
}

// MARK: - Log

/// Replaces the always-on 180 pt panel with a single "Log" button. The
/// full transcript is written to `movement_logger.log` regardless;
/// tapping the button opens that file in a viewer sheet (with a Share
/// button to export it to Files / Mail / AirDrop).
private struct LogSection: View {
    let logFileURL: URL
    @State private var showing = false

    var body: some View {
        HStack {
            Button {
                showing = true
            } label: {
                Label("Log", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            Spacer()
            Text("→ movement_logger.log")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .sheet(isPresented: $showing) {
            LogFileViewer(url: logFileURL)
        }
    }
}

/// Reads the on-disk log file and shows it scrollable + monospaced.
/// Re-reads on each appearance so it reflects the latest lines. A
/// ShareLink exports the actual file.
private struct LogFileViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "(log file is empty — connect to a box to generate entries)" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("end")
                }
                .onAppear { reload(); proxy.scrollTo("end", anchor: .bottom) }
            }
            .navigationTitle("movement_logger.log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        ShareLink(item: url)
                    }
                }
            }
        }
    }

    private func reload() {
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - Helpers

private struct CenteredSpinner: View {
    let label: String
    var body: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Text(label)
            Spacer()
        }
        .padding(16)
    }
}

/// Recency rank for the file list: the trailing per-session counter in
/// `SensNNN.csv` / `GpsNNN.csv` / … — higher = later session = shown
/// first. Names without a number sort last (-1).
private func recencyKey(_ name: String) -> Int {
    var cur = "", last = ""
    for ch in name {
        if ch.isNumber { cur.append(ch) }
        else { if !cur.isEmpty { last = cur; cur = "" } }
    }
    if !cur.isEmpty { last = cur }
    return Int(last) ?? -1
}

/// Per-session sensor-data files the firmware writes: Sens*.csv, Gps*.csv,
/// Bat*.csv, Mic*.wav. Everything else (notably DebugX.csv) lands in the
/// Debug group. Matches `is_sensor_data_name` in stbox-viz-gui/src/main.rs.
///
/// macOS AppleDouble sidecars (`._<name>`) match the inner pattern by accident
/// — guard the prefix explicitly.
private func isSensorData(_ name: String) -> Bool {
    let n = name.lowercased()
    if n.hasPrefix("._") { return false }
    return (n.hasPrefix("sens") && n.hasSuffix(".csv")) ||
           (n.hasPrefix("gps")  && n.hasSuffix(".csv")) ||
           (n.hasPrefix("bat")  && n.hasSuffix(".csv")) ||
           (n.hasPrefix("mic")  && n.hasSuffix(".wav"))
}

/// Rows the box firmware can *never* delete — return the reason so the
/// trash button can be disabled with an explanation instead of looking
/// like a silent no-op. Port of the desktop's `delete_unsupported`
/// (movement_logger_desktop v0.0.10 / issue #7): `ble.c` caps DELETE
/// names at 15 bytes (longer ⇒ BAD_REQUEST) and `SDFat_Delete` only
/// matches a real FAT 8.3 short name, so `._*` AppleDouble sidecars and
/// the virtual `PUMPTSUE.RI` placeholder always come back NOT_FOUND.
private func deleteUnsupported(_ name: String) -> String? {
    if name.hasPrefix("._") {
        return "macOS metadata sidecar — not a real file on the box's SD card"
    } else if name.caseInsensitiveCompare("PUMPTSUE.RI") == .orderedSame {
        return "virtual placeholder entry — nothing to delete"
    } else if name.utf8.count > 15 {
        return "filename too long for the box's delete command (15-char firmware cap)"
    }
    return nil
}

/// "v<short> (<build>)" from the bundle so the header shows exactly
/// which build is installed — mirrors Android's title suffix.
private func appVersionString() -> String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "v\(short) (\(build))"
}

private func humanBytes(_ b: Int64) -> String {
    if b < 1024 { return "\(b) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024.0) }
    return String(format: "%.2f MB", Double(b) / (1024.0 * 1024.0))
}

private func humanDuration(_ secs: Int) -> String {
    let h = secs / 3600
    let m = (secs / 60) % 60
    let s = secs % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0          { return "\(h)h" }
    if m > 0 && s > 0 { return "\(m)m \(s)s" }
    if m > 0          { return "\(m)m" }
    return "\(s)s"
}

private func formatRemaining(_ secs: Int) -> String {
    let h = secs / 3600
    let m = (secs / 60) % 60
    let s = secs % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}
