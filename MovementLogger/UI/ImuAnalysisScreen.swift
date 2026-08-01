import SwiftUI

/// "Analyze" tab — on-device IMU propulsion analysis of a recorded ride.
/// Lists the IMU recordings on the phone (phone-logger `SensPhone_*` and
/// Apple-Watch `WatchImu_*`), auto-pairs each with its GPS file, and renders
/// the `ImuAnalysis` mode strip + cadence + board angles natively. This is the
/// in-app equivalent of the offline Python analyzer.
struct ImuAnalysisScreen: View {
    @State private var recordings: [ImuRecording] = []
    @State private var selected: ImuRecording?

    // Master/detail is driven by internal state rather than a nested
    // NavigationStack: this tab lands in the tab bar's "More" overflow, which
    // already provides a navigation controller — a second NavigationStack there
    // renders two stacked back buttons. Matches the Android screen's structure.
    var body: some View {
        listView
            .onAppear { if recordings.isEmpty { recordings = ImuRecording.scan() } }
            // Present the detail as a full-screen modal rather than swapping the
            // body: this screen lands in the tab bar's "More" overflow, whose
            // UIKit bridging interferes with in-place body swaps / List button
            // taps. A modal cover always presents cleanly.
            .fullScreenCover(item: $selected) { rec in
                ImuAnalysisDetail(recording: rec, onBack: { selected = nil })
            }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Analyze").font(.largeTitle.bold())
                Spacer()
                Button { recordings = ImuRecording.scan() } label: {
                    Image(systemName: "arrow.clockwise").font(.title3)
                }
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)
            if recordings.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No IMU recordings",
                    systemImage: "waveform.path.ecg",
                    description: Text("Record with the Phone logger (GPS tab) or an Apple-Watch ride, then come back.")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(recordings) { rec in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rec.title).font(.body.weight(.medium))
                                    Text("\(rec.kindLabel) · \(rec.sizeLabel)\(rec.gpsURL == nil ? " · no GPS pair" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = rec }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Recording discovery

struct ImuRecording: Identifiable, Hashable {
    let id: String
    let imuURL: URL
    let gpsURL: URL?
    let isWatch: Bool
    let sizeBytes: Int

    var title: String { imuURL.lastPathComponent }
    var kindLabel: String { isWatch ? "Apple Watch IMU" : "Phone logger" }
    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    static func docs() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Scan Documents/ (phone-logger) and Documents/WatchRides/ (watch) for IMU
    /// files, auto-pairing each with its GPS sibling. Newest first.
    static func scan() -> [ImuRecording] {
        let fm = FileManager.default
        let root = docs()
        let rides = root.appendingPathComponent("WatchRides", isDirectory: true)
        var out: [ImuRecording] = []
        for dir in [root, rides] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for f in files {
                let n = f.lastPathComponent
                let lower = n.lowercased()
                guard lower.hasSuffix(".csv") else { continue }
                let isWatch = n.hasPrefix("WatchImu_")
                let isPhone = n.hasPrefix("SensPhone_")
                guard isWatch || isPhone else { continue }
                let gps = gpsPair(for: f, in: files)
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                out.append(ImuRecording(id: f.path, imuURL: f, gpsURL: gps, isWatch: isWatch, sizeBytes: size))
            }
        }
        return out.sorted { $0.imuURL.lastPathComponent > $1.imuURL.lastPathComponent }
    }

    private static func gpsPair(for imu: URL, in dir: [URL]) -> URL? {
        let n = imu.lastPathComponent
        let target: String?
        if n.hasPrefix("SensPhone") { target = n.replacingOccurrences(of: "SensPhone", with: "GpsPhone") }
        else if n.hasPrefix("WatchImu") { target = n.replacingOccurrences(of: "WatchImu", with: "WatchGps") }
        else { target = nil }
        guard let t = target else { return nil }
        return dir.first { $0.lastPathComponent == t }
    }
}

// MARK: - Detail (runs analysis + renders)

private struct ImuAnalysisDetail: View {
    let recording: ImuRecording
    let onBack: () -> Void
    @State private var result: ImuAnalysisResult?
    @State private var error: String?
    @State private var running = false
    // Horizontal zoom of the time axis: the panels render into a
    // (width × zoom)-wide horizontal scroll so a long ride can be spread out
    // and panned. `zoomAnchor` holds the value at the pinch gesture's start.
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 2) { Image(systemName: "chevron.left"); Text("Analyze") }
                }
                Spacer()
                Text("IMU analysis").font(.headline)
                Spacer()
                Color.clear.frame(width: 60, height: 1)   // balance the title
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            content
        }
        .task { await run() }
    }

    private var content: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if running {
                        HStack(spacing: 10) { ProgressView(); Text("Analyzing \(recording.title)…") }
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                    } else if let e = error {
                        ContentUnavailableView("Couldn't analyze", systemImage: "exclamationmark.triangle", description: Text(e))
                    } else if let r = result {
                        ResultHeader(r: r).padding(.horizontal)
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.left.and.right.text.vertical")
                            Text("Pinch to zoom · \(String(format: "%.0f×", zoom)) · drag to pan")
                            Spacer()
                            if zoom > 1.01 {
                                Button("Reset") { withAnimation(.easeOut) { zoom = 1; zoomAnchor = 1 } }
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)

                        let baseW = max(geo.size.width, 200)
                        ScrollView(.horizontal, showsIndicators: true) {
                            VStack(spacing: 12) {
                                if r.gpsHasSpeed {
                                    let sc = chartScale(r.speedKmh, hLine: ImuAnalysis.foilKmh, fill: true)
                                    Panel(title: "GPS speed", unit: "km/h",
                                          xs: r.minutes, startEpochMs: r.startEpochMs,
                                          yTop: sc.map { "\(fmtVal($0.max)) km/h" }) { g in
                                        LineChart(xs: r.minutes, ys: r.speedKmh, color: .green, geo: g,
                                                  hLine: ImuAnalysis.foilKmh, hColor: .cyan, bands: r.bands, fill: true)
                                    }
                                }
                                let asc = chartScale(r.pitchDeg, r.rollDeg, symmetric: true)
                                Panel(title: "Board angle (mount-relative)", unit: "deg",
                                      xs: r.minutes, startEpochMs: r.startEpochMs,
                                      yTop: asc.map { "\(fmtVal($0.max)) deg" },
                                      yBottom: asc.map { "\(fmtVal($0.min)) deg" },
                                      seriesLegend: [("Pitch", ImuPalette.pitch), ("Roll", ImuPalette.roll)]) { g in
                                    ZStack {
                                        LineChart(xs: r.minutes, ys: r.pitchDeg, color: ImuPalette.pitch, geo: g, bands: r.bands,
                                                  symmetric: true, scaleWith: r.rollDeg)
                                        LineChart(xs: r.minutes, ys: r.rollDeg, color: ImuPalette.roll, geo: g,
                                                  symmetric: true, scaleWith: r.pitchDeg)
                                    }
                                }
                                let esc = chartScale(r.strokeEnergy, hLine: r.seThreshold, fill: true)
                                Panel(title: "Stroke energy (0.35–1.3 Hz)", unit: "RMS",
                                      xs: r.minutes, startEpochMs: r.startEpochMs,
                                      yTop: esc.map { "\(fmtVal($0.max)) RMS" }) { g in
                                    LineChart(xs: r.minutes, ys: r.strokeEnergy, color: .teal, geo: g,
                                              hLine: r.seThreshold, hColor: .brown, bands: r.bands, fill: true)
                                }
                                ModeStripView(r: r)
                            }
                            .frame(width: baseW * zoom)
                            .padding(.horizontal, 12)
                        }
                        .scrollDisabled(zoom <= 1.01)
                        .highPriorityGesture(
                            MagnificationGesture()
                                .onChanged { v in zoom = min(max(zoomAnchor * v, 1), 40) }
                                .onEnded { _ in zoomAnchor = zoom }
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            LegendRow(items: [("Pitch (up/down)", ImuPalette.pitch), ("Roll (lean L/R)", ImuPalette.roll)])
                            LegendRow(items: [("Glide (on foil)", ImuPalette.glide),
                                              ("Paddle / pump", ImuPalette.paddle),
                                              ("Wait / drift", ImuPalette.wait)])
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
    }

    private func run() async {
        guard result == nil, !running else { return }
        running = true; error = nil
        let rec = recording
        do {
            let r = try await Task.detached(priority: .userInitiated) { () throws -> ImuAnalysisResult in
                // Cached result (keyed by source size+mtime) loads instantly and
                // survives app restarts; a miss runs the full pipeline once.
                if let cached = ImuAnalysisCache.load(imuURL: rec.imuURL, gpsURL: rec.gpsURL) { return cached }
                guard let gps = rec.gpsURL else { throw ImuAnalysisError.badFile("No paired GPS file found for \(rec.title).") }
                let fresh = rec.isWatch
                    ? try ImuAnalysis.fromWatch(imuURL: rec.imuURL, gpsURL: gps)
                    : try ImuAnalysis.fromPhoneLogger(sensURL: rec.imuURL, gpsURL: gps)
                ImuAnalysisCache.store(fresh, imuURL: rec.imuURL, gpsURL: rec.gpsURL)
                return fresh
            }.value
            result = r
        } catch {
            self.error = error.localizedDescription
        }
        running = false
    }
}

private extension ImuAnalysisResult {
    var gpsHasSpeed: Bool { speedKmh.contains { $0 > 0.5 } }
    /// Contiguous non-wait spans as (startMin, endMin, mode) for background shading.
    var bands: [(Double, Double, ImuMode)] {
        var out: [(Double, Double, ImuMode)] = []
        var i = 0
        while i < mode.count {
            var j = i
            while j + 1 < mode.count && mode[j + 1] == mode[i] { j += 1 }
            if mode[i] != .wait {
                out.append((minutes[i], minutes[min(j + 1, minutes.count - 1)], mode[i]))
            }
            i = j + 1
        }
        return out
    }
}

// MARK: - Rendering pieces

enum ImuPalette {
    static let glide = Color(red: 0.15, green: 0.39, blue: 0.92)
    static let paddle = Color(red: 0.92, green: 0.45, blue: 0.09)
    static let wait = Color(red: 0.58, green: 0.64, blue: 0.69)
    // Deliberately NOT the glide-blue / paddle-orange of the activity bands —
    // pitch/roll shared those hues once and the legend read as "double orange".
    static let pitch = Color(red: 0.49, green: 0.23, blue: 0.93)   // violet 0x7C3AED
    static let roll = Color(red: 0.86, green: 0.15, blue: 0.47)    // magenta 0xDB2777
    static func color(_ m: ImuMode) -> Color { m == .glide ? glide : (m == .paddle ? paddle : wait) }
}

private struct ResultHeader: View {
    let r: ImuAnalysisResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.sourceName).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(String(format: "%.0f min · %.0f Hz · %d foil runs", r.durationMin, r.fs, r.foilRuns))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                stat("Glide", r.glideSec, ImuPalette.glide)
                stat("Paddle", r.paddleSec, ImuPalette.paddle)
                stat("Wait", r.waitSec, ImuPalette.wait)
                if r.medianStrokeRate.isFinite {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Stroke").font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%.0f/min", r.medianStrokeRate)).font(.callout.weight(.semibold))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stat(_ label: String, _ sec: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Circle().fill(c).frame(width: 8, height: 8)
                Text("\(sec / 60)m").font(.callout.weight(.semibold))
            }
        }
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let unit: String
    var xs: [Double] = []
    var startEpochMs: Int64? = nil
    var yTop: String? = nil
    var yBottom: String? = nil
    var seriesLegend: [(String, Color)] = []
    @ViewBuilder let content: (GeometryProxy) -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                // which line is which, right where the question arises — the
                // bottom legend row is far away and the line hues double as
                // the activity-band hues
                ForEach(seriesLegend, id: \.0) { (label, color) in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 4)
                        Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            // 114 pt plot band + 16 pt hh:mm:ss ruler below it
            VStack(spacing: 0) {
                GeometryReader { g in
                    ZStack { content(g) }
                }
                .frame(height: 114)
                .overlay { TimeGrid(xs: xs, startEpochMs: startEpochMs, labels: false) }
                .overlay(alignment: .topLeading) { scaleTag(yTop) }
                .overlay(alignment: .bottomLeading) { scaleTag(yBottom) }
                TimeGrid(xs: xs, startEpochMs: startEpochMs, labels: true)
                    .frame(height: 16)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// y-scale readout, pinned to the viewport's left edge while the zoomed
    /// content pans under it (the panel itself is the full zoomed width).
    @ViewBuilder private func scaleTag(_ s: String?) -> some View {
        if let s {
            Text(s).font(.system(size: 9)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .visualEffect { c, p in
                    c.offset(x: max(0, 12 - p.frame(in: .scrollView).minX))
                }
        }
    }
}

/// A simple line chart over an [minutes]→[value] series, drawn into the panel's
/// geometry. Optionally fills under the curve, draws a horizontal threshold and
/// activity background bands.
private struct LineChart: View {
    let xs: [Double]
    let ys: [Double]
    let color: Color
    let geo: GeometryProxy
    var hLine: Double? = nil
    var hColor: Color = .gray
    var bands: [(Double, Double, ImuMode)] = []
    var fill: Bool = false
    var symmetric: Bool = false
    /// Extra series folded into the y-range only (shares the axis with `ys`),
    /// so stacked charts in one panel scale identically — like Android's
    /// `second` series.
    var scaleWith: [Double]? = nil

    var body: some View {
        Canvas { ctx, size in
            guard xs.count > 1 else { return }
            let xmin = xs.first!, xmax = xs.last!
            let xr = max(xmax - xmin, 1e-6)
            guard let (ymin, ymax) = chartScale(ys, scaleWith, hLine: hLine,
                                               symmetric: symmetric, fill: fill) else { return }
            let yr = max(ymax - ymin, 1e-6)
            func px(_ x: Double) -> CGFloat { CGFloat((x - xmin) / xr) * size.width }
            func py(_ y: Double) -> CGFloat { size.height - CGFloat((y - ymin) / yr) * size.height }

            // activity bands
            for (a, b, m) in bands {
                let rect = CGRect(x: px(a), y: 0, width: max(1, px(b) - px(a)), height: size.height)
                ctx.fill(Path(rect), with: .color(ImuPalette.color(m).opacity(0.12)))
            }
            // zero / threshold line
            if symmetric {
                var z = Path(); z.move(to: CGPoint(x: 0, y: py(0))); z.addLine(to: CGPoint(x: size.width, y: py(0)))
                ctx.stroke(z, with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
            }
            if let h = hLine {
                var hp = Path(); hp.move(to: CGPoint(x: 0, y: py(h))); hp.addLine(to: CGPoint(x: size.width, y: py(h)))
                ctx.stroke(hp, with: .color(hColor.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            }
            // line (+ optional fill)
            var line = Path()
            var filled = Path()
            var started = false
            for i in xs.indices where ys[i].isFinite {
                let p = CGPoint(x: px(xs[i]), y: py(ys[i]))
                if !started { line.move(to: p); filled.move(to: CGPoint(x: p.x, y: py(min(max(0, ymin), ymax)))); filled.addLine(to: p); started = true }
                else { line.addLine(to: p); filled.addLine(to: p) }
            }
            if fill, started {
                filled.addLine(to: CGPoint(x: px(xs.last!), y: py(min(max(0, ymin), ymax))))
                ctx.fill(filled, with: .color(color.opacity(0.16)))
            }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }
}

private struct ModeStripView: View {
    let r: ImuAnalysisResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mode").font(.caption.weight(.semibold))
            Canvas { ctx, size in
                guard r.minutes.count > 1 else { return }
                let xmin = r.minutes.first!, xmax = r.minutes.last!
                let xr = max(xmax - xmin, 1e-6)
                func px(_ x: Double) -> CGFloat { CGFloat((x - xmin) / xr) * size.width }
                var i = 0
                while i < r.mode.count {
                    var j = i
                    while j + 1 < r.mode.count && r.mode[j + 1] == r.mode[i] { j += 1 }
                    let x0 = px(r.minutes[i]), x1 = px(r.minutes[min(j + 1, r.minutes.count - 1)])
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)),
                             with: .color(ImuPalette.color(r.mode[i])))
                    i = j + 1
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // time ruler under the strip
            TimeGrid(xs: r.minutes, startEpochMs: r.startEpochMs, labels: true)
                .frame(height: 16)
        }
    }
}

private struct LegendRow: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { (label, color) in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 8)
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Axes

/// x-axis base in LOCAL-time seconds so tick marks land on round wall-clock
/// values (12:15:00, not 12:14:37); 0 when the recording has no epoch anchor,
/// which degrades the labels to elapsed hh:mm:ss.
private func axisBaseSec(_ startEpochMs: Int64?) -> Double {
    guard let e = startEpochMs else { return 0 }
    let date = Date(timeIntervalSince1970: Double(e) / 1000.0)
    return (Double(e) + Double(TimeZone.current.secondsFromGMT(for: date)) * 1000.0) / 1000.0
}

private func hms(_ absSec: Double) -> String {
    let t = Int(absSec.rounded()) % 86400
    let s = t < 0 ? t + 86400 : t
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

private func fmtVal(_ v: Double) -> String {
    let a = abs(v)
    if a >= 100 { return String(format: "%.0f", v) }
    if a >= 10 { return String(format: "%.1f", v) }
    return String(format: "%.2f", v)
}

/// The y range a `LineChart` will draw with — single source of truth shared by
/// the chart itself and the panel's y-scale readout so they can never disagree.
private func chartScale(_ ys: [Double], _ ys2: [Double]? = nil,
                        hLine: Double? = nil, symmetric: Bool = false,
                        fill: Bool = false) -> (min: Double, max: Double)? {
    var finite = ys.filter { $0.isFinite }
    if let ys2 { finite += ys2.filter { $0.isFinite } }
    guard !finite.isEmpty else { return nil }
    var ymin = finite.min()!, ymax = finite.max()!
    if symmetric { let m = max(abs(ymin), abs(ymax), 1); ymin = -m; ymax = m }
    if let h = hLine { ymin = min(ymin, h); ymax = max(ymax, h) }
    if fill { ymin = min(ymin, 0) }
    return (ymin, ymax)
}

/// Vertical time gridlines (labels == false) or the hh:mm:ss ruler strip
/// (labels == true). Drawn at the panels' full zoomed width, so ticks pan and
/// densify with the pinch zoom automatically.
private struct TimeGrid: View {
    let xs: [Double]
    let startEpochMs: Int64?
    let labels: Bool

    var body: some View {
        Canvas { ctx, size in
            guard xs.count > 1 else { return }
            let xmin = xs.first!, xmax = xs.last!
            let spanSec = max((xmax - xmin) * 60, 1e-6)
            var step = 7200.0
            for s in [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
            where size.width * CGFloat(s / spanSec) >= 72 { step = s; break }
            let base = axisBaseSec(startEpochMs) + xmin * 60
            var tick = (base / step).rounded(.up) * step
            var lastEnd = -CGFloat.greatestFiniteMagnitude
            while tick <= base + spanSec + 1e-9 {
                let x = CGFloat((tick - base) / spanSec) * size.width
                if labels {
                    let t = ctx.resolve(Text(hms(tick)).font(.system(size: 9)).foregroundStyle(.secondary))
                    let w = t.measure(in: size).width
                    let lx = min(max(x - w / 2, 0), max(0, size.width - w))
                    if lx > lastEnd + 4 {
                        ctx.draw(t, at: CGPoint(x: lx + w / 2, y: size.height / 2))
                        lastEnd = lx + w
                    }
                } else {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                }
                tick += step
            }
        }
    }
}
