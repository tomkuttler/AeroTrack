import Foundation

struct RequestBudget: Sendable {
    static let interval: TimeInterval = 60
    private(set) var lastAttempt: Date?

    func remaining(at date: Date) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        return max(0, Self.interval - date.timeIntervalSince(lastAttempt))
    }

    mutating func reserve(at date: Date) -> Bool {
        guard remaining(at: date) == 0 else { return false }
        lastAttempt = date
        return true
    }
}

/// All flight requests, including failures and region changes, pass through this single gate.
actor ADSBService {
    static let shared = ADSBService()
    private static let attemptKey = "adsb.lastRequestAttempt"
    private var budget: RequestBudget
    private var inFlight = false
    private var lastMonotonicAttempt: ContinuousClock.Instant?
    private let session: URLSession

    init() {
        let previous = UserDefaults.standard.double(forKey: Self.attemptKey)
        budget = RequestBudget(lastAttempt: previous > 0 ? Date(timeIntervalSince1970: previous) : nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func secondsUntilNextRequest() -> TimeInterval {
        let monotonic = lastMonotonicAttempt.map { max(0, 60 - Double($0.duration(to: .now).components.seconds)) } ?? 0
        return max(monotonic, budget.remaining(at: .now))
    }

    func fetch(around point: GeoPoint) async throws -> [Flight]? {
        guard !inFlight, secondsUntilNextRequest() <= 0, budget.reserve(at: .now) else { return nil }
        // Persist BEFORE suspension, so cancellation, failure, relaunch and rapid taps cannot bypass it.
        UserDefaults.standard.set(budget.lastAttempt!.timeIntervalSince1970, forKey: Self.attemptKey)
        lastMonotonicAttempt = .now
        inFlight = true
        defer { inFlight = false }
        let lat = point.latitude.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(5)).grouping(.never))
        let lon = point.longitude.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(5)).grouping(.never))
        let url = URL(string: "https://api.adsb.lol/v2/lat/\(lat)/lon/\(lon)/dist/100")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ADSBResponse.self, from: data).flights()
    }

    enum ServiceError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self { case .http(let status): "adsb.lol returned HTTP \(status). Retrying after the one-minute limit." }
        }
    }
}
