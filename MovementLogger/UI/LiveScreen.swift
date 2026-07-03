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
    /// Compass hard-iron offset (mG) — loaded once, refreshed by the
    /// "Calibrate compass" flow in `OrientationSection`.
    @State private var magOffset: [Double]? = AgentConfig.magOffsetMg

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
                            ReadoutGrid(sample: sample, magOffset: magOffset)
                            Spacer().frame(height: 8)
                            OrientationSection(live: vm.live, sample: sample,
                                               magOffset: $magOffset)
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
    let magOffset: [Double]?

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
                       c: String(format: "Yaw %5.1f", s.headingDeg(magOffMg: magOffset)))
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
            ReadoutRow(label: "GPS C/N0",
                       a: s.gpsCn0Max > 0 ? "\(s.gpsCn0Max) dB-Hz max" : "—",
                       b: (s.gpsCn0Max == 0 ? "no GSV / no data"
                           : (s.gpsCn0Max >= 40 ? "good antenna"
                           : (s.gpsCn0Max >= 30 ? "ok" : "weak signal"))),
                       c: "")
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

// MARK: - Box orientation (desktop v0.0.47 parity)

/// "Box orientation" section: calibrate button + stored hard-iron offset +
/// how-to text + the rotating 3D wireframe. Calibration collects per-axis
/// mag min/max for 30 s while the user tumbles the box; the midpoints
/// become the offset (persisted via `AgentConfig.magOffsetMg`).
private struct OrientationSection: View {
    let live: LiveState
    let sample: LiveSample
    @Binding var magOffset: [Double]?

    @State private var calUntil: Date? = nil
    @State private var calMin: [Double] = [.infinity, .infinity, .infinity]
    @State private var calMax: [Double] = [-.infinity, -.infinity, -.infinity]
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private static let howToCalibrate = """
        How to calibrate: tap the button, then rotate the box slowly flat on \
        the table through one full circle — pause about 3 s per quarter turn \
        (the box sends one sample every 2 s). Then briefly tip it on its nose \
        and on its side. The offset is stored and survives restarts. Calibrate \
        away from laptops, speakers and steel surfaces; re-calibrate if the \
        arrow stops following the rotation.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Box orientation").font(.subheadline).fontWeight(.semibold)
                if let until = calUntil {
                    let left = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
                    Text("calibrating — tumble the box… \(left)s")
                        .font(.subheadline).foregroundStyle(.orange)
                } else {
                    Button("Calibrate compass (30 s)") {
                        calMin = [.infinity, .infinity, .infinity]
                        calMax = [-.infinity, -.infinity, -.infinity]
                        calUntil = Date().addingTimeInterval(30)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if calUntil == nil, let off = magOffset {
                Text(String(format: "offset [%+.0f %+.0f %+.0f] mG", off[0], off[1], off[2]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.howToCalibrate)
                .font(.subheadline).foregroundStyle(.secondary)
            OrientationBoxCanvas(pitchDeg: sample.pitchDeg(),
                                 rollDeg: sample.rollDeg(),
                                 headingDeg: sample.headingDeg(magOffMg: magOffset))
        }
        .onReceive(tick) { t in
            now = t
            if let until = calUntil, t >= until {
                let off = [(calMin[0] + calMax[0]) / 2,
                           (calMin[1] + calMax[1]) / 2,
                           (calMin[2] + calMax[2]) / 2]
                // A run with no usable samples leaves infinities — discard.
                if off.allSatisfy({ $0.isFinite }) {
                    AgentConfig.magOffsetMg = off
                    magOffset = off
                }
                calUntil = nil
            }
        }
        .onChange(of: live.sampleCount) {
            guard calUntil != nil, let s = live.latestSample else { return }
            let m = [Double(s.magMg.0), Double(s.magMg.1), Double(s.magMg.2)]
            for i in 0..<3 {
                calMin[i] = min(calMin[i], m[i])
                calMax[i] = max(calMax[i], m[i])
            }
        }
    }
}

/// Wireframe cuboid rotated by the live eCompass angles — desktop
/// `draw_orientation_box` parity. Body frame is NED (x forward, y right,
/// z down) with the box's LONG side on body Y; rotation body->world is
/// Rz(yaw)·Ry(pitch)·Rx(roll), viewed from the south at ~28° elevation
/// (orthographic). Blue lid, green nose arrow, fixed N/E ground cross.
private struct OrientationBoxCanvas: View {
    let pitchDeg: Double
    let rollDeg: Double
    let headingDeg: Double

    var body: some View {
        Canvas { ctx, size in
            let cx = Double(size.width) / 2
            let cy = Double(size.height) / 2
            let scale = Double(size.height) / 3.2

            let sr = sin(rollDeg * .pi / 180), cr = cos(rollDeg * .pi / 180)
            let sp = sin(pitchDeg * .pi / 180), cp = cos(pitchDeg * .pi / 180)
            let sy = sin(headingDeg * .pi / 180), cyw = cos(headingDeg * .pi / 180)

            // body -> world (NED): Rz(yaw) * Ry(pitch) * Rx(roll)
            func rot(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
                let (x, y, z) = v
                let y1 = y * cr - z * sr, z1 = y * sr + z * cr        // Rx
                let x2 = x * cp + z1 * sp, z2 = -x * sp + z1 * cp     // Ry
                return (x2 * cyw - y1 * sy, x2 * sy + y1 * cyw, z2)   // Rz
            }
            // Orthographic camera looking north from the south, 28° up.
            let el = 28.0 * .pi / 180
            let sel = sin(el), cel = cos(el)
            func project(_ w: (Double, Double, Double)) -> CGPoint {
                CGPoint(x: cx + w.1 * scale, y: cy - (w.0 * sel - w.2 * cel) * scale)
            }
            func p3(_ v: (Double, Double, Double)) -> CGPoint { project(rot(v)) }
            func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ w: CGFloat) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(color), lineWidth: w)
            }

            let axis = Color(uiColor: .systemGray3)
            let side = Color(uiColor: .systemGray)
            let lid = Color(red: 0.31, green: 0.71, blue: 0.98)
            let nose = Color(red: 0.26, green: 0.63, blue: 0.28)

            // Fixed ground-plane compass cross (world frame).
            line(project((1.35, 0, 0)), project((-1.35, 0, 0)), axis, 1)
            line(project((0, 1.35, 0)), project((0, -1.35, 0)), axis, 1)
            ctx.draw(Text("N").font(.subheadline).foregroundStyle(.secondary),
                     at: project((1.5, 0, 0)))
            ctx.draw(Text("E").font(.subheadline).foregroundStyle(.secondary),
                     at: project((0, 1.5, 0)))

            // Cuboid — long side is body Y. z down in NED: lid has z = -hz.
            let hx = 0.62, hy = 1.0, hz = 0.28
            let v: [(Double, Double, Double)] = [
                (hx, hy, -hz), (hx, -hy, -hz), (-hx, -hy, -hz), (-hx, hy, -hz),  // lid
                (hx, hy, hz), (hx, -hy, hz), (-hx, -hy, hz), (-hx, hy, hz),      // bottom
            ]
            let pts = v.map { p3($0) }
            for (a, b) in [(4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)] {
                line(pts[a], pts[b], side, 1.3)
            }
            for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 0)] {
                line(pts[a], pts[b], lid, 2)
            }
            // Nose arrow along the long (+y) end of the lid.
            let lidC = p3((0, 0, -hz))
            let tip = p3((0, hy * 1.25, -hz))
            line(lidC, tip, nose, 2)
            let ang = atan2(tip.y - lidC.y, tip.x - lidC.x)
            for s in [1.0, -1.0] {
                let a2 = ang + s * 2.6
                line(tip, CGPoint(x: tip.x + 12 * cos(a2), y: tip.y + 12 * sin(a2)), nose, 2)
            }
        }
        .frame(height: 200)
    }
}

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
