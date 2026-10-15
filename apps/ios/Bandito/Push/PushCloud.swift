import Foundation

/// The Bandito cloud's push address book (`POST /push/register`, `POST /push/unregister`): the phone's Apple token goes in,
/// an opaque `handle` comes out; the daemons send to the handle, never to the token.
protocol PushCloud: Sendable {
    /// The handle for this token in this environment.
    func register(token: String, env: String) async throws -> String
    func unregister(handle: String) async throws
}

enum PushCloudError: Error, Equatable {
    /// 409: the cloud has this token in the other environment.
    case conflict
    /// 429: too many registrations from this address.
    case rateLimited
    /// Another answer of the cloud.
    case status(Int)
    /// The answer has no handle.
    case badAnswer
}

struct BanditoPushCloud: PushCloud {
    static let baseURL = URL(string: "https://bandito.dev/api/v1")!
    static let bundleID = "dev.bandito.ios"

    let base: URL
    let session: URLSession

    init(base: URL = BanditoPushCloud.baseURL, session: URLSession = BanditoPushCloud.makeSession()) {
        self.base = base
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func register(token: String, env: String) async throws -> String {
        struct Body: Encodable {
            var apnsToken: String
            var env: String
            var bundleId: String
        }
        struct Answer: Decodable { var handle: String }
        let data = try await post("push/register", Body(apnsToken: token, env: env, bundleId: Self.bundleID))
        guard let handle = (try? JSONDecoder().decode(Answer.self, from: data))?.handle, !handle.isEmpty else {
            throw PushCloudError.badAnswer
        }
        return handle
    }

    func unregister(handle: String) async throws {
        struct Body: Encodable { var handle: String }
        _ = try await post("push/unregister", Body(handle: handle))
    }

    private func post(_ path: String, _ body: some Encodable) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 409: throw PushCloudError.conflict
        case 429: throw PushCloudError.rateLimited
        default: throw PushCloudError.status(status)
        }
    }
}
