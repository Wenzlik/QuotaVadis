import Foundation

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try await send(url, method: "GET", body: nil, headers: headers)
    }

    static func post(_ url: URL, json body: String, headers: [String: String]) async throws -> Data {
        try await send(url, method: "POST", body: Data(body.utf8), headers: headers)
    }

    private static func send(_ url: URL, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299: return data
        case 401: throw ProviderError.unauthorized
        case 403: throw ProviderError.unauthorized
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.http(status)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw ProviderError.decoding(String(describing: error).prefix(200).description)
        }
    }
}

enum JWT {
    /// Decodes the payload of a JWT without verifying it. We only read our own tokens' claims.
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

extension ISO8601DateFormatter {
    /// Accepts both "2026-09-05T23:00:00Z" and "2026-09-05T23:00:00.123456+00:00".
    static func parseAny(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = try? Date(string, strategy: .iso8601.year().month().day().dateSeparator(.dash)
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: true).timeZone(separator: .colon)) {
            return date
        }
        if let date = try? Date(string, strategy: .iso8601.year().month().day().dateSeparator(.dash)
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false).timeZone(separator: .colon)) {
            return date
        }
        return try? Date(string, strategy: .iso8601)
    }
}

extension FileManager {
    /// `homeDirectoryForCurrentUser` is macOS-only; iOS never reaches these paths but the code must compile there.
    var userHome: URL { URL(fileURLWithPath: NSHomeDirectory()) }
}
