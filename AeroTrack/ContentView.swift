import SwiftUI

struct ContentView: View {
    @State private var store = TrackerStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            AircraftMapView(store: store, isActive: scenePhase == .active)
                .ignoresSafeArea()
                .accessibilityLabel("Aircraft map. Use the Flights button to select an aircraft.")
            VStack(spacing: 14) {
                header
                HStack(alignment: .top) {
                    Label(store.modelsVisible ? "3D AIRCRAFT" : "ICON VIEW · ZOOM FOR 3D", systemImage: store.modelsVisible ? "cube" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(TrackerTheme.panel, in: Capsule())
                    Spacer()
                    VStack(spacing: 8) {
                        mapButton(store.is3D ? "3D" : "2D", symbol: nil, accessibility: "Toggle map perspective", action: store.toggle3D)
                        mapButton(nil, symbol: "arrow.up.left.and.arrow.down.right", accessibility: "Show airspace overview", action: store.overview)
                        mapButton(nil, symbol: "slider.horizontal.3", accessibility: "Model display settings") { store.showSettings = true }
                    }
                }
                Spacer(minLength: 8)
                if let track = store.selected { FlightInspector(track: track, store: store) }
                else { emptyInspector }
                footer
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
        }
        .foregroundStyle(.white).preferredColorScheme(.dark).tint(TrackerTheme.accent)
        .task(id: scenePhase) { if scenePhase == .active { await store.run() } }
        .sheet(isPresented: $store.showFlights) { FlightList(store: store) }
        .sheet(isPresented: $store.showSettings) { DisplaySettings(store: store) }
        .sheet(isPresented: $store.showHelp) { PrototypeInfo() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "airplane").font(.title2).foregroundStyle(TrackerTheme.accent)
                    Text("AeroTrack").font(.system(size: 25, weight: .bold, design: .rounded))
                }
                Spacer()
                Button { store.showFlights = true } label: {
                    Image(systemName: "list.bullet").font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Browse flights")
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 12))
            }
            HStack(spacing: 7) {
                Circle().fill(store.isDemo ? .orange : TrackerTheme.accent).frame(width: 5, height: 5)
                Text(store.isDemo ? "DEMO AIRSPACE" : "ADSB.LOL · 100 NM SCAN")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(store.renderTracks(at: context.date).count) aircraft")
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(17).background(TrackerTheme.panel, in: .rect(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.08)))
    }

    private var emptyInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AIRSPACE EXPLORER", systemImage: "scope")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.3).foregroundStyle(TrackerTheme.accent)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            Text("Choose an aircraft").font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(store.errorMessage == nil ? "Tap a plane or browse nearby flights. Follow it to explore heading, bank and climb in 3D." : "Flight data is unavailable. The next attempt respects the one-minute limit. You can explore the offline demo now.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { store.showFlights = true } label: {
                    Label("Flights", systemImage: "airplane").frame(maxWidth: .infinity).padding(.vertical, 13)
                }
                .font(.subheadline.bold()).foregroundStyle(TrackerTheme.ink)
                .background(TrackerTheme.accent, in: .rect(cornerRadius: 13))
                Button(action: store.toggleDemo) {
                    Label(store.isDemo ? "Live data" : "Try demo", systemImage: store.isDemo ? "antenna.radiowaves.left.and.right" : "play.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                }
                .font(.subheadline.bold()).background(.white.opacity(0.08), in: .rect(cornerRadius: 13))
            }
        }.padding(20).background(TrackerTheme.panel, in: .rect(cornerRadius: 25))
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: store.isDemo ? "play.circle" : "clock")
                if store.isDemo { Text("Synthetic telemetry · no API calls") }
                else if store.isLoading { Text("Receiving flight data…") }
                else { Text("Next scan \(store.nextRequestIn)s · motion predicted") }
            }.font(.system(size: 9, weight: .medium, design: .monospaced))
            Spacer(minLength: 3)
            Button { store.showHelp = true } label: { Image(systemName: "info.circle").font(.system(size: 15)) }
                .accessibilityLabel("About telemetry and estimates")
        }
        .foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 12).padding(.vertical, 9)
        .background(TrackerTheme.panel, in: Capsule())
    }

    private func mapButton(_ text: String?, symbol: String?, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let text { Text(text).font(.system(size: 14, weight: .bold, design: .rounded)) }
                else if let symbol { Image(systemName: symbol).font(.system(size: 17, weight: .medium)) }
            }.frame(width: 44, height: 44)
        }.background(TrackerTheme.panel, in: .rect(cornerRadius: 14)).accessibilityLabel(accessibility)
    }
}

enum TrackerTheme {
    static let ink = Color(red: 0.025, green: 0.055, blue: 0.085)
    static let panel = Color(red: 0.035, green: 0.065, blue: 0.10).opacity(0.96)
    static let accent = Color(red: 0.35, green: 0.89, blue: 0.93)
}

#Preview { ContentView() }
