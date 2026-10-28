import SwiftUI
import MapKit

/// Session view — one recorded box session (`SENSnnn.CSV` + `GPSnnn.CSV`)
/// drawn straight from the CSVs, **no video needed**. Port of the desktop's
/// Session tab (`stbox-viz-gui/src/session_view.rs`). Opened from the Replay
/// tab's sensor-file list ("Session" button).
///
/// Top: the GPS track on an Apple `Map`, coloured by speed (blue → green →
/// red, scale capped at the 95th-percentile speed), green start / red end
/// marker and a dot at the cursor. Below: stacked charts on one shared time
/// axis — GPS speed, |acc|, pitch + roll, baro height, rotation rate. Pinned
/// at the bottom: play/pause, playback speed, time slider and a readout of
/// every value at the cursor. Tapping the map near the track or tapping a
/// chart moves the cursor; pinching a chart zooms the time axis around it.
///
/// Data prep is in `Data/SessionData.swift`; charts reduce each series to
/// min/max buckets of the visible range (`SessionData.decimate`) and only
/// redraw when that range changes, never per cursor move.
struct SessionScreen: View {
    let sensURL: URL
    let gpsURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var data: SessionData?
    @State private var runs: [MapRun] = []
    @State private var trackCoords: [CLLocationCoordinate2D] = []
    @State private var error: String?
    @State private var progress = SessionLoadProgress()
    @State private var progressText = ""
    @State private var progressFrac = 0.0
    @State private var loadSeconds = 0.0

    @State private var cursor = 0.0
    @State private var playing = false
    @State private var speedIdx = 1
    @State private var follow = false
    @State private var satellite = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var cameraDistance: Double?
    @State private var lastFollow = Date.distantPast
    @State private var shown: Set<SessionChart> = [.speed, .acc, .angles, .height]
    /// Time-axis zoom: visible span = duration / zoom, centred on the cursor.
    @State private var zoom = 1.0
    @State private var pinchBase: Double?

    static let playSpeeds: [Double] = [1, 5, 20, 60, 300]

    var body: some View {
        // Own NavigationStack: presented as a full-screen cover, like the
        // Rides map and the Analyze detail.
        NavigationStack {
            Group {
                if let e = error {
                    ContentUnavailableView("Couldn't read session",
                        systemImage: "exclamationmark.triangle", description: Text(e))
                } else if let d = data {
                    content(d)
                } else {
                    VStack(spacing: 10) {
                        ProgressView(value: progressFrac)
                            .frame(maxWidth: 260)
                        Text(progressText.isEmpty ? "loading…" : progressText)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .navigationTitle(sensURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Replay", systemImage: "chevron.backward")
                    }
                }
            }
        }
        .task { await load() }
        .task(id: playing) { await playLoop() }
    }

    // MARK: - Layout

    private func content(_ d: SessionData) -> some View {
        let (lo, hi) = visibleRange(d)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                summary(d)
                mapSection(d)
                chartToggles(d)
                charts(d, lo: lo, hi: hi)
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom) { controls(d) }
    }

    private func summary(_ d: SessionData) -> some View {
        var parts = [d.gpsName.map { "\(d.sensName) + \($0)" } ?? d.sensName]
        if case .none = d.clock {} else {
            parts.append("\(d.timeLabel(0, tenths: false)) – \(d.timeLabel(d.durationS, tenths: false))")
        }
        parts.append(String(format: "%.0f min %02.0f s", (d.durationS / 60).rounded(.down),
                            d.durationS.truncatingRemainder(dividingBy: 60).rounded(.down)))
        if !d.track.isEmpty {
            parts.append(String(format: "%.2f km", d.distanceM / 1000))
            parts.append(String(format: "max %.1f km/h", d.maxSpeedKmh))
            let hz = d.gpsRateHz
            if hz > 0 { parts.append(String(format: "GPS %.0f Hz", hz)) }
        } else if d.gpsName != nil {
            parts.append("no GPS fix in this file")
        } else {
            parts.append("no GPS file")
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(parts.joined(separator: " · "))
                .font(.subheadline)
            Text(String(format: "%d sensor rows · %d GPS rows · loaded in %.1f s",
                        d.sensT.count, d.gpsT.count, loadSeconds))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Map

    @ViewBuilder
    private func mapSection(_ d: SessionData) -> some View {
        HStack {
            Toggle("Satellite", isOn: $satellite).toggleStyle(.button)
            Toggle("Follow", isOn: $follow).toggleStyle(.button)
            Button("Fit track") { fitTrack() }
                .buttonStyle(.bordered)
        }
        .font(.footnote)
        .disabled(trackCoords.isEmpty)
        if trackCoords.isEmpty {
            Text("No GPS track to draw.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(runs) { run in
                        MapPolyline(coordinates: run.coords)
                            .stroke(run.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    if let s = trackCoords.first {
                        Annotation("Start", coordinate: s) { dot(.green, size: 12) }
                    }
                    if let e = trackCoords.last {
                        Annotation("End", coordinate: e) { dot(.red, size: 12) }
                    }
                    if let i = d.trackIndex(at: cursor) {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: d.lat[i], longitude: d.lon[i])) {
                            dot(.yellow, size: 16, ring: .black)
                        }
                    }
                }
                .mapStyle(satellite ? .imagery(elevation: .flat) : .standard(elevation: .flat))
                .onMapCameraChange { ctx in cameraDistance = ctx.camera.distance }
                .onTapGesture { pt in tapMap(pt, proxy: proxy, d: d) }
                .overlay(alignment: .bottomLeading) { speedLegend(d) }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func dot(_ color: Color, size: CGFloat, ring: Color = .white) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(ring, lineWidth: 2))
    }

    private func speedLegend(_ d: SessionData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speed").font(.caption2.weight(.semibold))
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: RideMode.speedGradientColors,
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 96, height: 8)
            HStack {
                Text("0").font(.caption2)
                Spacer()
                Text(String(format: "%.0f km/h", d.speedScale)).font(.caption2)
            }.frame(width: 96)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
    }

    /// Same hue ramp as the Rides speed legend (`RideMode.speedGradientColors`).
    static func speedColor(band: Int) -> Color {
        let f = Double(band) / Double(SessionData.speedBands - 1)
        return Color(UIColor(hue: CGFloat((1 - f) * 0.66), saturation: 0.9, brightness: 0.95, alpha: 1))
    }

    private func fitTrack() {
        if let rect = RideMapRenderer.boundingRect(trackCoords) {
            camera = .rect(rect)
        }
    }

    /// Tap within ~30 pt of the track → the nearest fix's time.
    private func tapMap(_ pt: CGPoint, proxy: MapProxy, d: SessionData) {
        guard let c = proxy.convert(pt, from: .local),
              let edge = proxy.convert(CGPoint(x: pt.x + 30, y: pt.y), from: .local) else { return }
        let k = cos(c.latitude * .pi / 180)
        let thr = abs(edge.longitude - c.longitude) * k
        var best = -1
        var bestD = Double.greatestFiniteMagnitude
        for i in d.track {
            let dy = d.lat[i] - c.latitude, dx = (d.lon[i] - c.longitude) * k
            let dist = dy * dy + dx * dx
            if dist < bestD { bestD = dist; best = i }
        }
        if best >= 0 && bestD.squareRoot() <= thr {
            playing = false
            cursor = d.gpsT[best]
        }
    }

    // MARK: - Charts

    private func chartToggles(_ d: SessionData) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SessionChart.allCases) { c in
                    Toggle(c.title, isOn: Binding(
                        get: { shown.contains(c) },
                        set: { on in if on { shown.insert(c) } else { shown.remove(c) } }))
                        .toggleStyle(.button)
                        .disabled(c == .speed && d.gpsT.isEmpty)
                }
                if zoom > 1 {
                    Button("Full time") { zoom = 1 }
                        .buttonStyle(.bordered)
                }
            }
            .font(.footnote)
        }
    }

    private func visibleRange(_ d: SessionData) -> (Double, Double) {
        let dur = max(d.durationS, 0.1)
        guard zoom > 1 else { return (0, dur) }
        let span = dur / zoom
        let lo = min(max(cursor - span / 2, 0), dur - span)
        return (lo, lo + span)
    }

    private func charts(_ d: SessionData, lo: Double, hi: Double) -> some View {
        let list = SessionChart.allCases.filter { shown.contains($0) && !(($0 == .speed) && d.gpsT.isEmpty) }
        let ticks = SessionTimeAxis.ticks(d, lo: lo, hi: hi)
        return VStack(spacing: 6) {
            ForEach(list) { c in
                SessionChartPlot(chart: c, data: d, lo: lo, hi: hi, gridTimes: ticks.map(\.t))
                    .equatable()
                    .frame(height: 120)
                    .overlay { cursorOverlay(lo: lo, hi: hi) }
            }
            if !list.isEmpty {
                SessionTimeAxis(ticks: ticks, lo: lo, hi: hi)
                    .equatable()
                    .frame(height: 16)
            }
        }
        // Pinch = zoom the shared time axis around the cursor.
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                let base = pinchBase ?? zoom
                pinchBase = base
                zoom = min(max(base * v.magnification, 1), max(d.durationS / 20, 1))
            }
            .onEnded { _ in pinchBase = nil })
    }

    /// The cursor line over a chart, plus the tap target that moves it.
    private func cursorOverlay(lo: Double, hi: Double) -> some View {
        GeometryReader { g in
            let x = SessionChartPlot.plotX(cursor, lo: lo, hi: hi, width: g.size.width)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { pt in
                        guard let d = data else { return }
                        playing = false
                        let t = SessionChartPlot.timeAt(pt.x, lo: lo, hi: hi, width: g.size.width)
                        cursor = min(max(t, 0), d.durationS)
                    }
                Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: g.size.height))
                }
                .stroke(Color.yellow, lineWidth: 1.5)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Controls

    private func controls(_ d: SessionData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button {
                    if !playing && cursor >= d.durationS { cursor = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 22)
                }
                .buttonStyle(.borderedProminent)
                Menu {
                    Picker("Speed", selection: $speedIdx) {
                        ForEach(Self.playSpeeds.indices, id: \.self) { i in
                            Text("\(Int(Self.playSpeeds[i]))×").tag(i)
                        }
                    }
                } label: {
                    Text("\(Int(Self.playSpeeds[speedIdx]))×")
                        .font(.footnote.monospacedDigit())
                        .frame(minWidth: 36)
                }
                .buttonStyle(.bordered)
                Slider(value: Binding(get: { cursor },
                                      set: { cursor = $0; if playing { playing = false } }),
                       in: 0...max(d.durationS, 0.1))
            }
            Text(d.readout(at: cursor))
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Loading + playback

    private func load() async {
        guard data == nil, error == nil else { return }
        let sens = sensURL, gps = gpsURL, prog = progress
        let started = Date()
        let task = Task.detached(priority: .userInitiated) {
            try SessionData.load(sens: sens, gps: gps) { file, frac in prog.set(file, frac) }
        }
        // Poll the loader's progress (desktop does the same with atomics).
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                let (f, x) = prog.get()
                progressFrac = x
                progressText = f.isEmpty ? "" : String(format: "%@  %.0f %%", f, x * 100)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { poll.cancel() }
        do {
            let d = try await task.value
            loadSeconds = Date().timeIntervalSince(started)
            trackCoords = d.track.map { CLLocationCoordinate2D(latitude: d.lat[$0], longitude: d.lon[$0]) }
            runs = d.speedRuns().enumerated().map { k, r in
                MapRun(id: k,
                       coords: r.points.map { CLLocationCoordinate2D(latitude: d.lat[$0], longitude: d.lon[$0]) },
                       color: Self.speedColor(band: r.band))
            }
            data = d
            fitTrack()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playLoop() async {
        guard playing else { return }
        var last = Date()
        while !Task.isCancelled && playing {
            try? await Task.sleep(for: .milliseconds(33))
            guard let d = data else { return }
            let now = Date()
            cursor += now.timeIntervalSince(last) * Self.playSpeeds[speedIdx]
            last = now
            if cursor >= d.durationS {
                cursor = d.durationS
                playing = false
            }
            // Follow: re-centre at most twice a second, keeping the zoom.
            if follow, now.timeIntervalSince(lastFollow) > 0.5, let i = d.trackIndex(at: cursor) {
                lastFollow = now
                camera = .camera(MapCamera(
                    centerCoordinate: CLLocationCoordinate2D(latitude: d.lat[i], longitude: d.lon[i]),
                    distance: cameraDistance ?? 1500))
            }
        }
    }
}

/// Loader → UI progress hand-off (file name + parsed fraction), polled by the
/// UI while the detached load runs.
final class SessionLoadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var file = ""
    private var frac = 0.0

    func set(_ f: String, _ x: Double) { lock.lock(); file = f; frac = x; lock.unlock() }
    func get() -> (String, Double) { lock.lock(); defer { lock.unlock() }; return (file, frac) }
}

enum SessionChart: String, CaseIterable, Identifiable {
    case speed, acc, angles, height, gyro
    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "Speed"
        case .acc: return "Acceleration"
        case .angles: return "Pitch / roll"
        case .height: return "Height"
        case .gyro: return "Rotation"
        }
    }

    var unit: String {
        switch self {
        case .speed: return "km/h"
        case .acc: return "g"
        case .angles: return "°"
        case .height: return "m"
        case .gyro: return "°/s"
        }
    }

    /// (legend, times, values, colour) per line. Pitch/roll use the Analyze
    /// tab's violet / magenta (`ImuPalette`).
    func series(_ d: SessionData) -> [(String, [Double], [Float], Color)] {
        switch self {
        case .speed: return [("GPS speed", d.gpsT, d.speedKmh, .blue)]
        case .acc: return [("|acc|", d.sensT, d.accG, .orange)]
        case .angles: return [("pitch (nose up +)", d.sensT, d.pitchDeg, ImuPalette.pitch),
                              ("roll", d.sensT, d.rollDeg, ImuPalette.roll)]
        case .height: return [("baro height", d.sensT, d.heightM, .teal)]
        case .gyro: return [("|rotation|", d.sensT, d.gyroDps, .brown)]
        }
    }
}

/// One chart's lines over `[lo, hi]`. Equatable on the range only, so a
/// cursor move (drawn as a separate overlay) never re-decimates ~1 M rows.
struct SessionChartPlot: View, Equatable {
    let chart: SessionChart
    let data: SessionData
    let lo: Double
    let hi: Double
    let gridTimes: [Double]

    /// Min/max buckets per line and redraw (two points each).
    static let buckets = 1200
    static let leftInset: CGFloat = 40

    static func == (a: Self, b: Self) -> Bool {
        a.chart == b.chart && a.lo == b.lo && a.hi == b.hi && a.data.sensName == b.data.sensName
    }

    static func plotX(_ t: Double, lo: Double, hi: Double, width: CGFloat) -> CGFloat {
        leftInset + CGFloat((t - lo) / max(hi - lo, 1e-9)) * (width - leftInset)
    }

    static func timeAt(_ x: CGFloat, lo: Double, hi: Double, width: CGFloat) -> Double {
        lo + Double(max(x - leftInset, 0)) / Double(max(width - leftInset, 1)) * (hi - lo)
    }

    var body: some View {
        let lines = chart.series(data).map { s in
            (s.0, SessionData.decimate(t: s.1, y: s.2, lo: lo, hi: hi, buckets: Self.buckets), s.3)
        }
        var yMin = Float.greatestFiniteMagnitude, yMax = -Float.greatestFiniteMagnitude
        for l in lines { for p in l.1 { yMin = min(yMin, p.y); yMax = max(yMax, p.y) } }
        if yMin > yMax { yMin = 0; yMax = 1 }
        if yMax - yMin < 1e-3 { yMin -= 0.5; yMax += 0.5 }
        let pad = (yMax - yMin) * 0.06
        let (y0, y1) = (Double(yMin - pad), Double(yMax + pad))
        return Canvas { ctx, size in
            let left = Self.leftInset
            let plot = CGRect(x: left, y: 0, width: size.width - left, height: size.height)
            ctx.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(Color(.secondarySystemBackground)))
            func py(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - y0) / (y1 - y0)) * plot.height }
            for t in gridTimes {
                let x = Self.plotX(t, lo: lo, hi: hi, width: size.width)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                           with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            }
            if y0 < 0 && y1 > 0 {
                ctx.stroke(Path { $0.move(to: CGPoint(x: left, y: py(0))); $0.addLine(to: CGPoint(x: size.width, y: py(0))) },
                           with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            }
            // A hole wider than a few buckets (e.g. GPS without a fix —
            // NaN speed) is left as a gap instead of a straight bridge.
            let gap = max((hi - lo) / Double(Self.buckets) * 4, 2)
            for (_, pts, color) in lines where pts.count > 1 {
                var path = Path()
                var prevT = -Double.infinity
                for p in pts {
                    let pt = CGPoint(x: Self.plotX(p.t, lo: lo, hi: hi, width: size.width), y: py(Double(p.y)))
                    if p.t - prevT > gap { path.move(to: pt) } else { path.addLine(to: pt) }
                    prevT = p.t
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.2)
            }
            // y scale: top / bottom value + unit, and the legend.
            ctx.draw(Text(fmt(Double(yMax)) + " " + chart.unit).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: left - 3, y: py(Double(yMax))), anchor: .trailing)
            ctx.draw(Text(fmt(Double(yMin))).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: left - 3, y: py(Double(yMin))), anchor: .trailing)
            var lx = left + 6
            for (name, _, color) in lines {
                let t = ctx.resolve(Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(color))
                ctx.draw(t, at: CGPoint(x: lx, y: 4), anchor: .topLeading)
                lx += t.measure(in: size).width + 10
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        abs(v) >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}

/// Wall-clock labels under the bottom chart, on round local times.
struct SessionTimeAxis: View, Equatable {
    let ticks: [(t: Double, label: String)]
    let lo: Double
    let hi: Double

    static func == (a: Self, b: Self) -> Bool { a.lo == b.lo && a.hi == b.hi && a.ticks.count == b.ticks.count }

    /// Tick times (session s) + labels for `[lo, hi]`: a "nice" step giving
    /// ~3–6 ticks, placed on round local seconds-of-day (elapsed seconds when
    /// the session has no clock). The clock is ~linear over a view, so the
    /// local time at `lo` plus (t − lo) places them.
    static func ticks(_ d: SessionData, lo: Double, hi: Double) -> [(t: Double, label: String)] {
        let span = hi - lo
        guard span > 0 else { return [] }
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let step = steps.first { span / $0 <= 5 } ?? 7200
        let base = d.clock.localSecondsOfDay(boxMs: d.t0Ms + lo * 1000)
        let s0 = base ?? lo
        var out: [(t: Double, label: String)] = []
        var v = (s0 / step).rounded(.up) * step
        while v <= s0 + span {
            let t = lo + (v - s0)
            let label: String
            if base != nil {
                label = step >= 60 ? String(SessionClock.format(v, tenths: false).prefix(5))
                                   : SessionClock.format(v, tenths: false)
            } else {
                label = step >= 60 ? String(format: "%.0f min", v / 60) : String(format: "%.0f s", v)
            }
            out.append((t, label))
            v += step
        }
        return out
    }

    var body: some View {
        Canvas { ctx, size in
            for tk in ticks {
                let x = SessionChartPlot.plotX(tk.t, lo: lo, hi: hi, width: size.width)
                ctx.draw(Text(tk.label).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: size.height / 2), anchor: .center)
            }
        }
    }
}
