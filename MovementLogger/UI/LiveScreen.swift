import SwiftUI
import CoreLocation

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
                            ReadoutGrid(sample: sample, magOffset: vm.magOffsetMg,
                                        headingBias: vm.headingBiasDeg)
                            Spacer().frame(height: 8)
                            OrientationSection(live: vm.live, sample: sample,
                                               magOffset: $vm.magOffsetMg,
                                               headingBias: $vm.headingBiasDeg)
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
    let headingBias: Double

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
                       c: String(format: "Yaw %5.1f",
                                 normDeg(s.headingDeg(magOffMg: magOffset) - headingBias)))
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
/// Wrap a degree value into [0, 360).
private func normDeg(_ d: Double) -> Double {
    var v = d.truncatingRemainder(dividingBy: 360)
    if v < 0 { v += 360 }
    return v
}

private struct OrientationSection: View {
    let live: LiveState
    let sample: LiveSample
    @Binding var magOffset: [Double]?
    @Binding var headingBias: Double

    /// iPhone's own compass — reference readout next to the box heading.
    @State private var phoneCompass = PhoneCompass()

    private static let howToCalibrate = """
        The compass auto-calibrates while this tab is open: rotate the box \
        through one slow full circle and the offset is learned and stored by \
        itself. Keep away from laptops, speakers and steel surfaces. Reset \
        calibration wipes the learned offset and direction if something \
        looks off.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Box orientation").font(.subheadline).fontWeight(.semibold)
            }
            do {
                // THE calibration: hard-iron is learned automatically
                // (autoCalibrate); the only thing the user must provide is
                // one known direction. Box flat, USB-C end south, one tap.
                let flat = abs(Double(sample.accMg.2)) >= 900
                if let phone = phoneCompass.headingDeg {
                    // Convention (fixed): FRONT = the USB-C connector end.
                    // Lay the box parallel to the iPhone with the USB-C
                    // end pointing the same way as the phone's top, one
                    // tap — the phone's OS-calibrated compass is the
                    // reference, no need to know south.
                    Text("Front of the box = USB-C connector end. Lay the iPhone flat on the table pointing SOUTH, the box parallel next to it with the USB-C end also pointing south, then tap:")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Box parallel to iPhone — set direction") {
                        let raw = sample.headingDeg(magOffMg: magOffset)
                        headingBias = normDeg(raw - phone)
                        AgentConfig.headingBiasDeg = headingBias
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flat)
                } else {
                    Button("Nose points SOUTH — set direction") {
                        let raw = sample.headingDeg(magOffMg: magOffset)
                        headingBias = normDeg(raw - 180.0)
                        AgentConfig.headingBiasDeg = headingBias
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flat)
                }
                if !flat {
                    Text("lay the box flat to set the direction")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset calibration") {
                    FileSyncViewModel.shared.resetMagCalibration()
                }
                .buttonStyle(.bordered)
            }
            if let off = magOffset {
                Text(String(format: "offset [%+.0f %+.0f %+.0f] mG", off[0], off[1], off[2]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            // iPhone's own (OS-calibrated) compass as a reference readout —
            // hold the phone away from the box, its magnets disturb it.
            if let ph = phoneCompass.headingDeg {
                let acc = phoneCompass.accuracyDeg.map { String(format: " ±%.0f°", $0) } ?? ""
                let box = normDeg(sample.headingDeg(magOffMg: magOffset) - headingBias)
                Text(String(format: "iPhone compass %.0f°%@  ·  box %.0f°", ph, acc, box))
                    .font(.caption).foregroundStyle(.secondary)
                Text("(compare while the phone lies flat, ≥ 50 cm from the box)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(Self.howToCalibrate)
                .font(.subheadline).foregroundStyle(.secondary)
            OrientationBoxCanvas(pitchDeg: sample.pitchDeg(),
                                 rollDeg: sample.rollDeg(),
                                 headingDeg: normDeg(
                                     sample.headingDeg(magOffMg: magOffset) - headingBias),
                                 compassRotDeg: phoneCompass.headingDeg ?? 0)
        }
        .onAppear { phoneCompass.start() }
        .onDisappear { phoneCompass.stop() }
    }
}

/// Looping pose animation for the guided calibration: the wireframe box
/// turns from the previous step's pose into the target pose (1.5 s motion
/// + 1 s hold), so the user sees the exact movement instead of parsing
/// "clockwise" from text. `from == to` renders a static pose (step 1).
private struct CalPoseAnimation: View {
    let from: (Double, Double, Double)  // pitch, roll, heading
    let to: (Double, Double, Double)

    var body: some View {
        TimelineView(.animation) { tl in
            let cycle = 2.5
            let t = tl.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle)
            let raw = min(1.0, t / 1.5)
            let e = raw * raw * (3 - 2 * raw)   // smoothstep ease-in-out
            OrientationBoxCanvas(
                pitchDeg: from.0 + (to.0 - from.0) * e,
                rollDeg: from.1 + (to.1 - from.1) * e,
                headingDeg: from.2 + (to.2 - from.2) * e,
                height: 110
            )
        }
    }
}

/// The iPhone's own compass (CoreLocation heading) — an OS-calibrated
/// reference the user can compare the box heading against. Reuses the
/// location permission the GPS cross-check feature already requests
/// (NSLocationWhenInUseUsageDescription is in Info.plist).
@Observable
private final class PhoneCompass: NSObject, CLLocationManagerDelegate {
    var headingDeg: Double? = nil
    var accuracyDeg: Double? = nil
    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
    }

    func start() {
        if mgr.authorizationStatus == .notDetermined {
            mgr.requestWhenInUseAuthorization()
        }
        if CLLocationManager.headingAvailable() {
            mgr.startUpdatingHeading()
        }
    }

    func stop() { mgr.stopUpdatingHeading() }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let st = m.authorizationStatus
        if st == .authorizedWhenInUse || st == .authorizedAlways,
           CLLocationManager.headingAvailable() {
            m.startUpdatingHeading()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        headingDeg = h.magneticHeading >= 0 ? h.magneticHeading : nil
        accuracyDeg = h.headingAccuracy >= 0 ? h.headingAccuracy : nil
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
    var height: CGFloat = 200
    /// iPhone compass heading: rotates the whole scene so screen-up is
    /// the direction the phone's top points — the preview then behaves
    /// like a compass app and the arrow points physically right no
    /// matter which way the user faces. 0 = fixed north-up (desktop).
    var compassRotDeg: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let cx = Double(size.width) / 2
            let cy = Double(size.height) / 2
            let scale = Double(size.height) / 3.2
            let vr = -compassRotDeg * .pi / 180
            let svr = sin(vr), cvr = cos(vr)

            // Sign flip for the DRAWING only: the sensor reads +1 g on the
            // axis pointing UP (z-up frame) while the NED math below assumes
            // z-down, which mirrored the tilt direction — box stood on its
            // nose drew the arrow pointing down. Flat behaviour and heading
            // are unaffected.
            let sr = -sin(rollDeg * .pi / 180), cr = cos(rollDeg * .pi / 180)
            let sp = -sin(pitchDeg * .pi / 180), cp = cos(pitchDeg * .pi / 180)
            // +90°: the eCompass yaw references the SHORT body axis, but the
            // nose arrow sits on the long (-y) axis — without the shift the
            // drawn arrow pointed east while the real nose (and the heading
            // number) said south. Verified against the real box.
            let yawDraw = (headingDeg + 90) * .pi / 180
            let sy = sin(yawDraw), cyw = cos(yawDraw)

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
                // View rotation by the phone's own heading (compass mode).
                let n = w.0 * cvr - w.1 * svr
                let e = w.0 * svr + w.1 * cvr
                return CGPoint(x: cx + e * scale, y: cy - (n * sel - w.2 * cel) * scale)
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

            // Ground-plane compass cross (world frame) — all four labels
            // so the south end can't be misread as north.
            line(project((1.35, 0, 0)), project((-1.35, 0, 0)), axis, 1)
            line(project((0, 1.35, 0)), project((0, -1.35, 0)), axis, 1)
            ctx.draw(Text("N").font(.subheadline).bold().foregroundStyle(.red),
                     at: project((1.5, 0, 0)))
            ctx.draw(Text("E").font(.subheadline).foregroundStyle(.secondary),
                     at: project((0, 1.5, 0)))
            ctx.draw(Text("S").font(.subheadline).foregroundStyle(.secondary),
                     at: project((-1.5, 0, 0)))
            ctx.draw(Text("W").font(.subheadline).foregroundStyle(.secondary),
                     at: project((0, -1.5, 0)))

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
            // Fill the lid semi-transparently: a bare wireframe cuboid is a
            // Necker cube — the eye flips which face is "up". The filled
            // lid disambiguates above/below at a glance.
            var lidFace = Path()
            lidFace.move(to: pts[0])
            for i in [1, 2, 3] { lidFace.addLine(to: pts[i]) }
            lidFace.closeSubpath()
            ctx.fill(lidFace, with: .color(lid.opacity(0.25)))
            for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 0)] {
                line(pts[a], pts[b], lid, 2)
            }
            // Nose arrow along the long end of the lid. Body -y, not +y:
            // verified against the real box (box pointed up must draw the
            // arrow up; with +y it drew mirrored while side-tips were
            // already correct — the arrow simply marked the wrong end).
            let lidC = p3((0, 0, -hz))
            let tip = p3((0, -hy * 1.25, -hz))
            line(lidC, tip, nose, 2)
            let ang = atan2(tip.y - lidC.y, tip.x - lidC.x)
            for s in [1.0, -1.0] {
                let a2 = ang + s * 2.6
                line(tip, CGPoint(x: tip.x + 12 * cos(a2), y: tip.y + 12 * sin(a2)), nose, 2)
            }
        }
        .frame(height: height)
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
