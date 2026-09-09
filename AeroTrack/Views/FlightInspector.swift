import SwiftUI

struct FlightInspector: View {
    let track: FlightTrack
    let store: TrackerStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let current = store.isDemo ? (store.selected ?? track) : track
            let flight = current.flight
            let pose = current.pose(at: context.date)
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.isDemo ? "SYNTHETIC TEST FLIGHT" : "SELECTED AIRCRAFT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.6).foregroundStyle(TrackerTheme.accent)
                        Text(flight.callsign).font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("\(flight.registration) · \(flight.aircraftType)").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Button { store.overview() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28).background(.white.opacity(0.08), in: Circle())
                    }.accessibilityLabel("Deselect aircraft")
                }
                HStack(spacing: 0) {
                    metric("ALTITUDE", value: (pose.altitude / 0.3048).formatted(.number.precision(.fractionLength(0))), unit: "ft")
                    Spacer()
                    metric("GROUND SPEED", value: flight.speedKnots.formatted(.number.precision(.fractionLength(0))), unit: "kt")
                    Spacer()
                    metric("VERTICAL", value: flight.verticalRate.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())), unit: "ft/m")
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 12) {
                    AttitudeIndicator(pitch: pose.pitch, roll: pose.roll).frame(width: 65, height: 65).accessibilityHidden(true)
                    HStack(alignment: .top, spacing: 0) {
                        attitude("YAW", value: pose.heading, source: flight.trueHeading == nil ? (flight.hasTrack ? "Track est." : "Unknown · 0°") : "True hdg.")
                        attitude("PITCH", value: pose.pitch, source: flight.hasVerticalRate ? "Path est." : "Unknown · 0°")
                        attitude("ROLL", value: pose.roll, source: flight.roll == nil ? (flight.trackRate == nil ? "Unknown · 0°" : "Turn est.") : "Reported")
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        if store.isFollowing { store.isFollowing = false }
                        else { store.select(flight.id) }
                    } label: {
                        Label(store.isFollowing ? "Following" : "Follow aircraft", systemImage: store.isFollowing ? "location.fill" : "location")
                            .font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .foregroundStyle(store.isFollowing ? TrackerTheme.ink : .white)
                    .background(store.isFollowing ? TrackerTheme.accent : .white.opacity(0.08), in: .rect(cornerRadius: 11))
                    Button { store.showSettings = true } label: {
                        Text("\(Int(store.modelScale))× model").font(.system(size: 11, weight: .semibold, design: .monospaced)).padding(12)
                    }.background(.white.opacity(0.07), in: .rect(cornerRadius: 11))
                }
                Text(store.isDemo ? "Demo attitude · scale affects model size only" : "\(max(0, Int(context.date.timeIntervalSince(flight.observedAt))))s since position · pitch is flight path, not measured attitude")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.42)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(19).background(TrackerTheme.panel, in: .rect(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.08)))
        }
    }

    private func metric(_ label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.7).foregroundStyle(.white.opacity(0.4))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func attitude(_ label: String, value: Double, source: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            Text("\(value.formatted(.number.precision(.fractionLength(1))))°").font(.system(size: 17, weight: .medium, design: .monospaced)).monospacedDigit()
            Text(source).font(.system(size: 8)).foregroundStyle(TrackerTheme.accent.opacity(0.7))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AttitudeIndicator: View {
    let pitch: Double
    let roll: Double

    var body: some View {
        ZStack {
            Canvas { context, size in
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.rotate(by: .degrees(-roll))
                context.translateBy(x: 0, y: pitch * 1.3)
                context.fill(Path(CGRect(x: -100, y: -150, width: 200, height: 150)), with: .color(Color(red: 0.12, green: 0.31, blue: 0.42)))
                context.fill(Path(CGRect(x: -100, y: 0, width: 200, height: 150)), with: .color(Color(red: 0.17, green: 0.21, blue: 0.23)))
                var line = Path(); line.move(to: CGPoint(x: -100, y: 0)); line.addLine(to: CGPoint(x: 100, y: 0))
                context.stroke(line, with: .color(.white.opacity(0.6)), lineWidth: 1)
                for y in [-20.0, -10, 10, 20] {
                    var tick = Path(); tick.move(to: CGPoint(x: -8, y: y)); tick.addLine(to: CGPoint(x: 8, y: y))
                    context.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 1)
                }
            }
            HStack(spacing: 3) {
                Rectangle().frame(width: 13, height: 2)
                Circle().frame(width: 4, height: 4)
                Rectangle().frame(width: 13, height: 2)
            }.foregroundStyle(TrackerTheme.accent)
        }.clipShape(Circle()).overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 2))
    }
}
