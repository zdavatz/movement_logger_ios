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
                                    Panel(title: "GPS speed", unit: "km/h") { g in
                                        LineChart(xs: r.minutes, ys: r.speedKmh, color: .green, geo: g,
                                                  hLine: ImuAnalysis.foilKmh, hColor: .cyan, bands: r.bands)
                                    }
                                }
                                Panel(title: "Board angle (mount-relative)", unit: "deg") { g in
                                    ZStack {
                                        LineChart(xs: r.minutes, ys: r.pitchDeg, color: .blue, geo: g, bands: r.bands, symmetric: true)
                                        LineChart(xs: r.minutes, ys: r.rollDeg, color: .orange, geo: g, symmetric: true)
                                    }
                                }
                                Panel(title: "Stroke energy (0.35–1.3 Hz)", unit: "RMS") { g in
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
                            LegendRow(items: [("Pitch (up/down)", .blue), ("Roll (lean L/R)", .orange)])
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
                guard let gps = rec.gpsURL else { throw ImuAnalysisError.badFile("No paired GPS file found for \(rec.title).") }
                return rec.isWatch
                    ? try ImuAnalysis.fromWatch(imuURL: rec.imuURL, gpsURL: gps)
                    : try ImuAnalysis.fromPhoneLogger(sensURL: rec.imuURL, gpsURL: gps)
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
    @ViewBuilder let content: (GeometryProxy) -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack { content(g) }
            }
            .frame(height: 130)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        Canvas { ctx, size in
            guard xs.count > 1 else { return }
            let xmin = xs.first!, xmax = xs.last!
            let xr = max(xmax - xmin, 1e-6)
            let finite = ys.filter { $0.isFinite }
            guard !finite.isEmpty else { return }
            var ymin = finite.min()!, ymax = finite.max()!
            if symmetric { let m = max(abs(ymin), abs(ymax), 1); ymin = -m; ymax = m }
            if let h = hLine { ymin = min(ymin, h); ymax = max(ymax, h) }
            if fill { ymin = min(ymin, 0) }
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
