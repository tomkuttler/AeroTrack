import Foundation
import Observation

@MainActor @Observable
final class TrackerStore {
    var tracks: [FlightTrack] = []
    var selectedID: String?
    var isDemo = false
    var is3D = true
    var isFollowing = false
    var modelScale: Double = 20
    var cameraDistance: Double = 180_000
    var cameraRevision = 0
    var queryCenter = GeoPoint.frankfurt
    var isLoading = false
    var lastUpdate: Date?
    var nextRequestIn: Int = 0
    var errorMessage: String?
    var showFlights = false
    var showHelp = false
    var showSettings = false

    private let demoEpoch = Date.now
    private let service = ADSBService.shared
    static let modelThreshold: Double = 70_000

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            isDemo = true
            selectedID = "demo-1"
            isFollowing = true
        }
        #endif
    }

    var modelsVisible: Bool { cameraDistance < Self.modelThreshold }
    var selected: FlightTrack? { renderTracks(at: .now).first { $0.id == selectedID } }

    func renderTracks(at date: Date) -> [FlightTrack] {
        if isDemo { return DemoFlights.tracks(at: date, epoch: demoEpoch) }
        return tracks.filter { date.timeIntervalSince($0.flight.observedAt) < 120 }
    }

    func run() async {
        while !Task.isCancelled {
            if !isDemo {
                nextRequestIn = Int(ceil(await service.secondsUntilNextRequest()))
                if nextRequestIn == 0 {
                    isLoading = true
                    do {
                        if let flights = try await service.fetch(around: queryCenter) {
                            try Task.checkCancellation()
                            if !isDemo { merge(flights, at: .now) }
                        }
                    } catch is CancellationError {
                        isLoading = false
                        return
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isLoading = false
                    nextRequestIn = Int(ceil(await service.secondsUntilNextRequest()))
                }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func merge(_ flights: [Flight], at date: Date) {
        let previous = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let unique = Dictionary(flights.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        tracks = unique.values.map { flight in
            FlightTrack(flight: flight, correctionFrom: previous[flight.id]?.pose(at: date), receivedAt: date)
        }.sorted { $0.flight.callsign < $1.flight.callsign }
        lastUpdate = date
        errorMessage = nil
        if let selectedID, !tracks.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            isFollowing = false
        }
    }

    func select(_ id: String) {
        selectedID = id
        isFollowing = true
        cameraRevision += 1
        showFlights = false
    }

    func toggle3D() { is3D.toggle(); cameraRevision += 1 }

    func toggleDemo() {
        isDemo.toggle()
        selectedID = isDemo ? "demo-1" : nil
        isFollowing = isDemo
        queryCenter = .frankfurt
        cameraRevision += 1
    }

    func overview() {
        isFollowing = false
        selectedID = nil
        cameraRevision += 1
    }
}

enum DemoFlights {
    /// Local synthetic telemetry for a repeatable attitude test; never calls the API.
    static func tracks(at date: Date, epoch: Date) -> [FlightTrack] {
        let t = date.timeIntervalSince(epoch)
        return (0..<3).map { index in
            let phase = Double(index) * 120 + t * 1.6
            let radius = 3_500.0 + Double(index) * 1_000
            let position = GeoPoint.frankfurt.destination(meters: radius, bearing: phase)
            let heading = (phase + 90).wrappedHeading
            let altitude = 1_500 + Double(index) * 700 + 300 * sin(t / 40)
            let speed = radius * 1.6.radians / 0.514444
            let flight = Flight(id: "demo-\(index + 1)", callsign: ["SPATIAL 01", "SPATIAL 02", "SPATIAL 03"][index],
                                registration: "Synthetic flight", aircraftType: "Shared jet model", position: position,
                                altitudeMeters: altitude, geometricAltitude: true, speedKnots: speed,
                                track: heading, trueHeading: (heading - 4).wrappedHeading,
                                roll: atan(speed * 0.514444 * 1.6.radians / 9.80665).degrees,
                                trackRate: 1.6, verticalRate: 7.5 * cos(t / 40) / 0.00508,
                                trueAirspeed: speed, observedAt: date, onGround: false)
            return FlightTrack(flight: flight, correctionFrom: nil, receivedAt: date)
        }
    }
}
