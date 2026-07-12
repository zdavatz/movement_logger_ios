#!/usr/bin/env swift
// Standalone macOS renderer: reads a Watch/box GPS CSV and produces a
// shareable PNG — real Apple Maps tiles under an activity-coloured track, with
// the app logo, ride stats, a legend, and the GitHub source link in a footer.
// Mirrors the in-app `RideMapRenderer` (MovementLogger/UI/RideMap.swift):
//
//  - ONE continuous line (no hole-splitting): valid fixes, stall-duplicates
//    collapsed, 1-sample GPS spikes removed, gaps bridged (the accuracy gate
//    already removes the only across-town outlier).
//  - Coloured by inferred activity when the ride carries the Ultra's
//    `WaterTemp [C]` submersion column: wet + slow → In water (blue),
//    ≥6 km/h → On board (green), dry + slow → On land (orange).
//  - Rides with no submersion column can't tell water from land, so they
//    degrade to a speed gradient (blue slow → red fast) with a note.
//
// Usage: swift scripts/ride_map_png.swift <in.csv> <out.png> [logo.png]

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

struct Row { let ticks: Double; let utc: String; let lat: Double; let lon: Double; let speed: Double; let fix: Int; let hdop: Double; let waterTemp: Double }

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
let iWt  = col(["WaterTemp [C]"]) ?? -1

var rows: [Row] = []
for line in lines {
    let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard f.count > max(iLat, iLon), let lat = Double(f[iLat]), let lon = Double(f[iLon]) else { continue }
    let sp = (iSpd >= 0 && iSpd < f.count) ? (Double(f[iSpd]) ?? 0) : 0
    let fx = (iFix >= 0 && iFix < f.count) ? (Int(f[iFix]) ?? 1) : 1
    let tk = (iT < f.count ? (Double(f[iT]) ?? 0) : 0) / tickDiv
    let ut = (iUtc >= 0 && iUtc < f.count) ? f[iUtc] : ""
    let hd = (iHdp >= 0 && iHdp < f.count) ? (Double(f[iHdp]) ?? .nan) : .nan
    let wt = (iWt >= 0 && iWt < f.count) ? (Double(f[iWt]) ?? .nan) : .nan
    rows.append(Row(ticks: tk, utc: ut, lat: lat, lon: lon, speed: sp, fix: fx, hdop: hd, waterTemp: wt))
}

// ---- clean into ONE continuous track (mirror RideMapRenderer.cleanTrack) --
func haversineM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let R = 6_371_000.0, dLat = (b.latitude - a.latitude) * .pi/180, dLon = (b.longitude - a.longitude) * .pi/180
    let s = sin(dLat/2)*sin(dLat/2) + cos(a.latitude * .pi/180)*cos(b.latitude * .pi/180)*sin(dLon/2)*sin(dLon/2)
    return 2*R*asin(min(1, sqrt(s)))
}
func hav(_ a: Row, _ b: Row) -> Double {
    haversineM(CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
               CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon))
}
// Valid fixes: fix>0, finite, not null island, not flagged-inaccurate (>50 m).
let validRaw = rows.filter { $0.fix > 0 && $0.lat.isFinite && $0.lon.isFinite
    && !($0.lat == 0 && $0.lon == 0) && !($0.hdop > 50) }
// Collapse consecutive identical fixes (watch stall duplicates).
var deduped: [Row] = []
for f in validRaw {
    if let p = deduped.last, p.utc == f.utc, p.lat == f.lat, p.lon == f.lon { continue }
    deduped.append(f)
}
// Drop isolated single-sample spikes (100–380 km/h implied glitches).
let spikeHopM = 45.0, spikeMaxDt = 2.5
var keep = [Bool](repeating: true, count: deduped.count)
if deduped.count >= 3 {
    for i in 1..<deduped.count-1 {
        let a = deduped[i-1], b = deduped[i], c = deduped[i+1]
        let dtIn = (b.ticks - a.ticks)*0.01, dtOut = (c.ticks - b.ticks)*0.01
        guard dtIn <= spikeMaxDt, dtOut <= spikeMaxDt else { continue }
        if hav(a,b) > spikeHopM && hav(b,c) > spikeHopM && hav(a,c) < spikeHopM { keep[i] = false }
    }
}
let pts = zip(deduped, keep).filter { $0.1 }.map { $0.0 }
guard pts.count >= 2 else { FileHandle.standardError.write("need >=2 valid fixes (got \(pts.count))\n".data(using: .utf8)!); exit(1) }
// Teleport breaks (safety valve — none in practice after the accuracy gate).
let teleportBreakM = 200.0
var breaks = Set<Int>()
for i in 1..<pts.count where hav(pts[i-1], pts[i]) > teleportBreakM { breaks.insert(i) }
let coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
FileHandle.standardError.write("parsed \(rows.count) rows, \(pts.count) clean fixes, \(breaks.count) break(s)\n".data(using: .utf8)!)

// ---- activity classification ---------------------------------------------
let submerged = pts.contains { $0.waterTemp.isFinite }
// Median filter (window 5) for speed smoothing.
func rollMed(_ x: [Double], _ w: Int) -> [Double] {
    let half = w/2
    return x.indices.map { i in
        let lo = max(0, i-half), hi = min(x.count, i+half+1)
        let s = x[lo..<hi].filter { $0.isFinite }.sorted()
        return s.isEmpty ? x[i] : s[s.count/2]
    }
}
// Merge runs of equal keys shorter than minRunSec into their longer neighbour.
func smoothKeys(_ keys: [Int], _ ticks: [Double], _ minRunSec: Double) -> [Int] {
    guard keys.count > 1 else { return keys }
    var runs: [(s: Int, e: Int, k: Int)] = []
    var s = 0
    for i in 1...keys.count where i == keys.count || keys[i] != keys[s] { runs.append((s, i, keys[s])); s = i }
    func dur(_ r: (s: Int, e: Int, k: Int)) -> Double { (ticks[r.e-1] - ticks[r.s]) * 0.01 }
    while runs.count > 1 {
        var idx = -1, shortest = minRunSec
        for (i, r) in runs.enumerated() where dur(r) < shortest { shortest = dur(r); idx = i }
        if idx < 0 { break }
        let left = idx > 0 ? runs[idx-1] : nil, right = idx < runs.count-1 ? runs[idx+1] : nil
        if let l = left, let r = right { runs[idx].k = dur(l) >= dur(r) ? l.k : r.k }
        else if let l = left { runs[idx].k = l.k }
        else if let r = right { runs[idx].k = r.k }
        else { break }
        var merged: [(s: Int, e: Int, k: Int)] = []
        for r in runs {
            if var last = merged.last, last.k == r.k { last.e = r.e; merged[merged.count-1] = last }
            else { merged.append(r) }
        }
        runs = merged
    }
    var out = [Int](repeating: 0, count: keys.count)
    for r in runs where r.s < r.e { for i in r.s..<r.e { out[i] = r.k } }
    return out
}
let boardKmh = 6.0
let ticksArr = pts.map { $0.ticks }
let smoothSpeed = rollMed(pts.map { $0.speed }, 5)
// Mode keys: 0=swim(blue) 1=board(green) 2=land(orange).
let modeColors: [NSColor] = [
    NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.42, alpha: 1),
    NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.13, alpha: 1)]
let modeLabels = ["In water", "On board", "On land"]
var modes: [Int] = []
if submerged {
    let raw = pts.indices.map { i -> Int in
        if smoothSpeed[i] >= boardKmh { return 1 }
        return pts[i].waterTemp.isFinite ? 0 : 2
    }
    modes = smoothKeys(raw, ticksArr, 20)
}
// Speed scale for the gradient fallback.
let sortedSp = pts.map { $0.speed }.filter { $0.isFinite && $0 >= 0 }.sorted()
let vMax = max(sortedSp.isEmpty ? 5 : sortedSp[Int(Double(sortedSp.count-1)*0.95)], 5)
func speedColor(_ speed: Double) -> NSColor {
    let t = min(max(speed/vMax, 0), 1); let hue = (1-t)*0.66
    return NSColor(calibratedHue: CGFloat(hue), saturation: 0.9, brightness: 0.95, alpha: 1)
}
func edgeColor(_ i: Int) -> NSColor { submerged ? modeColors[modes[i]] : speedColor(smoothSpeed[i]) }

// ---- stats ---------------------------------------------------------------
var distM = 0.0
for i in 1..<pts.count where !breaks.contains(i) {
    let d = hav(pts[i-1], pts[i]); if d <= 60 { distM += d }
}
let distanceKm = distM/1000
// Outlier-hardened top speed (port of RideMap.robustTopSpeed).
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
        let chordKmh = hav(valid[a], valid[b]) / ((ft[b] - ft[a]) / 100.0) * 3.6
        if v <= chordKmh * 3 + 5 { top = v }
    }
    return top
}
let topSpeed = robustTopSpeed(rows, deduped)
let durMin = (pts.last!.ticks - pts.first!.ticks) * 0.01 / 60.0

// ---- region --------------------------------------------------------------
var rect = MKMapRect.null
for c in coords { let p = MKMapPoint(c); rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
let padX = max(rect.size.width*0.18, rect.size.width == 0 ? 4000 : 0)
let padY = max(rect.size.height*0.18, rect.size.height == 0 ? 4000 : 0)
rect = rect.insetBy(dx: -padX, dy: -padY)

let W: CGFloat = 1080, mapH: CGFloat = 1440, footerH: CGFloat = 240
let H = mapH + footerH
let opts = MKMapSnapshotter.Options()
opts.region = MKCoordinateRegion(rect)
opts.size = CGSize(width: W, height: mapH)
let renderScale: CGFloat = 2   // macOS Options has no `scale`; upscale the bitmap ourselves
opts.mapType = .standard
opts.showsBuildings = true
opts.pointOfInterestFilter = .excludingAll

// ---- snapshot (async → block on run loop) --------------------------------
let snapshotter = MKMapSnapshotter(options: opts)
var done = false
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

    // White casing — one continuous sub-path per non-broken stretch.
    let casing = NSBezierPath(); casing.lineWidth = 9; casing.lineCapStyle = .round; casing.lineJoinStyle = .round
    var started = false
    for i in 0..<px.count {
        if i > 0 && breaks.contains(i) { started = false }
        if !started { casing.move(to: px[i]); started = true } else { casing.line(to: px[i]) }
    }
    NSColor.white.withAlphaComponent(0.9).setStroke(); casing.stroke()
    // Coloured track, edge by edge (skip teleport breaks).
    for i in 1..<px.count where !breaks.contains(i) {
        let seg = NSBezierPath(); seg.lineWidth = 5; seg.lineCapStyle = .round
        seg.move(to: px[i-1]); seg.line(to: px[i])
        edgeColor(i).setStroke(); seg.stroke()
    }
    // Start / end markers.
    func marker(_ p: NSPoint, _ color: NSColor) {
        let r: CGFloat = 13
        let e = NSBezierPath(ovalIn: NSRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2))
        color.setFill(); e.fill(); NSColor.white.setStroke(); e.lineWidth = 4; e.stroke()
    }
    marker(px.first!, .systemGreen); marker(px.last!, .systemRed)

    // Footer band (y 0..footerH). AppKit is y-up: high y = top of the footer.
    NSColor(calibratedWhite: 0.06, alpha: 0.95).setFill(); NSRect(x: 0, y: 0, width: W, height: footerH).fill()
    let pad: CGFloat = 28
    let dim = NSColor(calibratedWhite: 0.7, alpha: 1)
    func draw(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: f, .foregroundColor: color])
    }
    func width(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    // 1. Legend as a horizontal strip across the TOP of the footer — its own
    //    band, so it never collides with the (long) source-URL line.
    let legY = footerH - 44
    if submerged {
        let present = [0,1,2].filter { modes.contains($0) }
        draw("Activity", x: pad, y: legY, size: 25, weight: .semibold, color: NSColor(calibratedWhite: 0.85, alpha: 1))
        var x = pad + 170
        for m in present {
            modeColors[m].setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: legY + 2, width: 22, height: 22)).fill()
            draw(modeLabels[m], x: x + 30, y: legY, size: 25, weight: .regular, color: .white)
            x += 30 + width(modeLabels[m], 25, .regular) + 46
        }
    } else {
        draw("Speed", x: pad, y: legY, size: 25, weight: .semibold, color: NSColor(calibratedWhite: 0.85, alpha: 1))
        let barX = pad + 150, barW: CGFloat = 360, barH: CGFloat = 22, steps = 60
        for s in 0..<steps {
            let t = Double(s)/Double(steps-1)
            NSColor(calibratedHue: CGFloat((1-t)*0.66), saturation: 0.9, brightness: 0.95, alpha: 1).setFill()
            NSRect(x: barX + CGFloat(t)*barW, y: legY + 2, width: barW/CGFloat(steps)+1, height: barH).fill()
        }
        draw(String(format: "0 – %.0f km/h  ·  no submersion data", vMax),
             x: barX + barW + 22, y: legY, size: 25, weight: .regular, color: dim)
    }
    NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
    NSRect(x: pad, y: footerH - 66, width: W - pad*2, height: 1).fill()

    // 2. Content row below the strip: logo + three text lines.
    let logoSide: CGFloat = 130
    let logoRect = NSRect(x: pad, y: footerH - 84 - logoSide, width: logoSide, height: logoSide)
    if let lp = logoPath, let logo = NSImage(contentsOfFile: lp) {
        let clip = NSBezierPath(roundedRect: logoRect, xRadius: logoSide*0.22, yRadius: logoSide*0.22)
        NSGraphicsContext.saveGraphicsState(); clip.addClip()
        logo.draw(in: logoRect); NSGraphicsContext.restoreGraphicsState()
    }
    let textX = logoRect.maxX + 22
    draw("Movement Logger", x: textX, y: footerH - 128, size: 40, weight: .bold, color: .white)
    let stats = String(format: "Top %.1f km/h   ·   %.2f km   ·   %.0f min", topSpeed, distanceKm, max(durMin,0))
    draw(stats, x: textX, y: footerH - 174, size: 30, weight: .medium, color: NSColor(calibratedWhite: 0.78, alpha: 1))
    draw(sourceURL, x: textX, y: footerH - 218, size: 27, weight: .regular,
         color: NSColor(calibratedRed: 0.45, green: 0.8, blue: 1, alpha: 1), mono: true)

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write("wrote \(outPath) (\(pxW)x\(pxH))\n".data(using: .utf8)!)
    }
}

let deadline = Date().addingTimeInterval(60)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
if !done { FileHandle.standardError.write("timed out waiting for snapshot\n".data(using: .utf8)!); exit(1) }
