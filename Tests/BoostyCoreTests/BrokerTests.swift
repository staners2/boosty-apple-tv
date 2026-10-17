import XCTest
@testable import BoostyCore

final class StubProtocol: URLProtocol {
    static var afterFinish: (() -> Void)?
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            if (300...399).contains(status), let location = headers["Location"], let url = URL(string: location, relativeTo: request.url) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            Self.afterFinish?()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

final class BrokerTests: XCTestCase {
    let cookie = String(repeating: "a", count: 43)
    let proof = String(repeating: "b", count: 43)
    let profileJSON = "{\"id\":\"42\",\"name\":\"Автор\",\"avatar\":null}"
    var client: BrokerClient!

    override func setUpWithError() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = BrokerClient(endpoint: try BrokerEndpoint("https://broker.example/base"), session: URLSession(configuration: config))
    }

    override func tearDown() { StubProtocol.handler = nil; StubProtocol.afterFinish = nil }

    func respond(_ json: String, status: Int = 200, headers: [String: String] = [:], inspect: @escaping (URLRequest) throws -> Void = { _ in }) {
        StubProtocol.handler = { request in
            try inspect(request)
            return (status, headers, Data(json.utf8))
        }
    }

    func testRestoredCredentialsAndRequestContract() async throws {
        try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof))
        respond(profileJSON) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://broker.example/base/api/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "boostytv=" + self.cookie)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TV-Proof"), self.proof)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), BrokerClient.userAgent)
            XCTAssertEqual(BrokerClient.userAgent, "BoostyAppleTV/0.1")
            XCTAssertEqual(request.timeoutInterval, 25)
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        let profile = try await client.me()
        XCTAssertEqual(profile.id, "42")
        do { try await client.restoreSession(SessionCredentials(cookieValue: "bad\r\nCookie: evil", tvProof: proof)); XCTFail() } catch {}
        let saved = await client.currentSession()
        XCTAssertEqual(saved?.cookieValue, cookie)
    }

    func testRejectsTrailingNewlinesInCredentialsAndPollKeys() async throws {
        StubProtocol.handler = { _ in XCTFail("Invalid secret reached network"); throw URLError(.badURL) }
        do {
            try await client.restoreSession(SessionCredentials(cookieValue: cookie + "\n", tvProof: proof))
            XCTFail("Accepted newline in cookie")
        } catch {}
        do {
            try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof + "\n"))
            XCTFail("Accepted newline in proof")
        } catch {}
        do { _ = try await client.pollPair(id: "pair", pollKey: "key\n"); XCTFail() } catch {}
    }

    func testCreatePairSendsObjectAndNativePOSTHeaders() async throws {
        respond("{\"id\":\"pair\",\"pollKey\":\"key\",\"linkUrl\":\"https://broker.example/link/pair#key\",\"qrImage\":\"data:image/png;base64,AA==\",\"expiresAt\":1234}", status: 201) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TV-Request"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let object = try JSONSerialization.jsonObject(with: try requestBody(request)) as! [String: String]
            XCTAssertEqual(object, ["name": "Apple TV"])
        }
        let pair = try await client.createPair()
        XCTAssertEqual(pair.expiresAt, 1234)
    }

    func testFinishPairCapturesBothSecretsAtomically() async throws {
        let old = SessionCredentials(cookieValue: cookie, tvProof: proof)
        try await client.restoreSession(old)
        respond("{\"profile\":" + profileJSON + ",\"tvProof\":\"bad\"}", headers: ["Set-Cookie": "boostytv=" + String(repeating: "c", count: 43) + "; Secure; HttpOnly; Path=/"]) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Poll-Key"), "poll_key")
            XCTAssertEqual(String(data: try requestBody(request), encoding: .utf8), "{}")
        }
        do { _ = try await client.finishPair(id: "pair-id", pollKey: "poll_key"); XCTFail() } catch {}
        let unchanged = await client.currentSession()
        XCTAssertEqual(unchanged, old)
        let replacement = SessionCredentials(cookieValue: String(repeating: "c", count: 43), tvProof: String(repeating: "d", count: 43))
        respond("{\"profile\":" + profileJSON + ",\"tvProof\":\"" + replacement.tvProof + "\"}")
        do { _ = try await client.finishPair(id: "pair-id", pollKey: "poll_key"); XCTFail("Missing cookie accepted") } catch {}
        let missingCookie = await client.currentSession()
        XCTAssertEqual(missingCookie, old)
        respond("{\"profile\":" + profileJSON + ",\"tvProof\":\"" + replacement.tvProof + "\"}", headers: ["Set-Cookie": "boostytv=" + replacement.cookieValue + "; Secure; HttpOnly; Path=/"])
        _ = try await client.finishPair(id: "pair-id", pollKey: "poll_key")
        let installed = await client.currentSession()
        XCTAssertEqual(installed, replacement)
    }

    func testPendingFinishCannotRestoreSessionAfterLocalClear() async throws {
        let started = expectation(description: "Pair finish started")
        let release = DispatchSemaphore(value: 0)
        respond("{\"profile\":" + profileJSON + ",\"tvProof\":\"" + proof + "\"}", headers: ["Set-Cookie": "boostytv=" + cookie + "; Secure; HttpOnly; Path=/"]) { _ in
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        }
        let pending = Task { try await self.client.finishPair(id: "pair", pollKey: "key") }
        await fulfillment(of: [started], timeout: 1)
        try await client.restoreSession(nil)
        release.signal()
        do { _ = try await pending.value; XCTFail("Late finish restored session") }
        catch is CancellationError {}
        let value = await client.currentSession()
        XCTAssertNil(value)
    }

    func testCancelledCompletedFinishDoesNotInstallCredentials() async throws {
        let started = expectation(description: "network started")
        let occupied = expectation(description: "actor occupied")
        let delivered = expectation(description: "response delivered")
        let networkRelease = DispatchSemaphore(value: 0)
        let actorRelease = DispatchSemaphore(value: 0)
        respond("{\"profile\":" + profileJSON + ",\"tvProof\":\"" + proof + "\"}", headers: ["Set-Cookie": "boostytv=" + cookie + "; Secure; Path=/"]) { _ in
            started.fulfill()
            XCTAssertEqual(networkRelease.wait(timeout: .now() + 5), .success)
        }
        StubProtocol.afterFinish = { delivered.fulfill() }
        let pending = Task { try await self.client.finishPair(id: "pair", pollKey: "key") }
        await fulfillment(of: [started], timeout: 2)
        let blocker = Task { await self.client.holdForTest(occupied, release: actorRelease) }
        await fulfillment(of: [occupied], timeout: 2)
        networkRelease.signal()
        await fulfillment(of: [delivered], timeout: 2)
        pending.cancel()
        actorRelease.signal()
        await blocker.value
        do { _ = try await pending.value; XCTFail("Cancelled completed finish installed a session") }
        catch is CancellationError {}
        let saved = await client.currentSession()
        XCTAssertNil(saved)
    }

    func testRouteAndCursorValidationAndEncoding() async throws {
        let cursor = "opaque+/%=?&next=42"
        respond("{\"items\":[],\"nextOffset\":\"opaque-next\"}") { request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(parts.path, "/base/api/blog/author.name-1")
            XCTAssertEqual(request.url?.query, "offset=opaque%2B/%25%3D?%26next%3D42")
            let formValue = parts.percentEncodedQuery!.dropFirst("offset=".count)
                .replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            XCTAssertEqual(formValue, cursor)
        }
        let page = try await client.feed(blog: "author.name-1", offset: cursor)
        XCTAssertEqual(page.nextOffset, "opaque-next")
        StubProtocol.handler = { _ in XCTFail("Invalid input reached network"); throw URLError(.badURL) }
        for blog in ["../outside", "%2fescape", "", "ümlaut", String(repeating: "a", count: 161), ".", "..", "author\n"] {
            do { _ = try await client.feed(blog: blog); XCTFail(blog) } catch {}
        }
        for cursor in ["bad\nvalue", String(repeating: "a", count: 257)] {
            do { _ = try await client.feed(offset: cursor); XCTFail() } catch {}
        }
        let endpoint = try BrokerEndpoint("https://broker.example/base")
        XCTAssertEqual(try endpoint.requestURL(path: ["api", "a/b ?#"]).absoluteString, "https://broker.example/base/api/a%2Fb%20%3F%23")
    }

    func testProgressFloorsAndSendsZeroAndRejectsInvalidValues() async throws {
        for (input, expected) in [(0.0, 0), (42.99, 42), (604800.0, 604800)] {
            respond("{\"ok\":true}") { request in
                let body = try JSONSerialization.jsonObject(with: try requestBody(request)) as! [String: Any]
                XCTAssertEqual(body["videoId"] as? String, "video-1")
                XCTAssertEqual(body["seconds"] as? Int, expected)
            }
            try await client.saveProgress(videoID: "video-1", seconds: input)
        }
        StubProtocol.handler = { _ in XCTFail("Invalid progress reached network"); throw URLError(.badURL) }
        for value in [-1.0, .nan, .infinity, -.infinity, 604800.1] {
            do { try await client.saveProgress(videoID: "video-1", seconds: value); XCTFail() } catch {}
        }
    }

    func testErrorMappingRedactsServerInternalsAndPairExpiry() async throws {
        respond("{\"code\":\"reconnect\",\"message\":\"https://signed.example/?secret=TOKEN\"}", status: 401)
        do { _ = try await client.me(); XCTFail() }
        catch let error as BrokerError {
            XCTAssertTrue(error.requiresPairing)
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.code, "reconnect")
            XCTAssertFalse(error.localizedDescription.contains("TOKEN"))
            XCTAssertFalse(String(describing: error).contains("TOKEN"))
        }
        for status in [404, 410] {
            respond("{\"code\":\"pair_missing\"}", status: status)
            do { _ = try await client.pollPair(id: "pair", pollKey: "key"); XCTFail() }
            catch let error as BrokerError { XCTAssertTrue(error.isExpiredPair) }
        }
    }

    func testRedirectsCannotLeakCookieProofOrPollKeyOutsideBroker() async throws {
        try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof))
        for destination in ["https://evil.example/capture", "http://broker.example/base/capture", "https://broker.example/outside", "https://broker.example/base-evil/capture", "https://broker.example:8443/base/capture", "https://broker.example/base/%2e%2e/capture"] {
            var count = 0
            respond("{}", status: 302, headers: ["Location": destination]) { _ in
                count += 1
                XCTAssertEqual(count, 1, "Redirect escaped endpoint: " + destination)
            }
            do { _ = try await client.pollPair(id: "pair-id", pollKey: "secret_key"); XCTFail() } catch {}
            XCTAssertEqual(count, 1)
        }
    }

    func testSameBrokerRedirectKeepsExplicitCredentials() async throws {
        try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof))
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            if count == 1 { return (302, ["Location": "https://broker.example/base/api/pairs/redirected"], Data()) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "boostytv=" + self.cookie)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TV-Proof"), self.proof)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Poll-Key"), "secret_key")
            return (200, [:], Data("{\"state\":\"waiting\",\"name\":\"TV\",\"expiresAt\":1234}".utf8))
        }
        _ = try await client.pollPair(id: "pair-id", pollKey: "secret_key")
        XCTAssertEqual(count, 2)
    }

    func testLogoutClearsLocalSessionWhenOffline() async throws {
        try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof))
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await client.logout(); XCTFail() } catch {}
        let saved = await client.currentSession()
        XCTAssertNil(saved)
    }

    func testQRCodeUsesAuthenticatedPOSTAndReturnsValidatedPNG() async throws {
        try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof))
        let image = "data:image/png;base64,iVBORw0KGgo="
        respond("{\"qrImage\":\"" + image + "\"}") { request in
            XCTAssertEqual(request.url?.absoluteString, "https://broker.example/base/api/qr")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "boostytv=" + self.cookie)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TV-Proof"), self.proof)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), BrokerClient.userAgent)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TV-Request"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let object = try JSONSerialization.jsonObject(with: try requestBody(request)) as! [String: String]
            XCTAssertEqual(object, ["url": "https://boosty.to/author/posts/post?access=a+b#chapter"])
        }
        let result = try await client.qrCode(for: URL(string: "https://boosty.to/author/posts/post?access=a+b#chapter")!)
        XCTAssertEqual(result, image)
    }

    func testQRCodeRejectsUnsafeURLsBeforeNetworking() async throws {
        StubProtocol.handler = { _ in XCTFail("Invalid QR URL reached network"); throw URLError(.badURL) }
        for input in ["http://boosty.to/post", "https://user:secret@boosty.to/post", "file:///post", "/relative", "https://boosty.to/" + String(repeating: "a", count: 1800)] {
            do { _ = try await client.qrCode(for: URL(string: input)!); XCTFail(input) }
            catch let error as BrokerError { XCTAssertEqual(error.code, "invalid_input") }
        }
    }

    func testQRCodeRejectsMalformedOrOversizedPNGResponses() async throws {
        for image in ["https://cdn.example/qr.png", "data:image/jpeg;base64,/9j/2Q==", "data:image/png;base64,!!!", "data:image/png;base64,AA==", "data:image/png;base64,", "data:image/png;base64,iVBORw0KGgo=\n", "data:image/png;base64," + Data(repeating: 0, count: 1048577).base64EncodedString()] {
            let data = try JSONSerialization.data(withJSONObject: ["qrImage": image])
            respond(String(decoding: data, as: UTF8.self))
            do { _ = try await client.qrCode(for: URL(string: "https://boosty.to/post")!); XCTFail("Invalid PNG accepted") }
            catch let error as BrokerError { XCTAssertEqual(error.code, "invalid_response") }
        }
    }

    func testPreviewUsesContentIdentifierAndPreservesFiniteSecondsWithoutArbitraryMaximum() async throws {
        try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof))
        for seconds in [0.0, 42.75, 604801.0] {
            respond("{\"image\":\"data:image/jpeg;base64,/9j/2Q==\",\"seconds\":" + String(seconds) + "}") { request in
                XCTAssertEqual(request.url?.path, "/base/api/preview/author.name-1/post-id/content_id")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "seconds", value: String(seconds))])
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "boostytv=" + self.cookie)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-TV-Proof"), self.proof)
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), BrokerClient.userAgent)
            }
            let preview = try await client.preview(blog: "author.name-1", postID: "post-id", contentID: "content_id", seconds: seconds)
            XCTAssertEqual(preview.image, "data:image/jpeg;base64,/9j/2Q==")
            XCTAssertEqual(preview.seconds, seconds)
        }
    }

    func testPreviewRejectsEncodedIdentifiersAndInvalidSecondsBeforeNetworking() async throws {
        StubProtocol.handler = { _ in XCTFail("Invalid preview input reached network"); throw URLError(.badURL) }
        for invalid in ["..", "%2fescape", "a/b", "post?seconds=0", "", String(repeating: "x", count: 161)] {
            for (blog, post, content) in [(invalid, "post", "content"), ("blog", invalid, "content"), ("blog", "post", invalid)] {
                do { _ = try await client.preview(blog: blog, postID: post, contentID: content, seconds: 0); XCTFail(invalid) }
                catch let error as BrokerError { XCTAssertEqual(error.code, "invalid_input") }
            }
        }
        for seconds in [-1.0, .nan, .infinity, -.infinity] {
            do { _ = try await client.preview(blog: "blog", postID: "post", contentID: "content", seconds: seconds); XCTFail() }
            catch let error as BrokerError { XCTAssertEqual(error.code, "invalid_input") }
        }
    }

    func testPreviewRejectsMalformedJPEGAndInvalidResponseSeconds() async throws {
        for image in ["data:image/png;base64,iVBORw0KGgo=", "data:image/jpeg;base64,!!!", "data:image/jpeg;base64,AA==", "data:image/jpeg;base64,/9gAAA==", "data:image/jpeg;base64," + Data(repeating: 0, count: 65537).base64EncodedString()] {
            respond("{\"image\":\"" + image + "\",\"seconds\":0}")
            do { _ = try await client.preview(blog: "blog", postID: "post", contentID: "content", seconds: 0); XCTFail("Invalid JPEG accepted") }
            catch let error as BrokerError { XCTAssertEqual(error.code, "invalid_response") }
        }
        for seconds in ["-1", "1e999", "null", "\"NaN\"", "1"] {
            respond("{\"image\":\"data:image/jpeg;base64,/9j/2Q==\",\"seconds\":" + seconds + "}")
            do { _ = try await client.preview(blog: "blog", postID: "post", contentID: "content", seconds: 0); XCTFail("Invalid seconds accepted") }
            catch let error as BrokerError { XCTAssertEqual(error.code, "invalid_response") }
        }
    }

    func testQRCodeAndPreviewDoNotFollowCrossOriginRedirects() async throws {
        try await client.restoreSession(SessionCredentials(cookieValue: cookie, tvProof: proof))
        var requests = 0
        respond("{}", status: 307, headers: ["Location": "https://evil.example/capture"]) { _ in
            requests += 1
        }
        do { _ = try await client.qrCode(for: URL(string: "https://boosty.to/post?secret=TOKEN")!); XCTFail() }
        catch let error as BrokerError { XCTAssertEqual(error.status, 307) }
        XCTAssertEqual(requests, 1)
        do { _ = try await client.preview(blog: "blog", postID: "post", contentID: "content", seconds: 0); XCTFail() }
        catch let error as BrokerError { XCTAssertEqual(error.status, 307) }
        XCTAssertEqual(requests, 2)
    }

    func testQRCodeAndPreviewMapUnauthorizedWithoutLeakingCredentials() async throws {
        respond("{\"code\":\"reconnect\",\"message\":\"https://internal/?secret=TOKEN\"}", status: 401) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-TV-Proof"))
        }
        do { _ = try await client.qrCode(for: URL(string: "https://boosty.to/post")!); XCTFail() }
        catch let error as BrokerError {
            XCTAssertTrue(error.requiresPairing)
            XCTAssertEqual(error.status, 401)
            XCTAssertFalse(String(describing: error).contains("TOKEN"))
        }
        do { _ = try await client.preview(blog: "blog", postID: "post", contentID: "content", seconds: 0); XCTFail() }
        catch let error as BrokerError {
            XCTAssertTrue(error.requiresPairing)
            XCTAssertEqual(error.status, 401)
            XCTAssertFalse(String(describing: error).contains("TOKEN"))
        }
    }

    func testOtherReadRoutesAndNullPairProfile() async throws {
        respond("{\"state\":\"waiting\",\"name\":\"Apple TV\",\"expiresAt\":1234,\"profile\":null}") { request in
            XCTAssertEqual(request.url?.path, "/base/api/pairs/pair-id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Poll-Key"), "key")
        }
        let status = try await client.pollPair(id: "pair-id", pollKey: "key")
        XCTAssertEqual(status.state, .waiting)
        XCTAssertNil(status.profile)
        respond("{\"items\":[{\"blog\":\"author\",\"title\":\"Title\",\"name\":\"Name\",\"avatar\":null}],\"nextOffset\":100}") { request in
            XCTAssertEqual(request.url?.query, "offset=0")
        }
        let subscriptions = try await client.subscriptions()
        XCTAssertEqual(subscriptions.items.first?.id, "author")
        XCTAssertEqual(subscriptions.nextOffset, 100)
        respond("{\"seconds\":42.5}") { request in
            XCTAssertEqual(request.url?.path, "/base/api/progress/blog/post/video")
        }
        let seconds = try await client.progress(blog: "blog", postID: "post", videoID: "video")
        XCTAssertEqual(seconds, 42.5)
    }
}

private extension BrokerClient {
    func holdForTest(_ occupied: XCTestExpectation, release: DispatchSemaphore) {
        occupied.fulfill()
        _ = release.wait(timeout: .now() + 5)
    }
}
