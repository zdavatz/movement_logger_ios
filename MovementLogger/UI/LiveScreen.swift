import SwiftUI

/// Live tab — renders the most recent SensorStream snapshot at 0.5 Hz.
///
/// Mirrors `LiveScreen.kt` on Android and `ui_live_tab` in the desktop
/// `stbox-viz-gui/src/main.rs`: status strip, six-row readout grid (Accel /
/// Gyro / Mag / Baro / GPS / GPS aux / Flags), two Canvas sparklines (acc
/// magnitude, pressure). Gated on already being connected via the Sync tab —
/// Connect involves a scan + device-pick flow that doesn't fit nicely above
/// a 6-row readout.
struct LiveScreen: View {
    @Bindable var vm: FileSyncViewModel
    let onGoToSync: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SensorStream — 0.5 Hz packed all-sensor snapshot (IMU + mag + baro + GPS).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if vm.connection != .connected {
                        notConnectedView
                    } else {
                        FreshnessStrip(live: vm.live)
                        Divider()
                        if let sample = vm.live.latestSample {
                            ReadoutGrid(sample: sample)
                            Spacer().frame(height: 8)
                            Text("Acc magnitude (g)").font(.subheadline).fontWeight(.semibold)
                            Sparkline(points: vm.live.accHistory,
                                      color: Color(red: 0.31, green: 0.71, blue: 0.98),
                                      yMin: 0.5, yMax: 1.5)
                            Spacer().frame(height: 8)
                            Text("Pressure (hPa)").font(.subheadline).fontWeight(.semibold)
                            Sparkline(points: vm.live.pressureHistory,
                                      color: Color(red: 0.98, green: 0.71, blue: 0.31),
                                      yMin: 980, yMax: 1030)
                        } else {
                            Text("Waiting for first SensorStream notify…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var notConnectedView: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("Not connected.").fontWeight(.semibold).font(.title3)
            Text("Open the Sync tab, run Scan, and Connect to a box (PIN 123456). " +
                 "The live stream starts automatically — no extra button needed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: onGoToSync) { Text("Go to Sync") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

// MARK: - Status strip

/// "N samples received" + "X ms / s ago" freshness label. A 250 ms timer
/// drives recomposition so the "ago" text keeps moving between the 2-second
/// sample arrivals.
private struct FreshnessStrip: View {
    let live: LiveState
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text("\(live.sampleCount) samples received").font(.subheadline)
            Spacer()
            label
        }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private var label: some View {
        if let t = live.latestSampleAt {
            let elapsed = now.timeIntervalSince(t)
            if elapsed < 5 {
                Text("last sample \(Int(elapsed * 1000)) ms ago")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("no sample for \(Int(elapsed)) s — check connection")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("waiting for first SensorStream notify…")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Readout grid

private struct ReadoutGrid: View {
    let sample: LiveSample

    var body: some View {
        let s = sample
        let presHpa = Double(s.pressurePa) / 100.0
        let tempC = Double(s.temperatureCc) / 100.0

        VStack(alignment: .leading, spacing: 6) {
            ReadoutRow(label: "Accel (g)",
                       a: String(format: "X %+.3f", Double(s.accMg.0) / 1000),
                       b: String(format: "Y %+.3f", Double(s.accMg.1) / 1000),
                       c: String(format: "Z %+.3f", Double(s.accMg.2) / 1000))
            ReadoutRow(label: "Gyro (°/s)",
                       a: String(format: "X %+.2f", Double(s.gyroCdps.0) / 100),
                       b: String(format: "Y %+.2f", Double(s.gyroCdps.1) / 100),
                       c: String(format: "Z %+.2f", Double(s.gyroCdps.2) / 100))
            ReadoutRow(label: "Mag (mG)",
                       a: String(format: "X %+d", Int(s.magMg.0)),
                       b: String(format: "Y %+d", Int(s.magMg.1)),
                       c: String(format: "Z %+d", Int(s.magMg.2)))
            ReadoutRow(label: "Angles (°)",
                       a: String(format: "Roll %+6.1f", s.rollDeg()),
                       b: String(format: "Pitch %+6.1f", s.pitchDeg()),
                       c: String(format: "Yaw %5.1f", s.headingDeg()))
            let accA = s.accAxisAnglesDeg()
            ReadoutRow(label: "Acc∠grav (°)",
                       a: String(format: "X %5.1f", accA.0),
                       b: String(format: "Y %5.1f", accA.1),
                       c: String(format: "Z %5.1f", accA.2))
            let magA = s.magAxisAnglesDeg()
            ReadoutRow(label: "Mag∠field (°)",
                       a: String(format: "X %5.1f", magA.0),
                       b: String(format: "Y %5.1f", magA.1),
                       c: String(format: "Z %5.1f", magA.2))
            ReadoutRow(label: "Mag dir (°)",
                       a: String(format: "Head %5.1f", s.magHeadingRawDeg()),
                       b: String(format: "Dip %+5.1f", s.magDipDeg()),
                       c: "")
            ReadoutRow(label: "Baro",
                       a: String(format: "%.2f hPa", presHpa),
                       b: String(format: "%+.2f °C", tempC),
                       c: "")
            if let ll = s.latLonDeg() {
                ReadoutRow(label: "GPS",
                           a: String(format: "%.6f°", ll.0),
                           b: String(format: "%.6f°", ll.1),
                           c: "\(s.gpsAltM) m")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    label("GPS")
                    Text("no fix").foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ReadoutRow(label: "GPS aux",
                       a: "\(s.gpsNsat) sats",
                       b: "fix-q \(s.gpsFixQ)",
                       c: String(format: "%.2f km/h  (%.1f°)",
                                 Double(s.gpsSpeedCmh) / 100,
                                 Double(s.gpsCourseCdeg) / 100))
            HStack(alignment: .firstTextBaseline) {
                label("Flags")
                HStack(spacing: 12) {
                    flagChip("gps_valid", on: s.gpsValid)
                    flagChip("logging", on: s.loggingActive)
                    flagChip("low_batt", on: s.lowBattery)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .fontWeight(.semibold)
            .frame(width: 104, alignment: .leading)
    }

    private func flagChip(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(on ? .semibold : .regular)
            .foregroundStyle(on ? Color.green : Color.gray)
    }
}

private struct ReadoutRow: View {
    let label: String
    let a: String
    let b: String
    let c: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).fontWeight(.semibold).frame(width: 104, alignment: .leading)
            Text(a).font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(b).font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(c).font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sparkline

/// Bare polyline. Y is clamped to `[yMin, yMax]`; X auto-scales to the
/// current point set so the line drifts left as new samples arrive (matches
/// the desktop `draw_sparkline`).
private struct Sparkline: View {
    let points: [LivePoint]
    let color: Color
    let yMin: Double
    let yMax: Double

    var body: some View {
        Canvas { ctx, size in
            // Subtle baseline so an empty panel doesn't look broken.
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(uiColor: .tertiarySystemFill))
            )
            guard points.count >= 2 else { return }
            let tMin = points.first!.tSec
            let tMax = points.last!.tSec
            let dt = max(tMax - tMin, 1e-9)
            let dy = max(yMax - yMin, 1e-9)
            var path = Path()
            for (i, p) in points.enumerated() {
                let x = CGFloat((p.tSec - tMin) / dt) * size.width
                let ny = min(max((p.value - yMin) / dy, 0), 1)
                let y = size.height - CGFloat(ny) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(color), lineWidth: 2)
        }
        .frame(height: 56)
    }
}
