import SwiftUI

struct FlightList: View {
    let store: TrackerStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let flights = store.renderTracks(at: context.date).filter {
                    search.isEmpty || $0.flight.callsign.localizedStandardContains(search) || $0.flight.registration.localizedStandardContains(search)
                }
                List {
                    Section {
                        ForEach(flights) { track in
                            Button {
                                store.select(track.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "airplane").foregroundStyle(TrackerTheme.accent)
                                        .frame(width: 36, height: 36).background(TrackerTheme.accent.opacity(0.1), in: .rect(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.flight.callsign).font(.headline).foregroundStyle(.white)
                                        Text("\(track.flight.registration) · \(track.flight.aircraftType)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(Int(track.flight.altitudeMeters / 0.3048)) ft").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                    } header: { Text(store.isDemo ? "Synthetic test flights" : "Within 100 nautical miles of scan center") }
                    if flights.isEmpty {
                        ContentUnavailableView(store.isLoading ? "Scanning airspace" : "No matching aircraft", systemImage: "airplane", description: Text("Move the map to another area for the next scan, or use the demo to test 3D motion."))
                    }
                    Section {
                        Button(store.isDemo ? "Switch to live adsb.lol data" : "Try offline orientation demo", systemImage: store.isDemo ? "antenna.radiowaves.left.and.right" : "play.circle") {
                            store.toggleDemo()
                            dismiss()
                        }
                    } footer: { Text("Live requests are limited to one per minute across all map areas. Selecting a flight makes no additional request.") }
                }
            }
            .searchable(text: $search, prompt: "Callsign or registration")
            .navigationTitle("Flights")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(TrackerTheme.accent)
    }
}

struct DisplaySettings: View {
    @Bindable var store: TrackerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("Model size", systemImage: "cube")
                        Spacer()
                        Text("\(Int(store.modelScale))×").monospacedDigit().foregroundStyle(TrackerTheme.accent)
                    }
                    Slider(value: $store.modelScale, in: 1...40, step: 1)
                        .accessibilityLabel("Aircraft model magnification")
                    HStack {
                        Button("True size") { store.modelScale = 1 }
                        Spacer()
                        Button("20×") { store.modelScale = 20 }
                        Spacer()
                        Button("40×") { store.modelScale = 40 }
                    }.font(.caption.bold()).buttonStyle(.borderless)
                } header: { Text("Spatial orientation test") }
                footer: { Text("Magnification changes the aircraft geometry only. Position, altitude and attitude retain their original values. Large models may intersect the ground or overlap nearby aircraft.") }
                Section {
                    LabeledContent("3D model threshold", value: "Camera distance < 70 km")
                    LabeledContent("Live scan radius", value: "100 nautical miles")
                    LabeledContent("Minimum request interval", value: "60 seconds")
                    LabeledContent("Correction smoothing", value: "8 seconds")
                }
                Section {
                    Button(store.isDemo ? "Use live flight data" : "Start offline demo", systemImage: store.isDemo ? "antenna.radiowaves.left.and.right" : "play.circle") {
                        store.toggleDemo()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large]).preferredColorScheme(.dark).tint(TrackerTheme.accent)
    }
}

struct PrototypeInfo: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Explore") {
                    Text("Select a plane from the map or Flights list to follow it. Pinch to zoom, rotate with two fingers, and use the 2D/3D button to change perspective. Dragging stops follow mode.")
                    Text("Zoomed-out aircraft are icons. Below a 70 km camera distance they become one shared 3D jet model. Adjust model magnification in Display to inspect its orientation.")
                }
                Section("Reported and estimated orientation") {
                    Text("Yaw uses true heading when reported; otherwise it follows ground track. Magnetic heading is not substituted for true heading.")
                    Text("Roll uses reported bank when available. Otherwise it is estimated from speed and turn rate, or held level when those values are missing.")
                    Text("Pitch is an estimated flight-path angle from vertical speed and true airspeed (groundspeed as fallback). It is not measured nose attitude; angle of attack and wind can make the actual pitch different.")
                }
                Section("Sparse observations") {
                    Text("Positions are predicted using speed, track and vertical rate between scans. A reported turn rate is continued for up to 15 seconds, then motion continues straight. New observations ease into place over 8 seconds.")
                    Text("Prediction stops 90 seconds after the position observation. Old aircraft fade, then disappear at 120 seconds. One-minute sampling cannot reproduce turns that happen between scans.")
                }
                Section("Altitude") {
                    Text("Geometric WGS84 altitude is preferred; barometric altitude is used as a fallback. The map uses a flat reference surface. Terrain, geoid and atmospheric corrections are not applied, so vertical alignment near the ground is approximate.")
                }
                Section("Data") {
                    Link("adsb.lol API documentation", destination: URL(string: "https://api.adsb.lol/docs")!)
                    Text("At most one request starts per 60 seconds, including errors, region changes and app restarts. The demo is synthetic and makes no flight API calls. This is an orientation proof of concept.")
                }
            }
            .navigationTitle("About the prototype").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(TrackerTheme.accent)
    }
}
