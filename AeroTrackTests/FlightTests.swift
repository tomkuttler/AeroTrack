import Testing
import Foundation
import simd
import MapKit
@testable import AeroTrack

struct FlightTests {
    @Test func decodingSparseAndGroundTelemetry() throws {
        let json = #"""
        {"now": 1794250000000, "ac": [
          {"hex":"abc001","flight":" DLH123 ","lat":50,"lon":8,"alt_baro":12000,"alt_geom":12500,"gs":250,"true_heading":359,"roll":-12.5,"seen_pos":3},
          {"hex":"abc002","lat":50,"lon":8,"alt_baro":"ground","gs":0,"seen_pos":0},
          {"hex":"abc003","lat":50,"lon":8,"alt_baro":12000,"seen_pos":70},
          {"hex":"abc004","lat":95,"lon":8,"alt_baro":12000,"seen_pos":0},
          {"hex":"abc005","lat":50,"lon":8,"alt_baro":"10000","gs":"bad","roll":"invalid","seen_pos":0}
        ]}
        """#
        let response = try JSONDecoder().decode(ADSBResponse.self, from: Data(json.utf8))
        let flights = response.flights()
        #expect(flights.count == 3)
        #expect(flights[0].callsign == "DLH123")
        #expect(abs(flights[0].altitudeMeters - 3810) < 0.001)
        #expect(flights[0].geometricAltitude)
        #expect(flights[0].roll == -12.5)
        #expect(flights[0].observedAt == response.timestamp.addingTimeInterval(-3))
        #expect(flights[1].onGround && flights[1].altitudeMeters == 0)
        #expect(flights[2].speedKnots == 0 && flights[2].roll == nil)
        #expect(!flights[2].hasTrack && !flights[2].hasVerticalRate)
        #expect(response.timestamp.timeIntervalSince1970 == 1794250000)
    }

    @Test func budgetCountsFailedAttemptsAndRegionChanges() {
        let start = Date(timeIntervalSince1970: 1000)
        var budget = RequestBudget()
        let reservation1 = budget.reserve(at: start)
        #expect(reservation1)
        let reservation2 = !budget.reserve(at: start.addingTimeInterval(59.999))
        #expect(reservation2)
        let reservation3 = !budget.reserve(at: start.addingTimeInterval(-100))
        #expect(reservation3)
        // Restoring the persisted timestamp still blocks the next request.
        var restored = RequestBudget(lastAttempt: budget.lastAttempt)
        let reservation4 = !restored.reserve(at: start.addingTimeInterval(30))
        #expect(reservation4)
        let reservation5 = restored.reserve(at: start.addingTimeInterval(60))
        #expect(reservation5)
        let reservation6 = !restored.reserve(at: start.addingTimeInterval(60))
        #expect(reservation6)
        let reservation7 = restored.reserve(at: start.addingTimeInterval(120))
        #expect(reservation7)
    }

    @Test func predictionMovesContinuouslyAndFreezesWhenStale() {
        let epoch = Date(timeIntervalSince1970: 1000)
        let flight = example(at: epoch)
        let track = FlightTrack(flight: flight, receivedAt: epoch)
        let a = track.pose(at: epoch.addingTimeInterval(30))
        let b = track.pose(at: epoch.addingTimeInterval(30.016))
        #expect(a.position.longitude > flight.position.longitude)
        #expect(b.position.longitude > a.position.longitude)
        #expect(abs(a.altitude - (flight.altitudeMeters + 152.4)) < 0.001)
        #expect(track.pose(at: epoch.addingTimeInterval(90)).position == track.pose(at: epoch.addingTimeInterval(300)).position)
    }

    @Test func correctionStartsAtPreviousPoseAndWrapsHeading() {
        let epoch = Date(timeIntervalSince1970: 1000)
        var flight = example(at: epoch)
        flight.trueHeading = 1
        let old = FlightPose(position: GeoPoint(latitude: 50, longitude: 8), altitude: 900, heading: 359, pitch: 0, roll: 0, track: 90)
        let track = FlightTrack(flight: flight, correctionFrom: old, receivedAt: epoch)
        let start = track.pose(at: epoch)
        let middle = track.pose(at: epoch.addingTimeInterval(4))
        #expect(start.position == old.position)
        #expect(start.altitude == old.altitude)
        #expect(start.heading == 359)
        #expect(middle.heading < 2 || middle.heading > 358)
        #expect(track.pose(at: epoch.addingTimeInterval(8)).heading == 1)
    }

    @Test func positiveBankAndClimbUseConsistentAxes() {
        let yaw = simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: .pi / 12, axis: SIMD3(1, 0, 0))
        let roll = simd_quatf(angle: -.pi / 6, axis: SIMD3(0, 0, 1))
        #expect(yaw.act(SIMD3(0, 0, -1)).x > 0.99) // heading east
        #expect(pitch.act(SIMD3(0, 0, -1)).y > 0) // nose up
        #expect(roll.act(SIMD3(1, 0, 0)).y < 0) // right wing down
    }

    @Test func reportedBankIsNotArtificiallyFlattened() {
        var flight = example(at: .now)
        flight.roll = 95
        #expect(flight.rollEstimate == 95)
        flight.roll = -95
        #expect(flight.rollEstimate == -95)
    }

    @Test func turnPredictionIsBounded() {
        let epoch = Date(timeIntervalSince1970: 1000)
        var flight = example(at: epoch)
        flight.trackRate = 1
        let track = FlightTrack(flight: flight, receivedAt: epoch)
        #expect(track.pose(at: epoch.addingTimeInterval(10)).track == 100)
        #expect(track.pose(at: epoch.addingTimeInterval(60)).track == 105)
    }

    private func example(at date: Date) -> Flight {
        Flight(id: "test", callsign: "TEST", registration: "TEST", aircraftType: "A320",
               position: GeoPoint(latitude: 50, longitude: 8), altitudeMeters: 1000,
               geometricAltitude: true, speedKnots: 250, track: 90, verticalRate: 1000,
               observedAt: date, onGround: false)
    }
}

struct ProjectionTests {
    @Test func groundAndAltitudeMatchPerspectiveAtEveryHeading() throws {
        for heading in [0.0, 45, 90, 180, 270] {
            for pitch in [0.0, 20, 58, 75] {
                let size = SIMD2<Double>(390, 844)
                let focal = 920.0
                let distance = 12_000.0
                let sample = 1000.0
                func expected(_ x: Double, _ north: Double, _ altitude: Double) -> SIMD2<Double> {
                    let h = heading.radians
                    let p = pitch.radians
                    let right = x * cos(h) - north * sin(h)
                    let along = x * sin(h) + north * cos(h)
                    let depth = distance + along * sin(p) - altitude * cos(p)
                    return SIMD2(size.x / 2 + focal * right / depth,
                                 size.y / 2 - focal * (along * cos(p) + altitude * sin(p)) / depth)
                }
                let corners = [expected(-sample, -sample, 0), expected(sample, -sample, 0), expected(sample, sample, 0), expected(-sample, sample, 0)]
                let projection = try #require(MapProjection(screenPoints: corners, sampleMeters: sample,
                                                            width: size.x, height: size.y, heading: heading, pitch: pitch, cameraDistance: distance))
                for altitude in [0.0, 1500, 5000] {
                    let actual = projection.project(east: 450, north: -300, altitude: altitude)
                    let target = expected(450, -300, altitude)
                    #expect(abs(actual.x - target.x) < 0.001)
                    #expect(abs(actual.y - target.y) < 0.001)
                    let clip = projection.matrix * SIMD4<Float>(450, Float(altitude), 300, 1)
                    #expect(abs(Double((clip.x / clip.w + 1) / 2) * size.x - target.x) < 0.01)
                    #expect(abs(Double((1 - clip.y / clip.w) / 2) * size.y - target.y) < 0.01)
                }
            }
        }
    }
}

struct MapLifecycleTests {
    @MainActor @Test func initialLayoutKeepsTheScanAndCameraAtFrankfurt() async throws {
        let store = TrackerStore()
        let view = AircraftMapContainer(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutIfNeeded()
        view.setActive(true)
        defer { view.setActive(false) }
        try await Task.sleep(for: .seconds(1))
        #expect(abs(store.queryCenter.latitude - GeoPoint.frankfurt.latitude) < 0.001)
        #expect(abs(store.queryCenter.longitude - GeoPoint.frankfurt.longitude) < 0.001)
        #expect(abs(view.map.camera.centerCoordinate.latitude - GeoPoint.frankfurt.latitude) < 0.001)
        #expect(abs(view.map.camera.centerCoordinate.longitude - GeoPoint.frankfurt.longitude) < 0.001)
    }
}
