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
                    LogPanel(lines: vm.log)
                }
                .padding(16)
            }
            .navigationTitle("Movement Logger")
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
                    .disabled(vm.listing)
                    Button(action: vm.syncNow) {
                        Text(vm.syncing ? "Syncing…" : "Sync now")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.listing || vm.syncing)
                    Button("STOP_LOG", action: vm.stopLog)
                        .buttonStyle(.bordered)
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
                SessionStarter(vm: vm)
            }
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
                let sensor = vm.files.filter { isSensorData($0.name) }
                let debug = vm.files.filter { !isSensorData($0.name) }
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

    var body: some View {
        let progress = vm.downloads[file.name]
        let savedPath = vm.savedPaths[file.name]
        let deleteReason = deleteUnsupported(file.name)
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
                Button(progress == nil ? "Download" : "…") { vm.download(file) }
                    .buttonStyle(.bordered)
                    .disabled(progress != nil)
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
    }
}

// MARK: - Log panel

private struct LogPanel: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        Text("log").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .id(idx)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 180)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { _, newCount in
                if newCount > 0 {
                    withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) }
                }
            }
        }
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
