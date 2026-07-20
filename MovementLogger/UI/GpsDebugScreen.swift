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
                    // Live RF health straight from the SensorStream (firmware
                    // v0.0.55+; no survey needed): C/N0 max plus Peter's
                    // assembly metrics — fix type, sats used, top-6
                    // GPS+Galileo C/N0 and the MON-RF EMI set. Moved here
                    // from the Live tab: all GPS debugging lives on this tab.
                    if connected {
                        liveRfCard
                    }
                    controls
                    if let latest = vm.gps.log.last, vm.gps.running {
                        summaryCard(latest)
                    }
                    if let p = vm.gps.epochCsvPath {
                        filesCard(epoch: p, signals: vm.gps.signalsCsvPath,
                                  spectrum: vm.gps.spectrumCsvPath)
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

    // MARK: - Live RF (SensorStream) — moved from the Live tab

    // GPS RF-extension palette — matches Android `GpsRfRows` exactly
    // (0xFF2E7D32 / 0xFFB58B00 / 0xFFD32F2F / 0xFF888888).
    private var rfGreen: Color { Color(red: 0x2E / 255.0, green: 0x7D / 255.0, blue: 0x32 / 255.0) }
    private var rfYellow: Color { Color(red: 0xB5 / 255.0, green: 0x8B / 255.0, blue: 0x00 / 255.0) }
    private var rfRed: Color { Color(red: 0xD3 / 255.0, green: 0x2F / 255.0, blue: 0x2F / 255.0) }
    private var rfGray: Color { Color(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0) }

    /// Live RF health from the 0.5 Hz SensorStream: "GPS C/N0" (strongest
    /// single satellite), "GPS RF" (fix type, sats used, top-6 GPS+Galileo
    /// C/N0 avg/min/max) and "GPS EMI" (MON-RF noise/agc, jamming state,
    /// antenna supervisor). `rf == nil` (legacy 46-byte packets, firmware
    /// < v0.0.55) hides the two RF rows.
    private var liveRfCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live RF (SensorStream)").font(.caption).foregroundStyle(.secondary)
            if let s = vm.live.latestSample {
                HStack(alignment: .firstTextBaseline) {
                    rfLabel("GPS C/N0")
                    HStack(spacing: 12) {
                        Text(s.gpsCn0Max > 0 ? "\(s.gpsCn0Max) dB-Hz max" : "—")
                            .font(.system(size: 13, design: .monospaced))
                        Text(s.gpsCn0Max == 0 ? "no GSV / no data"
                             : (s.gpsCn0Max >= 40 ? "good antenna"
                             : (s.gpsCn0Max >= 30 ? "ok" : "weak signal")))
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let rf = s.rf {
                    gpsRfRow(rf)
                    gpsEmiRow(rf)
                }
            } else {
                Text("Waiting for first SensorStream notify…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func rfLabel(_ text: String) -> some View {
        Text(text)
            .fontWeight(.semibold)
            .frame(width: 84, alignment: .leading)
    }

    /// "GPS RF": fix type + sats used, top-6 GPS+Galileo C/N0 avg/min/max
    /// (yellow "no C/N0 data" when avg6 == 0).
    private func gpsRfRow(_ rf: GpsRfLive) -> some View {
        let fixName: String
        switch rf.fixType {
        case 0: fixName = "no fix"
        case 2: fixName = "2D"
        case 3: fixName = "3D"
        case 4: fixName = "3D+DR"
        case 5: fixName = "time"
        default: fixName = "?"
        }
        return HStack(alignment: .firstTextBaseline) {
            rfLabel("GPS RF")
            HStack(spacing: 12) {
                Text("fix \(fixName) · \(rf.usedSv) used")
                    .font(.system(size: 13, design: .monospaced))
                if rf.avg6X10 > 0 {
                    Text(String(format: "avg6 %.1f / min %d / max %d dB-Hz",
                                Double(rf.avg6X10) / 10.0, Int(rf.min6), Int(rf.max6)))
                        .font(.system(size: 13, design: .monospaced))
                } else {
                    Text("no C/N0 data")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(rfYellow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "GPS EMI": MON-RF noise/agc, jamming state, antenna supervisor —
    /// jam ok green / warn yellow / CRIT red; ant SHORT/OPEN red. Gray
    /// "no MON-RF reply" when the fresh flag (bit 3) is off.
    private func gpsEmiRow(_ rf: GpsRfLive) -> some View {
        let jam: (text: String, color: Color)
        switch rf.jamState {
        case 1: jam = ("jam ok", rfGreen)
        case 2: jam = ("jam warn", rfYellow)
        case 3: jam = ("jam CRIT", rfRed)
        default: jam = ("jam ?", rfGray)
        }
        let ant: (text: String, color: Color)
        switch rf.antStatus {
        case 2: ant = ("ant ok", rfGreen)
        case 3: ant = ("ant SHORT", rfRed)
        case 4: ant = ("ant OPEN", rfRed)
        default: ant = ("ant ?", rfGray)
        }
        return HStack(alignment: .firstTextBaseline) {
            rfLabel("GPS EMI")
            if rf.fresh {
                HStack(spacing: 12) {
                    Text("noise \(rf.noisePerMs) · agc \(rf.agcCnt)")
                        .font(.system(size: 13, design: .monospaced))
                    Text("\(jam.text) (ind \(rf.jamInd))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(jam.color)
                    Text(ant.text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(ant.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("no MON-RF reply (module quiet)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(rfGray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    private func filesCard(epoch: String, signals: String?, spectrum: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CSV output (Files app → On My iPhone → Movement Logger)")
                .font(.caption).foregroundStyle(.secondary)
            GpsOutputFileRow(path: epoch)
            if let signals {
                GpsOutputFileRow(path: signals)
            }
            if let spectrum {
                GpsOutputFileRow(path: spectrum)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// One CSV output file: filename + a **View** button (opens the same
/// `DownloadedFileViewer` sheet the Sync tab's sensor files use) and a
/// **Share** button (system share sheet). Both work mid-survey — the file is
/// written incrementally, so View/Share reflect whatever's on disk so far.
private struct GpsOutputFileRow: View {
    let path: String
    @State private var viewing = false

    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        HStack(spacing: 8) {
            Text((path as NSString).lastPathComponent)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewing = true
            } label: {
                Label("View", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .sheet(isPresented: $viewing) {
            DownloadedFileViewer(url: url)
        }
    }
}
