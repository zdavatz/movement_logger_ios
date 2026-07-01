import SwiftUI

/// GPS Debug — live u-blox UBX diagnostics tunnelled over the box's BLE link
/// (no cable). Matches the desktop app's "GPS Debug" tab: fix quality, per-
/// signal C/N0, and RF/antenna health, for antenna selection + mounting.
/// Polls the receiver once a second; it never reconfigures it persistently.
struct GpsDebugScreen: View {
    let vm: FileSyncViewModel

    private var connected: Bool { vm.connection == .connected }
    /// Explicit binding into the nested @Observable survey model (can't use
    /// `$vm.gps.label` through the `let gps` reference).
    private var labelBinding: Binding<String> {
        Binding(get: { vm.gps.label }, set: { vm.gps.label = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    controls
                    if let latest = vm.gps.log.last, vm.gps.running {
                        summaryCard(latest)
                    }
                    logCard
                    if let p = vm.gps.epochCsvPath {
                        filesCard(epoch: p, signals: vm.gps.signalsCsvPath)
                    }
                }
                .padding()
            }
            .navigationTitle("GPS Debug")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live u-blox UBX diagnostics over BLE (no cable) — fix quality, per-signal C/N0, and RF/antenna health for antenna selection + mounting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(connected ? "Box connected" : "Not connected — connect on the Sync tab first")
                    .font(.footnote)
                    .foregroundStyle(connected ? .primary : .secondary)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Label")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("antenna", text: labelBinding)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(vm.gps.running)
            }
            HStack(spacing: 12) {
                if vm.gps.running {
                    Button(role: .destructive) { vm.stopGpsDebug() } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    ProgressView().controlSize(.small)
                    Text("polling… \(vm.gps.epochCount) epoch\(vm.gps.epochCount == 1 ? "" : "s")")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button { vm.startGpsDebug() } label: {
                        Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected)
                }
            }
            Text("BLE: connect the box on the Sync tab, then Start — the survey tunnels the u-blox over the box's link. Needs box firmware v0.0.17+ (the GPS-bridge opcode); on older firmware it just shows \u{201C}no NAV-PVT reply\u{201D}.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryCard(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Latest epoch").font(.caption).foregroundStyle(.secondary)
            Text(line)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Survey log").font(.caption).foregroundStyle(.secondary)
            if vm.gps.log.isEmpty {
                Text("No output yet. Start a survey to poll the receiver.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                // Newest last; show the tail.
                ForEach(Array(vm.gps.log.suffix(40).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(line.hasPrefix("(no NAV-PVT") ? Color.orange : Color.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func filesCard(epoch: String, signals: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CSV output (Files app → On My iPhone → Movement Logger)")
                .font(.caption).foregroundStyle(.secondary)
            Text((epoch as NSString).lastPathComponent)
                .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            if let signals {
                Text((signals as NSString).lastPathComponent)
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
