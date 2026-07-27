import SwiftUI
import MapKit
import CoreLocation

/// Live race map — every rider streaming to the relay, plotted on the map with
/// their track and all their live data (speed + board angles + water + height +
/// battery). The iOS peer of the desktop Race tab; fed by `RaceViewer`.
struct RaceMapScreen: View {
    @State private var viewer = RaceViewer.shared
    @State private var rider = PhoneRider.shared
    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: String?
    @State private var now = Date()
    @State private var showSettings = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var riders: [RaceRider] { viewer.sorted }

    var body: some View {
        NavigationStack {
            Group {
                if riders.isEmpty {
                    ContentUnavailableView {
                        Label("No riders yet", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Start a session on the watch (it streams to the relay when away from the phone), or have riders stream to your relay server. Set the relay on the Live tab.")
                    }
                } else {
                    map
                }
            }
            .navigationTitle("Race")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: rider.tracking ? "figure.wave.circle.fill" : "figure.wave.circle")
                            .foregroundStyle(rider.tracking ? .green : .accentColor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { camera = .automatic } label: { Image(systemName: "scope") }
                        .disabled(riders.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showSettings) { RaceSettingsSheet() }
        .onAppear { viewer.start() }
        .onDisappear { viewer.stop() }
        .onReceive(tick) { now = $0 }
    }

    private var map: some View {
        Map(position: $camera, selection: $selected) {
            ForEach(riders) { rider in
                if let c = rider.coord {
                    if rider.trail.count > 1 {
                        MapPolyline(coordinates: rider.trail)
                            .stroke(Self.color(rider.id).opacity(rider.isStale(now) ? 0.35 : 0.9),
                                    lineWidth: 3)
                    }
                    Annotation(rider.id, coordinate: c) {
                        RiderDot(rider: rider, color: Self.color(rider.id), stale: rider.isStale(now))
                    }
                    .tag(rider.id)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .flat))   // satellite + labels, like the desktop imagery
        .safeAreaInset(edge: .bottom) { panel }
    }

    /// Live data card for the selected rider (or the only rider).
    @ViewBuilder private var panel: some View {
        let pick = selected ?? (riders.count == 1 ? riders.first?.id : nil)
        if let id = pick, let r = viewer.riders[id] {
            RiderPanel(rider: r, color: Self.color(id), now: now)
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    /// Stable per-rider colour from the name hash.
    static func color(_ name: String) -> Color {
        let hues: [Double] = [0.00, 0.58, 0.33, 0.09, 0.78, 0.50, 0.16, 0.90]
        var h = 5381
        for b in name.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return Color(hue: hues[abs(h) % hues.count], saturation: 0.85, brightness: 0.95)
    }
}

/// Map marker: a heading-rotated arrow in the rider's colour + a name/speed tag.
private struct RiderDot: View {
    let rider: RaceRider
    let color: Color
    let stale: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(rider.id)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.ultraThinMaterial, in: Capsule())
            Image(systemName: rider.deg.isFinite ? "location.north.fill" : "circle.fill")
                .font(.system(size: rider.deg.isFinite ? 20 : 12))
                .foregroundStyle(stale ? Color.gray : color)
                .rotationEffect(.degrees(rider.deg.isFinite ? rider.deg : 0))
                .shadow(radius: 1)
        }
        .opacity(stale ? 0.6 : 1)
    }
}

/// Bottom card: everything the rider is streaming.
private struct RiderPanel: View {
    let rider: RaceRider
    let color: Color
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(rider.id).fontWeight(.semibold)
                Spacer()
                Text(ageText).font(.caption2)
                    .foregroundStyle(rider.isStale(now) ? .orange : .secondary)
            }
            HStack(spacing: 6) {
                metric("SPEED", rider.kmh, "km/h", 1)
                if rider.hasBoard {
                    metric("PITCH", rider.pitch, "°", 0)
                    metric("ROLL", rider.roll, "°", 0)
                    metric("YAW", rider.yaw, "°", 0)
                } else {
                    metric("HDG", rider.deg, "°", 0)
                }
            }
            HStack(spacing: 6) {
                metric("WATER", rider.waterTempC ?? .nan, "°C", 1)
                metric("HEIGHT", rider.baroAltM, "m", 1)
                metric("ACC", rider.accM, "m", 0)
                metric("BATT", rider.battPct.map(Double.init) ?? .nan, "%", 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var ageText: String {
        let s = Int(now.timeIntervalSince(rider.lastUpdate))
        return s <= 1 ? "live" : "\(s)s ago"
    }

    private func metric(_ label: String, _ value: Double, _ unit: String, _ dp: Int) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value.isFinite ? String(format: "%.\(dp)f", value) : "—")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(unit).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Race settings — turn this phone into a rider (carry it instead of a watch)
/// and point everything at your relay server.
private struct RaceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rider = PhoneRider.shared
    @State private var motion = PhoneMotion.shared
    @State private var name = PhoneRider.shared.name
    @State private var host = WatchLive.shared.relayHost
    @State private var port = String(WatchLive.shared.relayPort)
    @State private var token = RaceUplink.shared.token

    var body: some View {
        NavigationStack {
            Form {
                Section("Track this phone") {
                    Toggle("Show this phone on the race map", isOn: Binding(
                        get: { rider.tracking },
                        set: { PhoneRider.shared.tracking = $0 }))
                    TextField("Rider name", text: $name)
                        .autocorrectionDisabled()
                    Text("Carry the phone instead of a watch — it streams its GPS to the relay as a rider. The name defaults to this device's name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Board-mounted") {
                    Toggle("Stream board angles + height", isOn: Binding(
                        get: { rider.boardMounted },
                        set: { PhoneRider.shared.boardMounted = $0 }))
                    if rider.boardMounted {
                        HStack {
                            angleReadout("PITCH", motion.anglesLive ? motion.pitchDeg : nil)
                            angleReadout("ROLL", motion.anglesLive ? motion.rollDeg : nil)
                            angleReadout("YAW", motion.anglesLive ? motion.yawDeg : nil)
                        }
                        Button {
                            if motion.hasZero { PhoneMotion.shared.clearZero() }
                            else { PhoneMotion.shared.zero() }
                        } label: {
                            Label(motion.hasZero ? "Clear zero" : "Zero here",
                                  systemImage: motion.hasZero ? "xmark.circle" : "scope")
                        }
                    }
                    Text("Only for a phone strapped to the board — reads its motion sensors for pitch/roll/yaw + height. A carried phone should leave this off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Relay server") {
                    TextField("host", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("port", text: $port).keyboardType(.numberPad)
                    TextField("race token (optional)", text: $token)
                        .autocorrectionDisabled()
                    Text("Run your own race-relay and point everything at it. Shared with the watch and the map. Blank host resets to the default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Race settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { applyAndDismiss() }
                }
            }
        }
    }

    private func angleReadout(_ label: String, _ deg: Double?) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(deg.map { String(format: "%.0f°", $0) } ?? "—")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func applyAndDismiss() {
        PhoneRider.shared.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        WatchLive.shared.relayHost = h.isEmpty ? WatchLive.defaultRelayHost : h
        if let p = Int(port.trimmingCharacters(in: .whitespaces)), p > 0 {
            WatchLive.shared.relayPort = p
        }
        RaceUplink.shared.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        RaceViewer.shared.restartIfActive()   // pick up the new relay / token
        dismiss()
    }
}
