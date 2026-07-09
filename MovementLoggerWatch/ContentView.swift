import SwiftUI

struct ContentView: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                durationView
                statusView
                if controller.isRunning, controller.source == .watchGPS {
                    gpsDetail
                }
                startStopButton
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .navigationTitle("MovementLogger")
    }

    // MARK: - Duration

    @ViewBuilder private var durationView: some View {
        if controller.isRunning, let start = controller.sessionStart {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Self.hms(context.date.timeIntervalSince(start)))
                    .durationStyle(active: true)
            }
        } else {
            Text("00:00").durationStyle(active: false)
        }
    }

    // MARK: - Status line

    private var statusView: some View {
        Group {
            if controller.isRunning {
                Label("Logging · \(controller.source?.rawValue ?? "")",
                      systemImage: controller.source == .box ? "sensor.tile.radiowaves.left.and.right" : "location.fill")
                    .foregroundStyle(.green)
            } else {
                Text(controller.readiness)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
    }

    private var gpsDetail: some View {
        VStack(spacing: 2) {
            Text(controller.gps.status)
            Text("\(controller.gps.loggedRows) samples")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    // MARK: - Button

    private var startStopButton: some View {
        Button(action: { controller.toggle() }) {
            Text(controller.isRunning ? "End Session" : "Start Session")
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.isRunning ? .red : .green)
        .disabled(controller.phase == .starting || controller.phase == .stopping)
        .padding(.top, 2)
    }

    // MARK: - Format

    static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}

private extension View {
    func durationStyle(active: Bool) -> some View {
        self.font(.system(size: 42, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
}

#Preview {
    ContentView()
        .environment(SessionController())
}
