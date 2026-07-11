#!/usr/bin/env swift
// Standalone macOS renderer: reads a Watch/box GPS CSV and produces a
// shareable PNG — real Apple Maps tiles under a speed-coloured track, with the
// app logo, ride stats, and the GitHub source link in a footer. Mirrors the
// in-app `RideMapRenderer` (MovementLogger/UI/RideMap.swift). Usage:
//   swift scripts/ride_map_png.swift <in.csv> <out.png> [logo.png]

import Foundation
import MapKit
import AppKit
import CoreLocation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: ride_map_png.swift <in.csv> <out.png> [logo.png]\n".data(using: .utf8)!)
    exit(2)
}
let csvPath = args[1]
let outPath = args[2]
let logoPath = args.count >= 4 ? args[3] : nil
let sourceURL = "github.com/zdavatz/movement_logger_ios"

struct Row { let ticks: Double; let utc: String; let lat: Double; let lon: Double; let speed: Double; let fix: Int; let hdop: Double }

// ---- parse CSV (exact-header map, tolerant of bad rows) ------------------
guard let text = try? String(contentsOfFile: csvPath, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(csvPath)\n".data(using: .utf8)!); exit(1)
}
var lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
guard !lines.isEmpty else { exit(1) }
let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
func col(_ names: [String]) -> Int? { for n in names { if let i = header.firstIndex(of: n) { return i } }; return nil }
let iT = col(["ms", "Time [10ms]", "Time [mS]"]) ?? 0
let tickDiv = header.contains("ms") ? 10.0 : 1.0
let iLat = col(["Lat [deg]", "Lat", "lat"])!
let iLon = col(["Lon [deg]", "Lon", "lon"])!
let iSpd = col(["SpeedKMh", "Speed [km/h]", "speed_kmh"]) ?? -1
let iFix = col(["Fix", "fix_q"]) ?? -1
let iUtc = col(["UTC", "utc"]) ?? -1
let iHdp = col(["HDOP", "hdop"]) ?? -1

var rows: [Row] = []
for line in lines {
    let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard f.count > max(iLat, iLon), let lat = Double(f[iLat]), let lon = Double(f[iLon]) else { continue }
    let sp = (iSpd >= 0 && iSpd < f.count) ? (Double(f[iSpd]) ?? 0) : 0
    let fx = (iFix >= 0 && iFix < f.count) ? (Int(f[iFix]) ?? 1) : 1
    let tk = (iT < f.count ? (Double(f[iT]) ?? 0) : 0) / tickDiv
    let ut = (iUtc >= 0 && iUtc < f.count) ? f[iUtc] : ""
    let hd = (iHdp >= 0 && iHdp < f.count) ? (Double(f[iHdp]) ?? .nan) : .nan
    rows.append(Row(ticks: tk, utc: ut, lat: lat, lon: lon, speed: sp, fix: fx, hdop: hd))
}
// Valid fixes: fix>0, finite, not null island, not flagged-inaccurate.
let validRaw = rows.filter { $0.fix > 0 && $0.lat.isFinite && $0.lon.isFinite
    && !($0.lat == 0 && $0.lon == 0) && !($0.hdop > 50) }
// Collapse consecutive identical fixes (watch stall duplicates) so a dead
// receiver's rewritten last-known rows read as a hole, not a live timeline.
var fixesD: [Row] = []
for f in validRaw {
    if let p = fixesD.last, p.utc == f.utc, p.lat == f.lat, p.lon == f.lon { continue }
    fixesD.append(f)
}
guard fixesD.count >= 2 else { FileHandle.standardError.write("need >=2 valid fixes (got \(fixesD.count))\n".data(using: .utf8)!); exit(1) }
// Blackout zones: leading convergence, every >=2 s fix hole (+-10 s pad), trailing.
let ftAll = fixesD.map { $0.ticks }
var zonesG: [(Double, Double)] = [(-.infinity, ftAll[0] + 1000)]
for i in 1..<ftAll.count where ftAll[i] - ftAll[i-1] >= 200 { zonesG.append((ftAll[i-1] - 1000, ftAll[i] + 1000)) }
zonesG.append((ftAll.last! + 1e-9, .infinity))
// Cleaned per-segment track: no fabricated positions, no bridging lines.
var segments: [[Row]] = []
var curSeg: [Row] = []
for f in fixesD {
    if zonesG.contains(where: { f.ticks >= $0.0 && f.ticks <= $0.1 }) { continue }
    if let last = curSeg.last, f.ticks - last.ticks >= 200 {
        if curSeg.count >= 2 { segments.append(curSeg) }
        curSeg = []
    }
    curSeg.append(f)
}
if curSeg.count >= 2 { segments.append(curSeg) }
let valid = segments.flatMap { $0 }
guard valid.count >= 2 else { FileHandle.standardError.write("no clean track segments\n".data(using: .utf8)!); exit(1) }
let coords = valid.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
FileHandle.standardError.write("parsed \(rows.count) rows, \(valid.count) clean fixes in \(segments.count) segment(s)\n".data(using: .utf8)!)

// ---- stats ---------------------------------------------------------------
func haversineM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let R = 6_371_000.0, dLat = (b.latitude - a.latitude) * .pi/180, dLon = (b.longitude - a.longitude) * .pi/180
    let s = sin(dLat/2)*sin(dLat/2) + cos(a.latitude * .pi/180)*cos(b.latitude * .pi/180)*sin(dLon/2)*sin(dLon/2)
    return 2*R*asin(min(1, sqrt(s)))
}
var distM = 0.0
for seg in segments {
    for i in 1..<seg.count {
        let d = haversineM(CLLocationCoordinate2D(latitude: seg[i-1].lat, longitude: seg[i-1].lon),
                           CLLocationCoordinate2D(latitude: seg[i].lat, longitude: seg[i].lon))
        if d <= 60 { distM += d }   // single-hop glitch gate
    }
}
let distanceKm = distM/1000
let speeds = valid.map { $0.speed }
// Outlier-hardened top speed (port of RideMap.robustTopSpeed): hard clip,
// blackout adjacency (no speed within 10 s of a >=2 s hole in the fix
// timeline — u-blox fabricates self-consistent speed ramps while the
// antenna sinks), and position consistency vs. the +-1 s fix chord.
func robustTopSpeed(_ rows: [Row], _ valid: [Row]) -> Double {
    guard valid.count >= 2 else { return 0 }
    let ft = valid.map { $0.ticks }
    var zones: [(Double, Double)] = [(-.infinity, ft[0] + 1000)]
    for i in 1..<ft.count where ft[i] - ft[i-1] >= 200 { zones.append((ft[i-1] - 1000, ft[i] + 1000)) }
    zones.append((ft.last! + 1e-9, .infinity))
    func lowerBound(_ key: Double) -> Int {
        var lo = 0, hi = ft.count
        while lo < hi { let m = (lo + hi) / 2; if ft[m] < key { lo = m + 1 } else { hi = m } }
        return lo
    }
    var top = 0.0
    for r in rows {
        let v = r.speed
        guard v.isFinite, v >= 0, v <= 60, v > top, r.ticks.isFinite else { continue }
        if zones.contains(where: { r.ticks >= $0.0 && r.ticks <= $0.1 }) { continue }
        let a = lowerBound(r.ticks - 100), b = lowerBound(r.ticks + 100 + 1e-9) - 1
        guard b > a, ft[b] - ft[a] >= 50 else { continue }
        let chordKmh = haversineM(CLLocationCoordinate2D(latitude: valid[a].lat, longitude: valid[a].lon),
                                  CLLocationCoordinate2D(latitude: valid[b].lat, longitude: valid[b].lon))
            / ((ft[b] - ft[a]) / 100.0) * 3.6
        if v <= chordKmh * 3 + 5 { top = v }
    }
    return top
}
let topSpeed = robustTopSpeed(rows, fixesD)
let durMin = (valid.last!.ticks - valid.first!.ticks) * 0.01 / 60.0
let sortedSp = speeds.filter { $0.isFinite && $0 >= 0 }.sorted()
let vMax = max(sortedSp.isEmpty ? 5 : sortedSp[Int(Double(sortedSp.count-1)*0.95)], 5)

// ---- region --------------------------------------------------------------
var rect = MKMapRect.null
for c in coords { let p = MKMapPoint(c); rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
let padX = max(rect.size.width*0.18, rect.size.width == 0 ? 4000 : 0)
let padY = max(rect.size.height*0.18, rect.size.height == 0 ? 4000 : 0)
rect = rect.insetBy(dx: -padX, dy: -padY)

let W: CGFloat = 1080, mapH: CGFloat = 1440, footerH: CGFloat = 190
let H = mapH + footerH
let opts = MKMapSnapshotter.Options()
opts.region = MKCoordinateRegion(rect)
opts.size = CGSize(width: W, height: mapH)
let renderScale: CGFloat = 2   // macOS Options has no `scale`; upscale the bitmap ourselves
opts.mapType = .standard
opts.showsBuildings = true
opts.pointOfInterestFilter = .excludingAll

func speedColor(_ speed: Double) -> NSColor {
    let t = min(max(speed/vMax, 0), 1); let hue = (1-t)*0.66
    return NSColor(hue: CGFloat(hue), saturation: 0.9, brightness: 0.95, alpha: 1)
}

// ---- snapshot (async → block on run loop) --------------------------------
let snapshotter = MKMapSnapshotter(options: opts)
var done = false
var resultImage: NSImage?
snapshotter.start(with: DispatchQueue.global(qos: .userInitiated)) { snap, err in
    defer { done = true }
    guard let snap = snap else { FileHandle.standardError.write("snapshot failed: \(String(describing: err))\n".data(using: .utf8)!); return }
    let scale = renderScale
    let pxW = Int(W*scale), pxH = Int(H*scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: W, height: H)
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx

    // Map tiles occupy the TOP of the canvas. AppKit is y-up, so the map's
    // bottom edge sits at y = footerH.
    snap.image.draw(in: NSRect(x: 0, y: footerH, width: W, height: mapH))

    // snap.point(for:) is relative to the map image's upper-left (y-down);
    // convert to this y-up canvas: y = footerH + (mapH - p.y).
    func canvasPoint(_ c: CLLocationCoordinate2D) -> NSPoint {
        let p = snap.point(for: c)
        return NSPoint(x: p.x, y: footerH + (mapH - p.y))
    }
    let px = coords.map(canvasPoint)

    // White casing.
    let casing = NSBezierPath(); casing.lineWidth = 9; casing.lineCapStyle = .round; casing.lineJoinStyle = .round
    var offC = 0
    for seg in segments {
        casing.move(to: px[offC])
        for i in 1..<seg.count { casing.line(to: px[offC + i]) }
        offC += seg.count
    }
    NSColor.white.withAlphaComponent(0.9).setStroke(); casing.stroke()
    // Speed-coloured segments — never across a blackout hole.
    var offS = 0
    for segRun in segments {
        for i in 1..<segRun.count {
            let seg = NSBezierPath(); seg.lineWidth = 5; seg.lineCapStyle = .round
            seg.move(to: px[offS + i - 1]); seg.line(to: px[offS + i])
            speedColor(speeds[offS + i]).setStroke(); seg.stroke()
        }
        offS += segRun.count
    }
    // Start / end markers.
    func marker(_ p: NSPoint, _ color: NSColor) {
        let r: CGFloat = 13
        let e = NSBezierPath(ovalIn: NSRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2))
        color.setFill(); e.fill(); NSColor.white.setStroke(); e.lineWidth = 4; e.stroke()
    }
    marker(px.first!, .systemGreen); marker(px.last!, .systemRed)

    // Footer band (y 0..footerH).
    NSColor(white: 0.06, alpha: 0.95).setFill(); NSRect(x: 0, y: 0, width: W, height: footerH).fill()
    let pad: CGFloat = 28
    let logoSide = footerH - pad*2
    let logoRect = NSRect(x: pad, y: pad, width: logoSide, height: logoSide)
    if let lp = logoPath, let logo = NSImage(contentsOfFile: lp) {
        let clip = NSBezierPath(roundedRect: logoRect, xRadius: logoSide*0.22, yRadius: logoSide*0.22)
        NSGraphicsContext.saveGraphicsState(); clip.addClip()
        logo.draw(in: logoRect); NSGraphicsContext.restoreGraphicsState()
    }
    let textX = logoRect.maxX + 22
    func draw(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        (s as NSString).draw(at: NSPoint(x: textX, y: y), withAttributes: [.font: f, .foregroundColor: color])
    }
    // y-up: top line highest.
    draw("Movement Logger", y: footerH - pad - 42, size: 40, weight: .bold, color: .white)
    let stats = String(format: "Top %.1f km/h   ·   %.2f km   ·   %.0f min", topSpeed, distanceKm, max(durMin,0))
    draw(stats, y: footerH - pad - 88, size: 30, weight: .medium, color: NSColor(white: 0.78, alpha: 1))
    draw(sourceURL, y: footerH - pad - 132, size: 27, weight: .regular,
         color: NSColor(red: 0.45, green: 0.8, blue: 1, alpha: 1), mono: true)

    NSGraphicsContext.restoreGraphicsState()
    resultImage = NSImage(size: NSSize(width: W, height: H)); resultImage!.addRepresentation(rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write("wrote \(outPath) (\(pxW)x\(pxH))\n".data(using: .utf8)!)
    }
}

let deadline = Date().addingTimeInterval(60)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
if !done { FileHandle.standardError.write("timed out waiting for snapshot\n".data(using: .utf8)!); exit(1) }
