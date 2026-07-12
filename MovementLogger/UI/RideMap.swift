import SwiftUI
import MapKit
import UIKit

/// Detail screen for one Apple-Watch ride CSV: draws the recorded GPS track on
/// an interactive `Map`, and exports a shareable PNG (real map tiles under an
/// activity-coloured track, with the app logo, ride stats, a legend, and the
/// GitHub source link baked in). Reached by tapping a row in the Rides tab.
///
/// The track is drawn as **one continuous line** (no more hole-splitting) and
/// coloured by inferred activity:
///
///  - **In water (swim)** — the Ultra's submersion sensor reports the wrist is
///    wet (`WaterTemp [C]` present) and the pace is slow.
///  - **On board** — moving at riding pace (≥ `RideActivity.boardKmh`).
///  - **On land (walking)** — dry (no submersion) and slow, e.g. the walk back
///    to the house after forgetting to stop the tracker.
///
/// Rides recorded before the submersion column existed have no wet/dry signal,
/// so swimming and walking can't be told apart from GPS alone — those degrade
/// to a **speed gradient** (blue slow → red fast) with a note, rather than
/// guessing land vs water.
struct RideMapView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var rendering = false
    @State private var shareItem: ShareImage?

    /// The cleaned continuous track + the coloured polyline runs and legend to
    /// draw for it. Computed once in `load()` so map-camera changes don't
    /// recompute the cleaning/classification.
    @State private var rows: [GpsRow] = []
    @State private var trackPoints: [CLLocationCoordinate2D] = []
    @State private var mapRuns: [MapRun] = []
    @State private var legend: RideLegend = .speed(vMax: 0)

    var body: some View {
        // Own NavigationStack so this screen has exactly ONE navigation bar,
        // regardless of whether the Rides tab is nested under the tab bar's
        // "More" overflow (which is itself a navigation controller — pushing
        // into it is what produced the second, redundant back button).
        NavigationStack {
            Group {
                if let e = loadError {
                    ContentUnavailableView("Couldn't read ride",
                        systemImage: "exclamationmark.triangle", description: Text(e))
                } else if trackPoints.count < 2 {
                    ContentUnavailableView("No GPS fixes",
                        systemImage: "location.slash",
                        description: Text("This ride has fewer than two valid GPS points to plot."))
                } else {
                    mapView
                }
            }
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                // The single "back" — steps back to the ride list.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Rides", systemImage: "chevron.backward")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await share() }
                    } label: {
                        if rendering { ProgressView() }
                        else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(rendering || trackPoints.count < 2)
                }
            }
            .task { load() }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    private var mapView: some View {
        Map(position: $camera) {
            // One polyline per colour run. Runs share their boundary point so
            // the line reads as continuous while the colour changes with the
            // activity — never a straight connector line bridging a real
            // teleport (those are the only breaks).
            ForEach(mapRuns) { run in
                MapPolyline(coordinates: run.coords)
                    .stroke(run.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let first = trackPoints.first {
                Annotation("Start", coordinate: first) {
                    marker(color: .green, glyph: "flag.fill")
                }
            }
            if let last = trackPoints.last {
                Annotation("End", coordinate: last) {
                    marker(color: .red, glyph: "flag.checkered")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .overlay(alignment: .bottomLeading) { legendCard }
        .onAppear {
            camera = .automatic
            if let rect = RideMapRenderer.boundingRect(trackPoints) {
                camera = .rect(rect)
            }
        }
    }

    /// Small translucent legend in the map corner — mode swatches when the
    /// activity is known, a speed gradient scale otherwise.
    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch legend {
            case .modes(let modes):
                ForEach(modes, id: \.self) { m in
                    HStack(spacing: 6) {
                        Circle().fill(m.swiftUIColor).frame(width: 11, height: 11)
                        Text(m.label).font(.caption2)
                    }
                }
            case .speed(let vMax):
                Text("Speed").font(.caption2.weight(.semibold))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: RideMode.speedGradientColors,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 96, height: 8)
                HStack {
                    Text("0").font(.caption2)
                    Spacer()
                    Text(String(format: "%.0f km/h", vMax)).font(.caption2)
                }.frame(width: 96)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private func marker(color: Color, glyph: String) -> some View {
        Image(systemName: glyph)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private func load() {
        do {
            rows = try CsvParsers.parseGpsFile(url)
            let clean = RideMapRenderer.cleanTrack(rows: rows)
            trackPoints = clean.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            (mapRuns, legend) = RideMapRenderer.mapRuns(clean: clean)
            loadError = rows.isEmpty ? "no rows parsed" : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func share() async {
        rendering = true
        defer { rendering = false }
        let png = await RideMapRenderer.render(
            rows: rows, title: url.deletingPathExtension().lastPathComponent)
        guard let png else { return }
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RideMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + "_map.png")
        do {
            try png.write(to: out)
            shareItem = ShareImage(url: out)
        } catch { }
    }
}

/// One coloured polyline for the interactive map.
struct MapRun: Identifiable {
    let id: Int
    let coords: [CLLocationCoordinate2D]
    let color: Color
}

/// What the legend shows: discrete activity modes, or a speed gradient scale
/// (rides with no submersion data, where water vs land can't be inferred).
enum RideLegend {
    case modes([RideMode])
    case speed(vMax: Double)
}

/// Wrapper so the share sheet's `.sheet(item:)` has an `Identifiable`.
private struct ShareImage: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - Activity mode

/// Inferred activity for a stretch of the ride.
enum RideMode: Int, CaseIterable {
    case swim   // in the water
    case board  // on the water, on the board / foil
    case land   // walking on land

    var color: UIColor {
        switch self {
        case .swim:  return UIColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1)  // blue
        case .board: return UIColor(red: 0.16, green: 0.78, blue: 0.42, alpha: 1)  // green
        case .land:  return UIColor(red: 0.95, green: 0.55, blue: 0.13, alpha: 1)  // orange
        }
    }
    var swiftUIColor: Color { Color(color) }

    var label: String {
        switch self {
        case .swim:  return "In water"
        case .board: return "On board"
        case .land:  return "On land"
        }
    }

    /// Blue → cyan → green → yellow → red gradient anchors for the speed legend.
    static var speedGradientColors: [Color] {
        [0.0, 0.25, 0.5, 0.75, 1.0].map { t in
            Color(UIColor(hue: CGFloat((1 - t) * 0.66), saturation: 0.9, brightness: 0.95, alpha: 1))
        }
    }
}

/// Activity classifier: turns cleaned GPS points into a per-point mode using
/// the Ultra submersion signal (wet ⇒ in water) plus speed (fast ⇒ on board),
/// then smooths short flickers into contiguous bands.
enum RideActivity {
    /// No one swims or walks this fast — at/above it the wrist is on the board.
    static let boardKmh = 6.0
    /// Mode runs shorter than this get absorbed into a neighbour, so the track
    /// shows sustained activity, not a 1–2 s flicker (a wrist momentarily
    /// leaving the water mid-swim, a brief slow patch mid-ride).
    static let minRunSec = 20.0

    /// True when the file carries the Ultra's `WaterTemp [C]` submersion column
    /// with at least one real reading — the only reliable wet/dry signal.
    static func hasSubmersion(_ rows: [GpsRow]) -> Bool {
        rows.contains { $0.waterTempC.isFinite }
    }

    /// Grid cell size (metres) for the geographic water region below.
    static let waterCellM = 70.0

    /// Per-point "on the water" flag, derived GEOGRAPHICALLY from the wet fixes.
    ///
    /// The submersion sensor is sparse AND often late — on one 62-min ride it
    /// didn't fire at all for the first 34 min of foiling, then ran continuously
    /// for the swim back. So a blank reading must NOT be read as "on land", and a
    /// time-window sticky-wet can't bridge a 34-min gap. Instead: the confirmed-
    /// wet fixes are ground-truth "this is water" locations — rasterise them into
    /// ~70 m grid cells, then mark any point within ±2 cells (~140 m) of a wet
    /// cell as ON THE WATER, whatever the wrist was doing that second. Only points
    /// far from every wet fix — a genuine inland walk — stay dry (→ land).
    static func waterRegion(_ pts: [GpsRow]) -> [Bool] {
        let n = pts.count
        guard n > 0 else { return [] }
        let latRef = pts[n / 2].lat
        let mLat = 111320.0, mLon = 111320.0 * cos(latRef * .pi / 180)
        let cell = waterCellM
        func cx(_ la: Double) -> Int { Int((la * mLat / cell).rounded(.down)) }
        func cy(_ lo: Double) -> Int { Int((lo * mLon / cell).rounded(.down)) }
        func gkey(_ x: Int, _ y: Int) -> Int64 { Int64(x) &* 4_000_000 &+ Int64(y) }
        var wetCells = Set<Int64>()
        for p in pts where p.waterTempC.isFinite { wetCells.insert(gkey(cx(p.lat), cy(p.lon))) }
        return pts.map { p in
            let x = cx(p.lat), y = cy(p.lon)
            for dx in -2...2 { for dy in -2...2 where wetCells.contains(gkey(x + dx, y + dy)) { return true } }
            return false
        }
    }

    /// A point counts as "wrist in the water" if a submersion reading occurred
    /// within this many seconds — bridges the brief wrist-up moments between
    /// swim strokes so a continuous swim doesn't flicker to "on board".
    static let wetStickySec = 45.0

    /// Per-point wrist-wet flag: confirmed submersion, or one within
    /// `wetStickySec` before/after (two-pass nearest-reading distance in time).
    static func stickyWet(_ pts: [GpsRow]) -> [Bool] {
        let n = pts.count
        guard n > 0 else { return [] }
        let t = pts.map { $0.ticks * 0.01 }                 // seconds
        let confirmed = pts.map { $0.waterTempC.isFinite }
        var dPrev = [Double](repeating: .infinity, count: n)
        var last = -Double.infinity
        for i in 0..<n { if confirmed[i] { last = t[i] }; dPrev[i] = t[i] - last }
        var dNext = [Double](repeating: .infinity, count: n)
        var next = Double.infinity
        for i in stride(from: n - 1, through: 0, by: -1) { if confirmed[i] { next = t[i] }; dNext[i] = next - t[i] }
        return (0..<n).map { min(dPrev[$0], dNext[$0]) <= wetStickySec }
    }

    /// Per-point smoothed activity mode for a cleaned, continuous track.
    ///
    /// Two signals, both needed: WHERE (geographic `waterRegion`) separates the
    /// water session from a real inland walk; and wrist-WET (`stickyWet`, the
    /// submersion sensor) separates **swimming** (wrist in the water) from **on
    /// the board** (foiling — the wrist rides above the surface, so the sensor is
    /// dry). Speed is deliberately NOT used: at swim/foil speeds GPS noise spikes
    /// cross any threshold, and submersion tells board-vs-swim reliably where
    /// speed can't.
    static func modes(for pts: [GpsRow]) -> [RideMode] {
        guard !pts.isEmpty else { return [] }
        let water = waterRegion(pts)      // on the water patch vs far inland
        let wet = stickyWet(pts)          // wrist submerged (or just was)
        let raw: [Int] = pts.indices.map { i in
            if !water[i] { return RideMode.land.rawValue }   // far from water = on land
            return wet[i] ? RideMode.swim.rawValue           // wrist in water = swimming
                          : RideMode.board.rawValue           // on the water, dry = on the board
        }
        return smoothKeys(raw, ticks: pts.map { $0.ticks }, minRunSec: minRunSec)
            .map { RideMode(rawValue: $0) ?? .swim }
    }

    /// Merge any run of equal keys shorter than `minRunSec` into its longer
    /// temporal neighbour, repeatedly, until only sustained runs remain.
    /// Generic over integer keys so it drives both the mode and the
    /// speed-band colourings.
    static func smoothKeys(_ keys: [Int], ticks: [Double], minRunSec: Double) -> [Int] {
        guard keys.count > 1 else { return keys }
        var runs: [(s: Int, e: Int, k: Int)] = []
        var s = 0
        for i in 1...keys.count where i == keys.count || keys[i] != keys[s] {
            runs.append((s, i, keys[s])); s = i
        }
        func dur(_ r: (s: Int, e: Int, k: Int)) -> Double { (ticks[r.e - 1] - ticks[r.s]) * 0.01 }
        while runs.count > 1 {
            // Absorb the single shortest sub-threshold run per pass, then coalesce.
            var idx = -1, shortest = minRunSec
            for (i, r) in runs.enumerated() where dur(r) < shortest { shortest = dur(r); idx = i }
            if idx < 0 { break }
            let left = idx > 0 ? runs[idx - 1] : nil
            let right = idx < runs.count - 1 ? runs[idx + 1] : nil
            if let l = left, let r = right { runs[idx].k = dur(l) >= dur(r) ? l.k : r.k }
            else if let l = left { runs[idx].k = l.k }
            else if let r = right { runs[idx].k = r.k }
            else { break }
            var merged: [(s: Int, e: Int, k: Int)] = []
            for r in runs {
                if var last = merged.last, last.k == r.k { last.e = r.e; merged[merged.count - 1] = last }
                else { merged.append(r) }
            }
            runs = merged
        }
        var out = [Int](repeating: 0, count: keys.count)
        for r in runs where r.s < r.e { for i in r.s..<r.e { out[i] = r.k } }
        return out
    }
}

// MARK: - PNG renderer (real map tiles + activity-coloured track + branded footer)

enum RideMapRenderer {
    static let sourceURL = "github.com/zdavatz/movement_logger_ios"

    // MARK: track cleaning (one continuous line — no more holes)

    /// Positions with a worse claimed accuracy than this are garbage — a watch
    /// ride once carried one WiFi-fallback fix 70 km away, honestly stamped
    /// accuracy 149 000 m. Dropping these is what makes bridging every other
    /// gap safe (no across-town connector line). NaN passes.
    static let maxPlausibleHdop = 50.0
    /// Break the drawn line only across a hop longer than this — a genuine
    /// teleport. In practice the accuracy gate above removes every such hop, so
    /// the track is one unbroken line; this is a safety valve.
    static let teleportBreakM = 200.0
    /// A lone fix reached and left by two big hops within a couple of seconds
    /// while its neighbours sit close together is a 1-sample GPS glitch
    /// (100–380 km/h implied) — drop it so it doesn't draw a zig-zag spur.
    static let spikeHopM = 45.0
    static let spikeMaxDtSec = 2.5
    /// Single hops longer than this don't count toward distance (glitch gate).
    static let trackMaxHopM = 60.0

    /// The continuous cleaned track: valid fixes, stall-duplicates collapsed,
    /// 1-sample spikes removed. `breaks` holds the (rare) edge indices that are
    /// genuine teleports and must not be drawn.
    struct CleanTrack {
        let points: [GpsRow]
        let breaks: Set<Int>
    }

    /// Plottable fixes: fix>0, finite, not (0,0), not flagged-inaccurate.
    static func validPoints(_ rows: [GpsRow]) -> [GpsRow] {
        rows.filter { $0.fix > 0 && $0.lat.isFinite && $0.lon.isFinite
            && !($0.lat == 0 && $0.lon == 0) && !($0.hdop > maxPlausibleHdop) }
    }

    /// The watch logger rewrites the LAST KNOWN location once per second while
    /// no fresh fix arrives, so a dead receiver looks like a live timeline.
    /// Collapse consecutive identical fixes so a stall becomes a single point.
    private static func dedupFixes(_ fixes: [GpsRow]) -> [GpsRow] {
        var out: [GpsRow] = []
        out.reserveCapacity(fixes.count)
        for f in fixes {
            if let p = out.last, p.utc == f.utc, p.lat == f.lat, p.lon == f.lon { continue }
            out.append(f)
        }
        return out
    }

    /// Remove isolated single-sample position spikes (see `spikeHopM`).
    private static func despike(_ pts: [GpsRow]) -> [GpsRow] {
        guard pts.count >= 3 else { return pts }
        var keep = [Bool](repeating: true, count: pts.count)
        for i in 1..<pts.count - 1 {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1]
            let dtIn = (b.ticks - a.ticks) * 0.01, dtOut = (c.ticks - b.ticks) * 0.01
            guard dtIn <= spikeMaxDtSec, dtOut <= spikeMaxDtSec else { continue }
            let hIn = GpsMath.haversineM(a.lat, a.lon, b.lat, b.lon)
            let hOut = GpsMath.haversineM(b.lat, b.lon, c.lat, c.lon)
            let hNbr = GpsMath.haversineM(a.lat, a.lon, c.lat, c.lon)
            if hIn > spikeHopM && hOut > spikeHopM && hNbr < spikeHopM { keep[i] = false }
        }
        return zip(pts, keep).filter { $0.1 }.map { $0.0 }
    }

    /// Half-width (samples) of the accuracy-weighted position smoother below.
    static let smoothHalfWindow = 6

    /// Accuracy-weighted position smoothing. While the wrist is submerged the
    /// fix accuracy collapses to ~27 m (vs ~5 m dry), so a swim draws a
    /// GPS-noise zig-zag no one could actually swim. Average each point's
    /// position with its neighbours weighted by 1/accuracy² — accurate fixes
    /// dominate and pull the noisy ones onto the real line, while clean
    /// low-error (dry) stretches barely move. Rebuilds rows (GpsRow is
    /// immutable), preserving every non-position field.
    private static func smoothPositions(_ pts: [GpsRow]) -> [GpsRow] {
        let n = pts.count
        guard n >= 3 else { return pts }
        let half = smoothHalfWindow
        return pts.indices.map { i -> GpsRow in
            var sLat = 0.0, sLon = 0.0, sW = 0.0
            for j in max(0, i - half)...min(n - 1, i + half) {
                let acc = (pts[j].hdop.isFinite && pts[j].hdop > 1) ? pts[j].hdop : 5.0
                let w = 1.0 / (acc * acc)
                sLat += pts[j].lat * w; sLon += pts[j].lon * w; sW += w
            }
            guard sW > 0 else { return pts[i] }
            let r = pts[i]
            return GpsRow(ticks: r.ticks, utc: r.utc, lat: sLat / sW, lon: sLon / sW,
                          altM: r.altM, speedKmhModule: r.speedKmhModule, courseDeg: r.courseDeg,
                          fix: r.fix, numSat: r.numSat, hdop: r.hdop, waterTempC: r.waterTempC)
        }
    }

    static func cleanTrack(rows: [GpsRow]) -> CleanTrack {
        let pts = smoothPositions(despike(dedupFixes(validPoints(rows))))
        var breaks = Set<Int>()
        if pts.count >= 2 {
            for i in 1..<pts.count {
                let d = GpsMath.haversineM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon)
                if d > teleportBreakM { breaks.insert(i) }
            }
        }
        return CleanTrack(points: pts, breaks: breaks)
    }

    // MARK: colour runs (shared by interactive map + PNG)

    /// Group edges (`1..<count`) into maximal runs of equal key, split at
    /// `breaks`. Each run is the list of POINT indices for one polyline;
    /// adjacent runs share their boundary point so the drawn line stays
    /// visually continuous across a colour change.
    static func polylineRuns(count: Int, breaks: Set<Int>,
                             keyForEdge: (Int) -> Int) -> [(points: [Int], key: Int)] {
        guard count >= 2 else { return [] }
        var runs: [(points: [Int], key: Int)] = []
        var cur: [Int] = []
        var curKey = 0
        func flush() { if cur.count >= 2 { runs.append((cur, curKey)) }; cur = [] }
        for i in 1..<count {
            if breaks.contains(i) { flush() }
            let k = keyForEdge(i)
            if cur.isEmpty { cur = [i - 1, i]; curKey = k }
            else if k == curKey { cur.append(i) }
            else { flush(); cur = [i - 1, i]; curKey = k }
        }
        flush()
        return runs
    }

    /// Build the interactive-map polyline runs + the legend for a cleaned
    /// track: activity-mode colours when submersion data exists, else a
    /// smoothed speed-band colouring approximating the PNG's gradient.
    static func mapRuns(clean: CleanTrack) -> ([MapRun], RideLegend) {
        let pts = clean.points
        guard pts.count >= 2 else { return ([], .speed(vMax: 0)) }
        let coord = { (i: Int) in CLLocationCoordinate2D(latitude: pts[i].lat, longitude: pts[i].lon) }

        let keyForEdge: (Int) -> Int
        let keyColor: (Int) -> Color
        let legend: RideLegend

        if RideActivity.hasSubmersion(pts) {
            let modes = RideActivity.modes(for: pts)
            keyForEdge = { modes[$0].rawValue }
            keyColor = { RideMode(rawValue: $0)?.swiftUIColor ?? .teal }
            // Present modes in canonical order for the legend.
            let present = RideMode.allCases.filter { m in modes.contains(m) }
            legend = .modes(present)
        } else {
            let speeds = pts.map { $0.speedKmhModule }
            let vMax = max(robustMaxSpeed(speeds), 5)
            let sp = GpsMath.rollingMedian(speeds, window: 5)
            let bands = 6
            let raw = pts.indices.map { i -> Int in
                min(bands - 1, max(0, Int((sp[i] / vMax) * Double(bands))))
            }
            let smooth = RideActivity.smoothKeys(raw, ticks: pts.map { $0.ticks }, minRunSec: 8)
            keyForEdge = { smooth[$0] }
            keyColor = { k in
                let t = min(max(Double(k) / Double(bands - 1), 0), 1)
                return Color(UIColor(hue: CGFloat((1 - t) * 0.66), saturation: 0.9, brightness: 0.95, alpha: 1))
            }
            legend = .speed(vMax: vMax)
        }

        let runs = polylineRuns(count: pts.count, breaks: clean.breaks, keyForEdge: keyForEdge)
        let mapRuns = runs.enumerated().map { idx, run in
            MapRun(id: idx, coords: run.points.map(coord), color: keyColor(run.key))
        }
        return (mapRuns, legend)
    }

    // MARK: geometry helpers

    /// Bounding `MKMapRect` of a track with a margin, or nil if empty.
    static func boundingRect(_ coords: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coords.isEmpty else { return nil }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        let padX = max(rect.size.width * 0.18, rect.size.width == 0 ? 4000 : 0)
        let padY = max(rect.size.height * 0.18, rect.size.height == 0 ? 4000 : 0)
        return rect.insetBy(dx: -padX, dy: -padY)
    }

    /// Even-stride downsample so a very dense polyline stays light without
    /// changing the visible shape.
    static func downsample(_ coords: [CLLocationCoordinate2D], max: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > max, max > 1 else { return coords }
        let stride = Double(coords.count) / Double(max)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(max + 1)
        var i = 0.0
        while Int(i) < coords.count {
            out.append(coords[Int(i)]); i += stride
        }
        if let last = coords.last, out.last?.latitude != last.latitude { out.append(last) }
        return out
    }

    /// Σ haversine along the continuous track, skipping teleport breaks and
    /// single-hop glitches.
    static func trackDistanceKm(_ clean: CleanTrack) -> Double {
        let pts = clean.points
        guard pts.count >= 2 else { return 0 }
        var m = 0.0
        for i in 1..<pts.count where !clean.breaks.contains(i) {
            let hop = GpsMath.haversineM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon)
            if hop <= trackMaxHopM { m += hop }
        }
        return m / 1000.0
    }

    // MARK: PNG

    /// Render the shareable PNG. Returns PNG `Data` (nil if the map snapshot
    /// fails or there are <2 points).
    static func render(rows: [GpsRow], title: String,
                       width: CGFloat = 1080, mapHeight: CGFloat = 1440,
                       footerHeight: CGFloat = 260) async -> Data? {
        let clean = cleanTrack(rows: rows)
        let pts = clean.points
        guard pts.count >= 2 else { return nil }
        let coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let rect = boundingRect(coords) else { return nil }

        let mapSize = CGSize(width: width, height: mapHeight)
        let opts = MKMapSnapshotter.Options()
        opts.region = MKCoordinateRegion(rect)
        opts.size = mapSize
        opts.mapType = .standard
        opts.showsBuildings = true
        opts.pointOfInterestFilter = .excludingAll

        guard let snap = try? await start(MKMapSnapshotter(options: opts)) else { return nil }

        // Per-edge colour: activity mode when we know it, else a speed gradient.
        let submerged = RideActivity.hasSubmersion(pts)
        let speeds = pts.map { $0.speedKmhModule }
        let vMax = max(robustMaxSpeed(speeds), 5)
        let smoothSp = GpsMath.rollingMedian(speeds, window: 5)
        let modes: [RideMode] = submerged ? RideActivity.modes(for: pts) : []
        func edgeColor(_ i: Int) -> UIColor {
            submerged ? modes[i].color : speedColor(smoothSp[i], vMax: vMax)
        }
        let legend: RideLegend = submerged
            ? .modes(RideMode.allCases.filter { m in modes.contains(m) })
            : .speed(vMax: vMax)

        // Footer stats.
        let topSpeed = robustTopSpeed(rows: rows)
        let distanceKm = trackDistanceKm(clean)
        let durMin = (pts.last!.ticks - pts.first!.ticks) * 0.01 / 60.0

        let full = CGSize(width: width, height: mapHeight + footerHeight)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = snap.image.scale
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: full, format: fmt)

        let img = renderer.image { rctx in
            let cg = rctx.cgContext
            // 1. Map tiles.
            snap.image.draw(at: .zero)

            let px = coords.map { snap.point(for: $0) }
            cg.setLineCap(.round); cg.setLineJoin(.round)

            // 2. White casing — one continuous sub-path per non-broken run.
            let casingRuns = polylineRuns(count: pts.count, breaks: clean.breaks, keyForEdge: { _ in 0 })
            let casing = CGMutablePath()
            for run in casingRuns { casing.addLines(between: run.points.map { px[$0] }) }
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(9)
            cg.addPath(casing); cg.strokePath()

            // 3. Coloured track, edge by edge (skip teleport breaks).
            cg.setLineWidth(5)
            for i in 1..<pts.count where !clean.breaks.contains(i) {
                cg.setStrokeColor(edgeColor(i).cgColor)
                cg.beginPath(); cg.move(to: px[i - 1]); cg.addLine(to: px[i]); cg.strokePath()
            }

            // 4. Start / end markers.
            drawMarker(cg, at: px.first!, fill: UIColor.systemGreen)
            drawMarker(cg, at: px.last!, fill: UIColor.systemRed)

            // 5. Branded footer with legend.
            drawFooter(cg, full: full, footerHeight: footerHeight, title: title,
                       topSpeed: topSpeed, distanceKm: distanceKm, durMin: durMin, legend: legend)
        }
        return img.pngData()
    }

    // MARK: robust stats

    private static func start(_ s: MKMapSnapshotter) async throws -> MKMapSnapshotter.Snapshot {
        try await withCheckedThrowingContinuation { cont in
            s.start(with: DispatchQueue.global(qos: .userInitiated)) { snap, err in
                if let snap { cont.resume(returning: snap) }
                else { cont.resume(throwing: err ?? CocoaError(.featureUnsupported)) }
            }
        }
    }

    /// 95th-percentile speed so a single GPS speed spike doesn't wash the whole
    /// colour scale toward blue.
    private static func robustMaxSpeed(_ speeds: [Double]) -> Double {
        let s = speeds.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !s.isEmpty else { return 0 }
        return s[Int(Double(s.count - 1) * 0.95)]
    }

    /// >60 km/h on a pumpfoil is always a bad fix (same clip as `GpsMath`).
    private static let maxPlausibleSpeedKmh = 60.0
    private static let fixWindowTicks = 100.0
    private static let minFixSpanTicks = 50.0
    private static let speedVsTrackFactor = 3.0
    private static let speedVsTrackFloorKmh = 5.0
    /// A ≥2 s hole in the valid-fix timeline is a signal blackout (antenna
    /// under water)…
    private static let blackoutGapTicks = 200.0
    /// …and no speed row within 10 s of one counts: while the antenna sinks,
    /// u-blox fabricates a smooth, self-consistent speed ramp with matching
    /// sliding positions and healthy quality flags, so neither quality gates
    /// nor the position cross-check can catch it — blackout adjacency is the
    /// one reliable signature.
    private static let blackoutPadTicks = 1_000.0

    /// Blackout exclusion zones as (start, end) tick pairs, for the top-speed
    /// stat: before the first fix settles, around every ≥2 s hole, after the last.
    private static func blackoutZones(_ fixTicks: [Double]) -> [(Double, Double)] {
        var zones: [(Double, Double)] = [(-.infinity, fixTicks[0] + blackoutPadTicks)]
        for i in 1..<fixTicks.count where fixTicks[i] - fixTicks[i - 1] >= blackoutGapTicks {
            zones.append((fixTicks[i - 1] - blackoutPadTicks, fixTicks[i] + blackoutPadTicks))
        }
        zones.append((fixTicks.last! + 1e-9, .infinity))
        return zones
    }

    /// Top speed for the footer stat, outlier-hardened: hard clip, blackout
    /// adjacency, and position consistency (the earliest/latest valid fix
    /// within ±1 s must span ≥0.5 s and move commensurately). Verified against
    /// the 11.7.2026 Ermioni ride, whose raw column peaked at a fantasy
    /// 27.1 km/h on a ~7 km/h session.
    static func robustTopSpeed(rows: [GpsRow]) -> Double {
        let fixes = dedupFixes(validPoints(rows))
        guard fixes.count >= 2 else { return 0 }
        let fixTicks = fixes.map { $0.ticks }
        let zones = blackoutZones(fixTicks)

        var top = 0.0
        for r in rows {
            let v = r.speedKmhModule
            guard v.isFinite, v >= 0, v <= maxPlausibleSpeedKmh, v > top,
                  r.ticks.isFinite else { continue }
            if zones.contains(where: { r.ticks >= $0.0 && r.ticks <= $0.1 }) { continue }
            let a = lowerBound(fixTicks, r.ticks - fixWindowTicks)
            let b = lowerBound(fixTicks, r.ticks + fixWindowTicks + 1e-9) - 1
            guard b > a else { continue }
            let span = fixTicks[b] - fixTicks[a]
            guard span >= minFixSpanTicks else { continue }
            let chordKmh = GpsMath.haversineM(fixes[a].lat, fixes[a].lon,
                                              fixes[b].lat, fixes[b].lon)
                / (span / 100.0) * 3.6   // ticks are 10 ms
            if v <= chordKmh * speedVsTrackFactor + speedVsTrackFloorKmh { top = v }
        }
        return top
    }

    /// Index of the first element ≥ `key` in the sorted `arr`.
    private static func lowerBound(_ arr: [Double], _ key: Double) -> Int {
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Blue (slow) → cyan → green → yellow → red (fast).
    private static func speedColor(_ speed: Double, vMax: Double) -> UIColor {
        let t = min(max(speed / vMax, 0), 1)
        let hue = (1 - t) * 0.66     // 0.66 = blue, 0.0 = red
        return UIColor(hue: CGFloat(hue), saturation: 0.9, brightness: 0.95, alpha: 1)
    }

    private static func drawMarker(_ cg: CGContext, at p: CGPoint, fill: UIColor) {
        let r: CGFloat = 13
        cg.setFillColor(fill.cgColor)
        cg.setStrokeColor(UIColor.white.cgColor)
        cg.setLineWidth(4)
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        cg.fillEllipse(in: rect); cg.strokeEllipse(in: rect)
    }

    private static func drawFooter(_ cg: CGContext, full: CGSize, footerHeight: CGFloat,
                                   title: String, topSpeed: Double,
                                   distanceKm: Double, durMin: Double, legend: RideLegend) {
        let rect = CGRect(x: 0, y: full.height - footerHeight, width: full.width, height: footerHeight)
        cg.setFillColor(UIColor(white: 0.06, alpha: 0.92).cgColor)
        cg.fill(rect)

        let pad: CGFloat = 28
        // 1. Legend as a horizontal strip across the TOP of the footer — its own
        //    band, so it can never collide with the (long) source-URL line.
        drawLegend(cg, legend, in: rect, pad: pad)
        cg.setFillColor(UIColor(white: 0.2, alpha: 1).cgColor)
        cg.fill(CGRect(x: pad, y: rect.minY + 66, width: full.width - pad * 2, height: 1))

        // 2. Content row below the strip: logo + three text lines.
        let contentTop = rect.minY + 84
        let logoSide: CGFloat = 130
        let logoRect = CGRect(x: pad, y: contentTop, width: logoSide, height: logoSide)
        if let logo = UIImage(named: "RideLogo") {
            let path = UIBezierPath(roundedRect: logoRect, cornerRadius: logoSide * 0.22)
            cg.saveGState(); path.addClip()
            logo.draw(in: logoRect)
            cg.restoreGState()
        }

        let textX = logoRect.maxX + 22
        draw("Movement Logger", at: CGPoint(x: textX, y: contentTop - 2),
             font: .systemFont(ofSize: 40, weight: .bold), color: .white)
        let stats = String(format: "Top %.1f km/h   ·   %.2f km   ·   %.0f min",
                           topSpeed, distanceKm, max(durMin, 0))
        draw(stats, at: CGPoint(x: textX, y: contentTop + 46),
             font: .systemFont(ofSize: 30, weight: .medium), color: UIColor(white: 0.75, alpha: 1))
        draw(sourceURL, at: CGPoint(x: textX, y: contentTop + 92),
             font: .monospacedSystemFont(ofSize: 27, weight: .regular),
             color: UIColor(red: 0.45, green: 0.8, blue: 1, alpha: 1))
    }

    /// Legend as a horizontal strip in the footer's top band: activity swatches
    /// laid out left→right, or a speed gradient scale.
    private static func drawLegend(_ cg: CGContext, _ legend: RideLegend,
                                   in rect: CGRect, pad: CGFloat) {
        let y = rect.minY + 18
        let titleFont = UIFont.systemFont(ofSize: 25, weight: .semibold)
        let labelFont = UIFont.systemFont(ofSize: 25, weight: .regular)
        switch legend {
        case .modes(let modes):
            draw("Activity", at: CGPoint(x: pad, y: y), font: titleFont, color: UIColor(white: 0.85, alpha: 1))
            var x = pad + 170
            for m in modes {
                let dot = CGRect(x: x, y: y + 5, width: 22, height: 22)
                cg.setFillColor(m.color.cgColor); cg.fillEllipse(in: dot)
                draw(m.label, at: CGPoint(x: x + 30, y: y), font: labelFont, color: .white)
                x += 30 + textWidth(m.label, labelFont) + 46
            }
        case .speed(let vMax):
            draw("Speed", at: CGPoint(x: pad, y: y), font: titleFont, color: UIColor(white: 0.85, alpha: 1))
            let barX = pad + 150, barW: CGFloat = 360, barH: CGFloat = 22
            let steps = 60
            for s in 0..<steps {
                let t = Double(s) / Double(steps - 1)
                cg.setFillColor(UIColor(hue: CGFloat((1 - t) * 0.66),
                                        saturation: 0.9, brightness: 0.95, alpha: 1).cgColor)
                cg.fill(CGRect(x: barX + CGFloat(t) * barW, y: y + 2,
                               width: barW / CGFloat(steps) + 1, height: barH))
            }
            let scale = String(format: "0 – %.0f km/h  ·  no submersion data", vMax)
            draw(scale, at: CGPoint(x: barX + barW + 22, y: y),
                 font: labelFont, color: dimGray)
        }
    }

    private static func textWidth(_ s: String, _ font: UIFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private static let dimGray = UIColor(white: 0.7, alpha: 1)

    private static func draw(_ s: String, at p: CGPoint, font: UIFont, color: UIColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }
}

// MARK: - Share sheet

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
