import Foundation
import Observation
import Network
import CoreLocation

/// One tracked rider on the race map — latest fix + live data + a trail.
struct RaceRider: Identifiable {
    let id: String                 // rider name (the datagram's `rider`)
    var lat = Double.nan
    var lon = Double.nan
    var kmh = Double.nan
    var deg = Double.nan
    var accM = Double.nan
    var battPct: Int?
    // Board data — present when the rider streams board snapshots (typ:"board").
    var pitch = Double.nan
    var roll = Double.nan
    var yaw = Double.nan
    var waterTempC: Double?
    var baroAltM = Double.nan
    var hasBoard = false
    var lastUpdate = Date()
    var trail: [CLLocationCoordinate2D] = []

    var coord: CLLocationCoordinate2D? {
        lat.isFinite && lon.isFinite ? .init(latitude: lat, longitude: lon) : nil
    }
    /// A rider whose last fix is old renders greyed — a capsized rider's last
    /// position stays on the map (same as the desktop).
    func isStale(_ now: Date) -> Bool { now.timeIntervalSince(lastUpdate) > 12 }
}

/// Live multi-rider race map source — a relay *viewer* that subscribes to the
/// (user-configurable) `race-relay` and tracks every rider streaming to it:
/// position from race fixes, board angles from board snapshots, merged by rider
/// name. The iOS peer of the desktop Race tab (`race.rs`). Reuses the live
/// view's relay endpoint (`WatchLive.relayHost/relayPort`) and the race token.
@Observable
final class RaceViewer {
    static let shared = RaceViewer()

    private(set) var riders: [String: RaceRider] = [:]
    var sorted: [RaceRider] { riders.values.sorted { $0.id < $1.id } }

    // Trail shaping — mirrors race.rs constants.
    private static let trailMax = 1500              // ~5 min at 5 Hz
    private static let trailMinStepM = 3.0          // dead-band
    private static let maxTrailAccM = 20.0          // worse fixes: dot only, no trail

    @ObservationIgnored private var conn: NWConnection?
    @ObservationIgnored private let q = DispatchQueue(label: "race-viewer")
    @ObservationIgnored private var keepalive: Timer?
    @ObservationIgnored private var active = false

    private init() {}

    func start() {
        stop()
        active = true
        let host = WatchLive.shared.relayHost
        let portN = WatchLive.shared.relayPort
        guard !host.isEmpty, portN > 0, let port = NWEndpoint.Port(rawValue: UInt16(clamping: portN)) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        c.stateUpdateHandler = { [weak self] st in if case .ready = st { self?.subscribe() } }
        c.start(queue: q)
        conn = c
        receiveLoop()
        keepalive?.invalidate()
        keepalive = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.subscribe() }
    }

    func stop() {
        active = false
        keepalive?.invalidate(); keepalive = nil
        conn?.cancel(); conn = nil
    }

    /// Restart against the current relay endpoint (after a host/port change).
    func restartIfActive() { if active { start() } }

    private func subscribe() {
        let sub: [String: Any] = ["v": 1, "sub": true, "race": RaceUplink.shared.token]
        guard let d = try? JSONSerialization.data(withJSONObject: sub) else { return }
        conn?.send(content: d, completion: .idempotent)
    }

    private func receiveLoop() {
        conn?.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.ingest(obj)
            }
            if err == nil { self.receiveLoop() }
        }
    }

    private func ingest(_ obj: [String: Any]) {
        guard let rider = obj["rider"] as? String, !rider.isEmpty else { return }
        func num(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        DispatchQueue.main.async {
            var r = self.riders[rider] ?? RaceRider(id: rider)
            if let lat = num("lat"), let lon = num("lon"), lat.isFinite, lon.isFinite {
                let acc = num("acc") ?? .nan
                if r.lat.isFinite {
                    let moved = Self.distM(r.lat, r.lon, lat, lon)
                    if moved >= Self.trailMinStepM, !acc.isFinite || acc <= Self.maxTrailAccM {
                        r.trail.append(.init(latitude: lat, longitude: lon))
                        if r.trail.count > Self.trailMax { r.trail.removeFirst(r.trail.count - Self.trailMax) }
                    }
                } else {
                    r.trail.append(.init(latitude: lat, longitude: lon))
                }
                r.lat = lat; r.lon = lon; r.accM = acc
            }
            if let v = num("kmh") { r.kmh = v }
            if let v = num("deg") { r.deg = v }
            if let n = obj["batt"] as? NSNumber { r.battPct = n.intValue >= 0 ? n.intValue : nil }
            if (obj["typ"] as? String) == "board" {
                r.hasBoard = true
                if let v = num("p") { r.pitch = v }
                if let v = num("r") { r.roll = v }
                if let v = num("y") { r.yaw = v }
                if let v = num("wt") { r.waterTempC = v }
                if let v = num("alt") { r.baroAltM = v }
            }
            r.lastUpdate = Date()
            self.riders[rider] = r
        }
    }

    static func distM(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let R = 6_371_000.0, dLat = (la2 - la1) * .pi / 180, dLon = (lo2 - lo1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2)
            + cos(la1 * .pi/180) * cos(la2 * .pi/180) * sin(dLon/2) * sin(dLon/2)
        return 2 * R * atan2(sqrt(a), sqrt(1 - a))
    }
}
