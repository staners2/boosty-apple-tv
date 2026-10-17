import Foundation

public actor BrokerClient {
    public nonisolated static let userAgent = "BoostyAppleTV/0.1"
    private let endpoint: BrokerEndpoint
    private let session: URLSession
    private var credentials: SessionCredentials?
    private var sessionRevision: UInt64 = 0

    public init(endpoint: BrokerEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 25
            self.session = URLSession(configuration: configuration)
        }
    }

    public func restoreSession(_ value: SessionCredentials?) throws {
        guard value?.isValid ?? true else { throw BrokerError.invalidInput }
        credentials = value
        sessionRevision &+= 1
    }

    public func currentSession() -> SessionCredentials? { credentials }

    public func me() async throws -> Profile {
        try decode(await request(path: ["api", "me"]).0)
    }

    public func createPair() async throws -> PairCreated {
        try decode(await request(path: ["api", "pairs"], body: ["name": "Apple TV"]).0)
    }

    public func pollPair(id: String, pollKey: String) async throws -> PairStatus {
        try validateIdentifier(id)
        try validatePollKey(pollKey)
        return try decode(await request(path: ["api", "pairs", id], pollKey: pollKey, pairRequest: true).0)
    }

    public func finishPair(id: String, pollKey: String) async throws -> Profile {
        try validateIdentifier(id)
        try validatePollKey(pollKey)
        let revision = sessionRevision
        let (data, response) = try await request(path: ["api", "pairs", id, "finish"], body: [:], pollKey: pollKey, pairRequest: true)
        struct Finished: Decodable { let profile: Profile; let tvProof: String }
        let finished: Finished = try decode(data)
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { throw BrokerError.invalidResponse }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: endpoint.url)
        let tokens = cookies.filter { $0.name == "boostytv" }
        guard tokens.count == 1 else { throw BrokerError.invalidResponse }
        let value = SessionCredentials(cookieValue: tokens[0].value, tvProof: finished.tvProof)
        guard value.isValid else { throw BrokerError.invalidResponse }
        // A pending response must not restore a session after local logout or endpoint state restoration.
        try Task.checkCancellation()
        guard revision == sessionRevision else { throw CancellationError() }
        credentials = value
        sessionRevision &+= 1
        return finished.profile
    }

    public func logout() async throws {
        let outgoing = credentials
        credentials = nil
        sessionRevision &+= 1
        _ = try await request(path: ["api", "logout"], body: [:], outgoingCredentials: outgoing)
    }

    public func subscriptions(offset: Int = 0) async throws -> SubscriptionPage {
        guard (0...100000).contains(offset) else { throw BrokerError.invalidInput }
        return try decode(await request(path: ["api", "subscriptions"], query: [URLQueryItem(name: "offset", value: String(offset))]).0)
    }

    public func feed(blog: String? = nil, offset: String? = nil) async throws -> PostPage {
        if let blog { try validateIdentifier(blog) }
        if let offset {
            guard offset.count <= 256, !offset.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BrokerError.invalidInput }
        }
        let path = blog.map { ["api", "blog", $0] } ?? ["api", "feed"]
        return try decode(await request(path: path, query: offset.map { [URLQueryItem(name: "offset", value: $0)] } ?? []).0)
    }

    public func post(blog: String, id: String) async throws -> Post {
        try validateIdentifier(blog)
        try validateIdentifier(id)
        return try decode(await request(path: ["api", "post", blog, id]).0)
    }

    public func progress(blog: String, postID: String, videoID: String) async throws -> Double {
        try validateIdentifier(blog)
        try validateIdentifier(postID)
        try validateIdentifier(videoID)
        struct Progress: Decodable { let seconds: Double }
        let progress: Progress = try decode(await request(path: ["api", "progress", blog, postID, videoID]).0)
        guard progress.seconds.isFinite, progress.seconds >= 0, progress.seconds <= 604800 else { throw BrokerError.invalidResponse }
        return progress.seconds
    }

    public func saveProgress(videoID: String, seconds: Double) async throws {
        try validateIdentifier(videoID)
        guard seconds.isFinite, seconds >= 0, seconds <= 604800 else { throw BrokerError.invalidInput }
        _ = try await request(path: ["api", "progress"], body: ["videoId": videoID, "seconds": Int(seconds.rounded(.down))])
    }

    public func qrCode(for url: URL) async throws -> String {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.absoluteString.utf16.count <= 1800
        else { throw BrokerError.invalidInput }
        struct QRCode: Decodable { let qrImage: String }
        let result: QRCode = try decode(await request(path: ["api", "qr"], body: ["url": url.absoluteString]).0)
        // The broker renders a 480px PNG; this client budget also bounds base64 decoding allocation.
        let image = try imageData(result.qrImage, prefix: "data:image/png;base64,", maxBytes: 1_048_576)
        guard image.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { throw BrokerError.invalidResponse }
        return result.qrImage
    }

    public func preview(blog: String, postID: String, contentID: String, seconds: Double) async throws -> VideoPreview {
        try validateIdentifier(blog)
        try validateIdentifier(postID)
        try validateIdentifier(contentID)
        guard blog.count <= 80, seconds.isFinite, seconds >= 0 else { throw BrokerError.invalidInput }
        let result: VideoPreview = try decode(await request(
            path: ["api", "preview", blog, postID, contentID],
            query: [URLQueryItem(name: "seconds", value: String(seconds))]
        ).0)
        guard result.seconds.isFinite, result.seconds >= 0, result.seconds == seconds else { throw BrokerError.invalidResponse }
        let image = try imageData(result.image, prefix: "data:image/jpeg;base64,", maxBytes: 65_536)
        guard image.count >= 4, image.starts(with: [0xff, 0xd8]), image.suffix(2).elementsEqual([0xff, 0xd9]) else { throw BrokerError.invalidResponse }
        return result
    }

    private func imageData(_ value: String, prefix: String, maxBytes: Int) throws -> Data {
        guard value.utf8.count <= prefix.utf8.count + ((maxBytes + 2) / 3) * 4,
              value.hasPrefix(prefix)
        else { throw BrokerError.invalidResponse }
        let encoded = String(value.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= maxBytes,
              data.base64EncodedString() == encoded
        else { throw BrokerError.invalidResponse }
        return data
    }

    private func validateIdentifier(_ value: String) throws {
        guard value != ".", value != "..", value.range(of: "^[A-Za-z0-9_.-]{1,160}$", options: .regularExpression) != nil else { throw BrokerError.invalidInput }
    }

    private func validatePollKey(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw BrokerError.invalidInput }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw BrokerError.invalidResponse }
    }

    private func request(path: [String], query: [URLQueryItem] = [], body: [String: Any]? = nil, pollKey: String? = nil, pairRequest: Bool = false, outgoingCredentials: SessionCredentials? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try endpoint.requestURL(path: path, queryItems: query), timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let credentials = outgoingCredentials ?? credentials {
            guard credentials.isValid else { throw BrokerError.invalidInput }
            request.setValue("boostytv=" + credentials.cookieValue, forHTTPHeaderField: "Cookie")
            request.setValue(credentials.tvProof, forHTTPHeaderField: "X-TV-Proof")
        }
        if let pollKey { request.setValue(pollKey, forHTTPHeaderField: "X-Poll-Key") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "X-TV-Request")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: BrokerRedirectDelegate(endpoint: endpoint)) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw BrokerError(code: "network") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, endpoint.contains(finalURL) else { throw BrokerError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            struct Failure: Decodable { let code: String? }
            let code = (try? JSONDecoder().decode(Failure.self, from: data).code) ?? "request_failed"
            throw BrokerError(status: http.statusCode, code: code, isExpiredPair: pairRequest && [404, 410].contains(http.statusCode))
        }
        return (data, http)
    }
}

private final class BrokerRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let endpoint: BrokerEndpoint
    init(endpoint: BrokerEndpoint) { self.endpoint = endpoint }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, endpoint.contains(url) else { completionHandler(nil); return }
        var redirected = request
        redirected.httpShouldHandleCookies = false
        // URLSession may strip sensitive headers during redirects; copy only after validating the destination.
        for header in ["Cookie", "X-TV-Proof", "X-Poll-Key", "User-Agent", "Accept", "X-TV-Request", "Content-Type"] {
            redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        completionHandler(redirected)
    }
}
