import SwiftUI
import MapKit
import UIKit

/// Detail screen for one Apple-Watch ride CSV: draws the recorded GPS track on
/// an interactive `Map`, and exports a shareable PNG (real map tiles under a
/// speed-coloured track, with the app logo, ride stats, and the GitHub source
/// link baked in). Reached by tapping a row in the Rides tab.
struct RideMapView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [GpsRow] = []
    @State private var loadError: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var rendering = false
    @State private var shareItem: ShareImage?

    /// Blackout-cleaned track segments — fabricated antenna-under-water
    /// positions dropped, polyline broken across fix holes. Cached from
    /// `load()` so map camera changes don't recompute the cleaning.
    @State private var coordSegments: [[CLLocationCoordinate2D]] = []

    private var coords: [CLLocationCoordinate2D] { coordSegments.flatMap { $0 } }

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
                } else if coords.count < 2 {
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
                    .disabled(rendering || coords.count < 2)
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
            // One polyline per segment — never a straight connector line
            // bridging a signal blackout.
            ForEach(coordSegments.indices, id: \.self) { i in
                MapPolyline(coordinates: RideMapRenderer.downsample(
                    coordSegments[i],
                    max: Swift.max(2, 2000 * coordSegments[i].count / Swift.max(1, coords.count))))
                    .stroke(.teal, lineWidth: 4)
            }
            if let first = coords.first {
                Annotation("Start", coordinate: first) {
                    marker(color: .green, glyph: "flag.fill")
                }
            }
            if let last = coords.last {
                Annotation("End", coordinate: last) {
                    marker(color: .red, glyph: "flag.checkered")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .onAppear {
            camera = .automatic
            if let rect = RideMapRenderer.boundingRect(coords) {
                camera = .rect(rect)
            }
        }
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
            coordSegments = RideMapRenderer.cleanTrackSegments(rows: rows).map { seg in
                seg.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            }
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

/// Wrapper so the share sheet's `.sheet(item:)` has an `Identifiable`.
private struct ShareImage: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - PNG renderer (real map tiles + speed-coloured track + branded footer)

enum RideMapRenderer {
    static let sourceURL = "github.com/zdavatz/movement_logger_ios"

    /// Bounding `MKMapRect` of a track with a margin, or nil if empty.
    static func boundingRect(_ coords: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coords.isEmpty else { return nil }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        // 18 % margin so the track isn't jammed against the frame; clamp a
        // near-stationary session to a sensible minimum span.
        let padX = max(rect.size.width * 0.18, rect.size.width == 0 ? 4000 : 0)
        let padY = max(rect.size.height * 0.18, rect.size.height == 0 ? 4000 : 0)
        return rect.insetBy(dx: -padX, dy: -padY)
    }

    /// Even-stride downsample so an interactive `MapPolyline` (or a very dense
    /// track) stays light without changing the visible shape.
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

    /// Render the shareable PNG. Returns PNG `Data` (nil if the map snapshot
    /// fails or there are <2 points).
    static func render(rows: [GpsRow], title: String,
                       width: CGFloat = 1080, mapHeight: CGFloat = 1440,
                       footerHeight: CGFloat = 190) async -> Data? {
        // Blackout-cleaned segments: no fabricated antenna-under-water
        // positions, no straight connector lines across the fix holes.
        let segments = cleanTrackSegments(rows: rows)
        guard !segments.isEmpty else { return nil }
        let valid = segments.flatMap { $0 }
        let coords = valid.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let rect = boundingRect(coords) else { return nil }

        let mapSize = CGSize(width: width, height: mapHeight)
        let opts = MKMapSnapshotter.Options()
        opts.region = MKCoordinateRegion(rect)
        opts.size = mapSize
        opts.mapType = .standard
        opts.showsBuildings = true
        opts.pointOfInterestFilter = .excludingAll

        guard let snap = try? await start(MKMapSnapshotter(options: opts)) else { return nil }

        // Stats for the footer. Top speed is outlier-hardened — the raw
        // column max reads 27 km/h on a 7 km/h session when the antenna
        // dips under water (see robustTopSpeed).
        let speeds = valid.map { $0.speedKmhModule }
        let topSpeed = robustTopSpeed(rows: rows)
        let distanceKm = segmentsDistanceKm(segments)
        let durMin = (valid.last!.ticks - valid.first!.ticks) * 0.01 / 60.0   // 10ms ticks → min
        let vMax = max(robustMaxSpeed(speeds), 5)

        let full = CGSize(width: width, height: mapHeight + footerHeight)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = snap.image.scale
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: full, format: fmt)

        let img = renderer.image { rctx in
            let cg = rctx.cgContext
            // 1. Map tiles.
            snap.image.draw(at: .zero)

            // 2. Track. White casing first for contrast, then speed-coloured
            //    segments on top.
            let px = coords.map { snap.point(for: $0) }
            cg.setLineCap(.round); cg.setLineJoin(.round)
            // One sub-path per segment — the casing never crosses a blackout.
            let casing = CGMutablePath()
            var off = 0
            for seg in segments {
                casing.addLines(between: Array(px[off ..< off + seg.count]))
                off += seg.count
            }
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(9)
            cg.addPath(casing); cg.strokePath()

            cg.setLineWidth(5)
            off = 0
            for seg in segments {
                for i in 1..<seg.count {
                    cg.setStrokeColor(speedColor(speeds[off + i], vMax: vMax).cgColor)
                    cg.beginPath(); cg.move(to: px[off + i - 1]); cg.addLine(to: px[off + i]); cg.strokePath()
                }
                off += seg.count
            }

            // 3. Start / end markers.
            drawMarker(cg, at: px.first!, fill: UIColor.systemGreen)
            drawMarker(cg, at: px.last!, fill: UIColor.systemRed)

            // 4. Branded footer.
            drawFooter(cg, full: full, footerHeight: footerHeight, title: title,
                       topSpeed: topSpeed, distanceKm: distanceKm, durMin: durMin)
        }
        return img.pngData()
    }

    // MARK: helpers

    private static func start(_ s: MKMapSnapshotter) async throws -> MKMapSnapshotter.Snapshot {
        try await withCheckedThrowingContinuation { cont in
            s.start(with: DispatchQueue.global(qos: .userInitiated)) { snap, err in
                if let snap { cont.resume(returning: snap) }
                else { cont.resume(throwing: err ?? CocoaError(.featureUnsupported)) }
            }
        }
    }

    private static func trackDistanceKm(_ rows: [GpsRow]) -> Double {
        guard rows.count >= 2 else { return 0 }
        var m = 0.0
        for i in 1..<rows.count {
            m += GpsMath.haversineM(rows[i-1].lat, rows[i-1].lon, rows[i].lat, rows[i].lon)
        }
        return m / 1000.0
    }

    /// 95th-percentile speed so a single GPS speed spike doesn't wash the whole
    /// colour scale toward blue.
    private static func robustMaxSpeed(_ speeds: [Double]) -> Double {
        let s = speeds.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !s.isEmpty else { return 0 }
        return s[Int(Double(s.count - 1) * 0.95)]
    }

    // MARK: track cleaning + robust stats (Android `RideMapRenderer` port)

    /// Positions with a worse claimed accuracy than this are flagged
    /// garbage — the 11.7.2026 watch ride carried one WiFi-fallback fix
    /// 70 km away, honestly stamped accuracy 149 000 m. NaN passes.
    static let maxPlausibleHdop = 50.0

    /// Plottable fixes: fix>0, finite, not (0,0), not flagged-inaccurate.
    static func validPoints(_ rows: [GpsRow]) -> [GpsRow] {
        rows.filter { $0.fix > 0 && $0.lat.isFinite && $0.lon.isFinite
            && !($0.lat == 0 && $0.lon == 0) && !($0.hdop > maxPlausibleHdop) }
    }

    /// The watch logger rewrites the LAST KNOWN location once per second
    /// while no fresh fix arrives (42 identical rows during the 11.7.2026
    /// stall), so a dead receiver looks like a live fix timeline. Collapse
    /// consecutive identical fixes so a stall becomes a visible hole.
    private static func dedupFixes(_ fixes: [GpsRow]) -> [GpsRow] {
        var out: [GpsRow] = []
        out.reserveCapacity(fixes.count)
        for f in fixes {
            if let p = out.last, p.utc == f.utc, p.lat == f.lat, p.lon == f.lon { continue }
            out.append(f)
        }
        return out
    }

    /// Blackout exclusion zones as (start, end) tick pairs: before the
    /// first fix settles, around every ≥2 s hole, and after the last fix.
    private static func blackoutZones(_ fixTicks: [Double]) -> [(Double, Double)] {
        var zones: [(Double, Double)] = [(-.infinity, fixTicks[0] + blackoutPadTicks)]
        for i in 1..<fixTicks.count where fixTicks[i] - fixTicks[i - 1] >= blackoutGapTicks {
            zones.append((fixTicks[i - 1] - blackoutPadTicks, fixTicks[i] + blackoutPadTicks))
        }
        zones.append((fixTicks.last! + 1e-9, .infinity))
        return zones
    }

    /// The drawable track, cleaned with the same blackout rule as
    /// `robustTopSpeed` and split into continuous segments: positions
    /// within ±10 s of a ≥2 s fix hole are dropped (where u-blox/watch
    /// fabricate a sliding solution) and the polyline breaks across the
    /// holes instead of bridging two distant real points.
    static func cleanTrackSegments(rows: [GpsRow]) -> [[GpsRow]] {
        let fixes = dedupFixes(validPoints(rows))
        guard fixes.count >= 2 else { return [] }
        let zones = blackoutZones(fixes.map { $0.ticks })
        var segments: [[GpsRow]] = []
        var cur: [GpsRow] = []
        for f in fixes {
            if zones.contains(where: { f.ticks >= $0.0 && f.ticks <= $0.1 }) { continue }
            if let last = cur.last, f.ticks - last.ticks >= blackoutGapTicks {
                if cur.count >= 2 { segments.append(cur) }
                cur = []
            }
            cur.append(f)
        }
        if cur.count >= 2 { segments.append(cur) }
        return segments
    }

    /// Single hops longer than this are GPS glitches and don't count.
    private static let trackMaxHopM = 60.0

    /// Σ haversine within segments — never across the holes between them.
    static func segmentsDistanceKm(_ segments: [[GpsRow]]) -> Double {
        var m = 0.0
        for seg in segments {
            for i in 1..<seg.count {
                let hop = GpsMath.haversineM(seg[i-1].lat, seg[i-1].lon, seg[i].lat, seg[i].lon)
                if hop <= trackMaxHopM { m += hop }
            }
        }
        return m / 1000.0
    }

    /// >60 km/h on a pumpfoil is always a bad fix (same clip as `GpsMath`).
    private static let maxPlausibleSpeedKmh = 60.0
    /// Fix pair for the position cross-check: within ±1 s of the speed row…
    private static let fixWindowTicks = 100.0
    /// …spanning ≥0.5 s, so position jitter can't fake a huge derived speed.
    private static let minFixSpanTicks = 50.0
    /// Reported speed may exceed the chord-derived speed by ×3 + 5 km/h.
    private static let speedVsTrackFactor = 3.0
    private static let speedVsTrackFloorKmh = 5.0
    /// A ≥2 s hole in the valid-fix timeline is a signal blackout
    /// (antenna under water)…
    private static let blackoutGapTicks = 200.0
    /// …and no speed row within 10 s of one counts: while the antenna
    /// sinks, u-blox fabricates a smooth, self-consistent speed ramp WITH
    /// matching sliding positions and healthy quality flags (12 sats /
    /// HDOP 0.6 while reporting 5 → 27 km/h on a ~1.5 km/h swimmer,
    /// 11.7.2026 Ermioni ride), so neither quality gates nor the position
    /// cross-check can catch it — blackout adjacency is the one reliable
    /// signature.
    private static let blackoutPadTicks = 1_000.0

    /// Top speed for the footer stat, outlier-hardened: hard clip, blackout
    /// adjacency, and position consistency (the earliest/latest valid fix
    /// within ±1 s must span ≥0.5 s and move commensurately). Verified
    /// against the 11.7.2026 Ermioni ride, whose raw column peaked at a
    /// fantasy 27.1 km/h on a ~7 km/h session.
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
                                   distanceKm: Double, durMin: Double) {
        let rect = CGRect(x: 0, y: full.height - footerHeight, width: full.width, height: footerHeight)
        cg.setFillColor(UIColor(white: 0.06, alpha: 0.92).cgColor)
        cg.fill(rect)

        let pad: CGFloat = 28
        // Logo.
        let logoSide: CGFloat = footerHeight - pad * 2
        let logoRect = CGRect(x: pad, y: rect.minY + pad, width: logoSide, height: logoSide)
        if let logo = UIImage(named: "RideLogo") {
            let path = UIBezierPath(roundedRect: logoRect, cornerRadius: logoSide * 0.22)
            cg.saveGState(); path.addClip()
            logo.draw(in: logoRect)
            cg.restoreGState()
        }

        let textX = logoRect.maxX + 22
        let white = UIColor.white
        let dim = UIColor(white: 0.75, alpha: 1)

        // Line 1: product name.
        draw("Movement Logger", at: CGPoint(x: textX, y: rect.minY + pad - 2),
             font: .systemFont(ofSize: 40, weight: .bold), color: white)
        // Line 2: ride stats.
        let stats = String(format: "Top %.1f km/h   ·   %.2f km   ·   %.0f min",
                           topSpeed, distanceKm, max(durMin, 0))
        draw(stats, at: CGPoint(x: textX, y: rect.minY + pad + 48),
             font: .systemFont(ofSize: 30, weight: .medium), color: dim)
        // Line 3: source link.
        draw(sourceURL, at: CGPoint(x: textX, y: rect.minY + pad + 96),
             font: .monospacedSystemFont(ofSize: 27, weight: .regular),
             color: UIColor(red: 0.45, green: 0.8, blue: 1, alpha: 1))
    }

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
