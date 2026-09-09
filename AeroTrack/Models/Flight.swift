import Foundation

struct GeoPoint: Sendable, Equatable {
    var latitude: Double
    var longitude: Double

    func destination(meters: Double, bearing: Double) -> GeoPoint {
        let distance = meters / 6_371_000
        let course = bearing.radians
        let lat = latitude.radians
        let lon = longitude.radians
        let nextLat = asin(sin(lat) * cos(distance) + cos(lat) * sin(distance) * cos(course))
        let nextLon = lon + atan2(sin(course) * sin(distance) * cos(lat), cos(distance) - sin(lat) * sin(nextLat))
        return GeoPoint(latitude: nextLat.degrees, longitude: (nextLon.degrees + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    static let frankfurt = GeoPoint(latitude: 50.05, longitude: 8.57)
}

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
    var wrappedHeading: Double { (self.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    func angleDelta(to other: Double) -> Double { (other - self + 540).truncatingRemainder(dividingBy: 360) - 180 }
}

struct Flight: Identifiable, Sendable {
    let id: String
    var callsign: String
    var registration: String
    var aircraftType: String
    var position: GeoPoint
    var altitudeMeters: Double
    var geometricAltitude: Bool
    var speedKnots: Double
    var track: Double
    var trueHeading: Double?
    var roll: Double?
    var trackRate: Double?
    var verticalRate: Double // feet/minute
    var trueAirspeed: Double?
    var observedAt: Date
    var onGround: Bool
    var hasTrack = true
    var hasVerticalRate = true

    var pitchEstimate: Double {
        guard !onGround, speedKnots > 30 else { return 0 }
        let horizontalSpeed = (trueAirspeed ?? speedKnots) * 0.514444
        return atan2(verticalRate * 0.00508, horizontalSpeed).degrees
    }

    var rollEstimate: Double {
        if let roll { return (roll + 540).truncatingRemainder(dividingBy: 360) - 180 }
        guard !onGround, let trackRate else { return 0 }
        return min(35, max(-35, atan(speedKnots * 0.514444 * trackRate.radians / 9.80665).degrees))
    }
}

struct FlightPose: Sendable {
    var position: GeoPoint
    var altitude: Double
    var heading: Double
    var pitch: Double
    var roll: Double
    var track: Double
}

/// Predict motion from a sparse observation, then ease corrections without teleporting.
struct FlightTrack: Sendable, Identifiable {
    var id: String { flight.id }
    var flight: Flight
    var correctionFrom: FlightPose?
    var receivedAt: Date

    func pose(at date: Date) -> FlightPose {
        // Never extrapolate indefinitely after a connection failure.
        let elapsed = min(90, max(0, date.timeIntervalSince(flight.observedAt)))
        let turnTime = min(15, elapsed)
        let rate = min(3, max(-3, flight.trackRate ?? 0))
        let distancePerSecond = flight.speedKnots * 0.514444
        var point = flight.position
        // Integrate the first 15 seconds of a reported turn; don't predict a minute-long circle.
        let steps = max(1, Int(ceil(turnTime)))
        for step in 0..<steps {
            let dt = turnTime / Double(steps)
            point = point.destination(meters: distancePerSecond * dt, bearing: flight.track + rate * (Double(step) + 0.5) * dt)
        }
        let course = (flight.track + rate * turnTime).wrappedHeading
        point = point.destination(meters: distancePerSecond * (elapsed - turnTime), bearing: course)
        var pose = FlightPose(
            position: point,
            altitude: flight.onGround ? 0 : max(0, flight.altitudeMeters + flight.verticalRate * 0.00508 * elapsed),
            heading: ((flight.trueHeading ?? flight.track) + rate * turnTime).wrappedHeading,
            pitch: flight.pitchEstimate,
            roll: flight.rollEstimate,
            track: course
        )
        if let old = correctionFrom {
            let t = min(1, max(0, date.timeIntervalSince(receivedAt) / 8))
            let blend = t * t * (3 - 2 * t)
            // Advance the old pose too, so the correction doesn't bring motion to a halt.
            let oldPoint = old.position.destination(meters: distancePerSecond * min(8, max(0, date.timeIntervalSince(receivedAt))), bearing: old.track)
            pose.position.latitude = oldPoint.latitude + (pose.position.latitude - oldPoint.latitude) * blend
            pose.position.longitude = oldPoint.longitude + oldPoint.longitude.angleDelta(to: pose.position.longitude) * blend
            let oldAltitude = max(0, old.altitude + tan(old.pitch.radians) * distancePerSecond * min(8, max(0, date.timeIntervalSince(receivedAt))))
            pose.altitude = oldAltitude + (pose.altitude - oldAltitude) * blend
            pose.heading = (old.heading + old.heading.angleDelta(to: pose.heading) * blend).wrappedHeading
            pose.pitch = old.pitch + (pose.pitch - old.pitch) * blend
            pose.roll = old.roll + (pose.roll - old.roll) * blend
        }
        return pose
    }
}

struct ADSBResponse: Decodable, Sendable {
    let ac: [AircraftRecord]
    let now: Double

    var timestamp: Date { Date(timeIntervalSince1970: now > 10_000_000_000 ? now / 1000 : now) }

    func flights() -> [Flight] { ac.compactMap { $0.flight(timestamp: timestamp) } }
}

/// Optional telemetry is intentionally tolerant: one malformed field mustn't discard a region.
struct AircraftRecord: Decodable, Sendable {
    let hex: String?
    let callsign: String?
    let registration: String?
    let aircraftType: String?
    let latitude: Double?
    let longitude: Double?
    let barometricAltitude: Double?
    let geometricAltitude: Double?
    let speed: Double?
    let track: Double?
    let heading: Double?
    let roll: Double?
    let trackRate: Double?
    let verticalRate: Double?
    let airspeed: Double?
    let seenPosition: Double?
    let onGround: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func number(_ key: String) -> Double? {
            let k = Key(stringValue: key)
            if let n = try? c.decode(Double.self, forKey: k), n.isFinite { return n }
            if let s = try? c.decode(String.self, forKey: k), let n = Double(s), n.isFinite { return n }
            return nil
        }
        func string(_ key: String) -> String? { try? c.decode(String.self, forKey: Key(stringValue: key)) }
        hex = string("hex")
        callsign = string("flight")?.trimmingCharacters(in: .whitespacesAndNewlines)
        registration = string("r")
        aircraftType = string("t")
        latitude = number("lat")
        longitude = number("lon")
        barometricAltitude = number("alt_baro")
        geometricAltitude = number("alt_geom")
        speed = number("gs")
        track = number("track")
        heading = number("true_heading") // Magnetic heading isn't interchangeable with true north.
        roll = number("roll")
        trackRate = number("track_rate")
        verticalRate = number("geom_rate") ?? number("baro_rate")
        airspeed = number("tas")
        seenPosition = number("seen_pos")
        onGround = string("alt_baro") == "ground"
    }

    func flight(timestamp: Date) -> Flight? {
        guard let hex, let latitude, let longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              let age = seenPosition, (0...60).contains(age),
              onGround || geometricAltitude != nil || barometricAltitude != nil else { return nil }
        return Flight(id: hex, callsign: callsign.flatMap { $0.isEmpty ? nil : $0 } ?? hex.uppercased(),
                      registration: registration ?? "Unknown", aircraftType: aircraftType ?? "Aircraft",
                      position: GeoPoint(latitude: latitude, longitude: longitude),
                      altitudeMeters: onGround ? 0 : max(0, (geometricAltitude ?? barometricAltitude ?? 0) * 0.3048),
                      geometricAltitude: geometricAltitude != nil, speedKnots: max(0, speed ?? 0),
                      track: track ?? heading ?? 0, trueHeading: heading, roll: roll, trackRate: trackRate,
                      verticalRate: verticalRate ?? 0, trueAirspeed: airspeed,
                      observedAt: timestamp.addingTimeInterval(-age), onGround: onGround,
                      hasTrack: track != nil || heading != nil, hasVerticalRate: verticalRate != nil)
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
