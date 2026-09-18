import Foundation

/// The runner's side of the Python API — the only network code in the app, and
/// never called during the race. The phone talks to this API and nothing else,
/// so it knows nothing about which login or storage provider sits behind it.
nonisolated struct ApiClient {

    let baseURL: URL
    var urlSession: URLSession = .shared

    struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    struct RunnerEvent: Decodable {
        let id: UUID
        let name: String
    }

    struct RemoteCheer: Decodable {
        let id: UUID
        let slot: Mile
        let senderName: String
        let downloadUrl: URL
    }

    /// The API sends miles as strings ("20.5", "20.0") because they are exact
    /// decimals on the server. Accept either form.
    struct Mile: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self), let number = Double(text) {
                value = number
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "A mile must be a number or a numeric string")
            }
        }
    }

    enum Failure: LocalizedError {
        /// The API answered and said no, with a message meant for people.
        case refused(status: Int, message: String)
        case unreadable

        var needsSignIn: Bool {
            if case .refused(401, _) = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .refused(_, let message): return message
            case .unreadable: return "The server sent something unexpected."
            }
        }
    }

    // MARK: - Session

    func signIn(email: String, password: String) async throws -> Tokens {
        try await send("POST", "/api/runner/session", body: ["email": email, "password": password])
    }

    func refresh(_ refreshToken: String) async throws -> Tokens {
        try await send("POST", "/api/runner/session/refresh", body: ["refresh_token": refreshToken])
    }

    // MARK: - Cheers

    func events(accessToken: String) async throws -> [RunnerEvent] {
        try await send("GET", "/api/runner/events", accessToken: accessToken)
    }

    func cheers(accessToken: String, eventID: UUID) async throws -> [RemoteCheer] {
        try await send("GET", "/api/runner/events/\(eventID.uuidString.lowercased())/cheers",
                       accessToken: accessToken)
    }

    /// Downloads to a temporary file first, so a dropped connection can never
    /// leave half a recording where a whole one is expected.
    func download(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await urlSession.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.refused(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                  message: "A recording couldn't be downloaded.")
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    // MARK: - Plumbing

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: String]? = nil,
        accessToken: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }

        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.refused(status: http.statusCode,
                                  message: message ?? "The server refused the request (\(http.statusCode)).")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw Failure.unreadable
        }
    }
}
