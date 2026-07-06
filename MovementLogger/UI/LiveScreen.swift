import SwiftUI
import CoreLocation
import CoreMotion

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
                            BoardAnglesCard(vm: vm)
                            Spacer().frame(height: 8)
                            ReadoutGrid(sample: sample, magOffset: vm.magOffsetMg,
                                        headingBias: vm.headingBiasDeg)
                            Spacer().frame(height: 8)
                            BatterySection(vm: vm)
                            OrientationSection(live: vm.live, sample: sample,
                                               oriRows: vm.oriRows,
                                               magOffset: $vm.magOffsetMg,
                                               headingBias: $vm.headingBiasDeg,
                                               nosePlusY: $vm.nosePlusY)
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
        // Fixed-width, one-line rendering so the ticking value can't
        // reflow the layout (the whole screen used to hop with it).
        if let t = live.latestSampleAt {
            let elapsed = now.timeIntervalSince(t)
            if elapsed < 5 {
                Text(String(format: "last sample %4.1f s ago", elapsed))
                    .font(.caption).foregroundStyle(.green)
                    .monospacedDigit().lineLimit(1)
            } else {
                Text(String(format: "no sample for %4.0f s — check connection", elapsed))
                    .font(.caption).foregroundStyle(.orange)
                    .monospacedDigit().lineLimit(1)
            }
        } else {
            Text("waiting for first SensorStream notify…")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(1)
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
                       a: String(format: "X %+.1f", Double(s.gyroCdps.0) / 10),
                       b: String(format: "Y %+.1f", Double(s.gyroCdps.1) / 10),
                       c: String(format: "Z %+.1f", Double(s.gyroCdps.2) / 10))
            ReadoutRow(label: "Mag (mG)",
                       a: String(format: "X %+d", Int(s.magMg.0)),
                       b: String(format: "Y %+d", Int(s.magMg.1)),
                       c: String(format: "Z %+d", Int(s.magMg.2)))
            // (Pitch/Roll/Yaw now live in the dedicated BoardAnglesCard above —
            // computed about the box's physical axes, not the phone-style accel
            // frame that swapped pitch and roll on this Y-nose box.)
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
    let oriRows: OriRows?
    @Binding var magOffset: [Double]?
    @Binding var headingBias: Double
    @Binding var nosePlusY: Bool?

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
                Text("· gyro-27").font(.caption2).foregroundStyle(.green)
            }
            do {
                // THE calibration: hard-iron is learned automatically
                // (autoCalibrate); the only thing the user must provide is
                // one known direction. Box flat, USB-C end south, one tap.
                let flat = abs(Double(sample.accMg.2)) >= 900
                // ONE tap: box flat, USB-C end south, done. The hard-iron
                // offset is learned silently in the background (autoCalibrate)
                // and every offset refinement is folded into the bias, so the
                // direction set here never drifts.
                Text("Lay the box flat, USB-C end pointing SOUTH, then tap:")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("USB-C points SOUTH — set direction") {
                    // Define the gyro filter's current yaw as south.
                    FileSyncViewModel.shared.setDirectionSouth()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!flat)
                // (Removed "Match iPhone compass": laid next to the box, the
                // box's own magnets disturb the phone's compass, so it fed a
                // wrong heading. One reliable reference — USB-C south — only.)
                // Once: which physical end carries the USB-C connector, so
                // the arrow tilts the right way when the box is upright.
                let upright = abs(Double(sample.accMg.1)) >= 900
                Text("Once, for tilt: stand the box upright, USB-C end UP, and tap:")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("USB-C end is UP — confirm") {
                    // Nose end = the long-axis end currently pointing up.
                    let was = nosePlusY ?? false
                    let now = Double(sample.accMg.1) > 0
                    nosePlusY = now
                    AgentConfig.nosePlusY = now
                    // Flipping the nose end flips its azimuth by exactly 180°
                    // in any pose — keep the set direction valid.
                    if now != was { FileSyncViewModel.shared.nudgeBiasForNoseFlip() }
                }
                .buttonStyle(.bordered)
                .disabled(!upright)
                // No left/right flip button: the handedness is fixed by the
                // hardware (mag-Y chirality in Triad.rows), not a user choice.
                // A scene-mirror toggle reverses the yaw sense and broke the
                // 360° heading + the "USB-C south" reference every time it was
                // tapped — removed. Just two taps calibrate: direction + nose.
                Button("Reset calibration") {
                    FileSyncViewModel.shared.resetMagCalibration()
                }
                .buttonStyle(.bordered)
            }
            if let off = magOffset {
                Text(String(format: "offset [%+04.0f %+04.0f %+04.0f] mG", off[0], off[1], off[2]))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
            }
            // iPhone's own (OS-calibrated) compass as a reference readout —
            // hold the phone away from the box, its magnets disturb it.
            if let ph = phoneCompass.headingDeg {
                let acc = phoneCompass.accuracyDeg.map { String(format: " ±%.0f°", $0) } ?? ""
                let box = FileSyncViewModel.shared.orientationFilter.noseAzimuth(
                    nosePlusY: nosePlusY ?? false, biasDeg: headingBias) ?? 0
                Text(String(format: "iPhone compass %3.0f°%@  ·  box %3.0f°", ph, acc, box))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
                Text("(compare while the phone lies flat, ≥ 50 cm from the box)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(Self.howToCalibrate)
                .font(.subheadline).foregroundStyle(.secondary)
            OrientationBoxCanvas(rows: oriRows,
                                 biasDeg: headingBias,
                                 nosePlusY: nosePlusY ?? false)
        }
        .onAppear { phoneCompass.start() }
        .onDisappear { phoneCompass.stop() }
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
    /// Last heading captured while the phone lay FLAT — drives the preview
    /// scene rotation. Frozen while the phone is picked up (a hand-held,
    /// tilted phone reports garbage headings and made the scene spin).
    var flatHeadingDeg: Double? = nil
    /// iPhone lying flat on the table (CoreMotion gravity ≈ straight
    /// through the screen) — the level/Measure-app trick. The compass
    /// heading is most trustworthy in exactly this pose, so the
    /// set-direction button requires it.
    var phoneFlat = false
    private let mgr = CLLocationManager()
    private let motion = CMMotionManager()

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
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.25
            motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
                guard let g = dm?.gravity else { return }
                self?.phoneFlat = abs(g.z) > 0.9
            }
        }
    }

    func stop() {
        mgr.stopUpdatingHeading()
        motion.stopDeviceMotionUpdates()
    }

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
        if phoneFlat, let hd = headingDeg { flatHeadingDeg = hd }
    }
}

/// Wireframe cuboid rendered from the gyro+accel attitude filter — the
/// box's true 3D orientation from gravity (tilt) + gyroscope (rotation),
/// independent of the magnetometer. All poses are consistent (upside-down
/// and compound rotations included). Fixed map view, screen-up = SOUTH;
/// N/E/S/W labels (N red); semi-transparent lid; green nose arrow on the
/// user-confirmed front end.
private struct OrientationBoxCanvas: View {
    let rows: OriRows?
    let biasDeg: Double
    let nosePlusY: Bool
    var height: CGFloat = 200

    var body: some View {
        Canvas { ctx, size in
            let cx = Double(size.width) / 2
            let cy = Double(size.height) / 2
            let scale = Double(size.height) / 3.2
            let el = 28.0 * .pi / 180
            let sel = sin(el), cel = cos(el)

            // Fixed south-up orthographic screen mapping for a world
            // (north, east, down) point.
            func screen(n: Double, e: Double, d: Double) -> CGPoint {
                CGPoint(x: cx + (-e) * scale,
                        y: cy - ((-n) * sel - d * cel) * scale)
            }

            let axis = Color(uiColor: .systemGray3)
            let side = Color(uiColor: .systemGray)
            let lid = Color(red: 0.31, green: 0.71, blue: 0.98)
            let nose = Color(red: 0.26, green: 0.63, blue: 0.28)
            func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ w: CGFloat) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(color), lineWidth: w)
            }

            // Ground compass cross (world frame, fixed).
            line(screen(n: 1.35, e: 0, d: 0), screen(n: -1.35, e: 0, d: 0), axis, 1)
            line(screen(n: 0, e: 1.35, d: 0), screen(n: 0, e: -1.35, d: 0), axis, 1)
            ctx.draw(Text("N").font(.subheadline).bold().foregroundStyle(.red),
                     at: screen(n: 1.5, e: 0, d: 0))
            ctx.draw(Text("E").font(.subheadline).foregroundStyle(.secondary),
                     at: screen(n: 0, e: 1.5, d: 0))
            ctx.draw(Text("S").font(.subheadline).foregroundStyle(.secondary),
                     at: screen(n: -1.5, e: 0, d: 0))
            ctx.draw(Text("W").font(.subheadline).foregroundStyle(.secondary),
                     at: screen(n: 0, e: -1.5, d: 0))

            // Attitude from the gyro+accel filter; flat until it seeds.
            let r = rows ?? OriRows(n: [1, 0, 0], e: [0, 1, 0], d: [0, 0, -1])
            func p3(_ p: [Double]) -> CGPoint {
                let w = Triad.world(p, rows: (n: r.n, e: r.e, d: r.d), biasDeg: biasDeg)
                return screen(n: w.n, e: w.e, d: w.d)
            }

            // Cuboid in the SENSOR frame: z points UP out of the lid
            // (accel reads +1g on z when flat lid-up), long side = y.
            let hx = 0.62, hy = 1.0, hz = 0.28
            let v: [[Double]] = [
                [hx, hy, hz], [hx, -hy, hz], [-hx, -hy, hz], [-hx, hy, hz],     // lid
                [hx, hy, -hz], [hx, -hy, -hz], [-hx, -hy, -hz], [-hx, hy, -hz], // bottom
            ]
            let pts = v.map { p3($0) }
            for (a, b) in [(4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)] {
                line(pts[a], pts[b], side, 1.3)
            }
            var lidFace = Path()
            lidFace.move(to: pts[0])
            for i in [1, 2, 3] { lidFace.addLine(to: pts[i]) }
            lidFace.closeSubpath()
            ctx.fill(lidFace, with: .color(lid.opacity(0.25)))
            for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 0)] {
                line(pts[a], pts[b], lid, 2)
            }
            // Nose arrow on the user-confirmed front end, on the lid.
            let ny = nosePlusY ? hy : -hy
            let lidC = p3([0, 0, hz])
            let tip = p3([0, ny * 1.25, hz])
            line(lidC, tip, nose, 2)
            let ang = atan2(tip.y - lidC.y, tip.x - lidC.x)
            for sgn in [1.0, -1.0] {
                let a2 = ang + sgn * 2.6
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

// MARK: - Board angles (pitch / roll / yaw, absolute + zeroable)

/// Prominent attitude readout for the Live tab. Two sets, both from the
/// drift-free gyro+accel filter (NOT the raw accel formulas — those assume a
/// phone-style frame where the long axis is X, so on this box, whose nose is
/// the Y axis, they swap pitch and roll). `BoardAngles` decouples the three
/// about the box's physical axes so the labels are literally what they say:
///
///   • Pitch — nose up / down  (going uphill vs downhill)
///   • Roll  — lean onto the left / right side (bank about the nose)
///   • Yaw   — heading / turn
///
/// Absolute yaw is a compass heading (render bias applied). "Zero here" tares
/// all three to the current pose; the calibrated set then shows deviation from
/// that mounted reference. Hidden math note: the tared yaw is sampled at bias 0
/// so it measures turn-since-zero independent of the direction calibration.
private struct BoardAnglesCard: View {
    @Bindable var vm: FileSyncViewModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Board angles").font(.subheadline).fontWeight(.semibold)

            if let rows = vm.oriRows {
                let abs = BoardAngles.from(rows: rows, nosePlusY: vm.nosePlusY ?? false,
                                           biasDeg: vm.headingBiasDeg)
                let rel = BoardAngles.from(rows: rows, nosePlusY: vm.nosePlusY ?? false,
                                           biasDeg: 0)

                // --- Absolute ---
                Text("Absolute — vs level & north")
                    .font(.caption).foregroundStyle(.secondary)
                angleRow(pitch: abs.pitchDeg, roll: abs.rollDeg,
                         yaw: String(format: "%5.1f°", abs.yawDeg))

                Divider().padding(.vertical, 2)

                // --- Calibrated (tared) ---
                HStack {
                    Text("Calibrated — vs zero pose")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Zero here") { vm.zeroBoardAngles() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if let ref = vm.angleZeroRef {
                    angleRow(pitch: rel.pitchDeg - ref[0],
                             roll: rel.rollDeg - ref[1],
                             yaw: String(format: "%+5.1f°", normDeltaDeg(rel.yawDeg - ref[2])))
                    HStack {
                        if let at = vm.angleZeroAt {
                            Text("zeroed \(agoText(now.timeIntervalSince(at))) ago")
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        Button("Clear") { vm.clearBoardAngleZero() }
                            .font(.caption2).controlSize(.mini)
                    }
                } else {
                    Text("Tap “Zero here” with the board in its reference pose "
                         + "(e.g. sitting level) to read deviation from it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Move the box a little to seed the orientation filter…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onReceive(tick) { now = $0 }
    }

    /// One pitch / roll / yaw line with fixed-width monospaced values and the
    /// plain-language axis hints underneath.
    @ViewBuilder
    private func angleRow(pitch: Double, roll: Double, yaw: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            angleCell("Pitch", String(format: "%+5.1f°", pitch), "up / down hill")
            angleCell("Roll", String(format: "%+5.1f°", roll), "lean L / R")
            angleCell("Yaw", yaw, "heading")
        }
    }

    private func angleCell(_ name: String, _ value: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agoText(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t < 60 ? String(format: "0:%02d", t)
                      : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Battery (dedicated BatteryStatus characteristic)

/// Live pack meter driven by the box's …0200… BatteryStatus characteristic
/// (STC3115 fuel gauge). Desktop parity: stbox-viz-gui main.rs battery meter.
/// Hidden on legacy firmware that never sends a BatterySample (`latestBattery
/// == nil`). The SensorStream `low_batt` flagChip in ReadoutGrid stays — it's
/// a different source (SensorStream flags bit1) and cadence (0.5 Hz vs 1/min).
private struct BatterySection: View {
    @Bindable var vm: FileSyncViewModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let b = vm.latestBattery {
            let pct = b.socPct
            let stale = vm.latestBatteryAt.map { now.timeIntervalSince($0) > 90 } ?? true
            let ramp: Color = pct < 20 ? .red : (pct < 40 ? .yellow : .green)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Battery").fontWeight(.semibold)
                        .frame(width: 104, alignment: .leading)
                    Spacer()
                    Text("\(pct)%")
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(ramp)
                }
                ProgressView(value: Double(pct) / 100.0)
                    .tint(ramp)
                Text(String(format: "%d%%  ·  %.2f V  ·  %+.2f A%@",
                            pct, b.volts, b.amps, stale ? "  · stale" : ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if b.lowBatt {
                    Text("⚠ low battery (< 10 %) — charge the box; GPS may lose fix")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onReceive(tick) { now = $0 }
        }
    }
}
