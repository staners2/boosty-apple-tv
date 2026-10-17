import BoostyCore
import Foundation
import XCTest
@testable import BoostyAppState

final class StateProtocol: URLProtocol {
    static var handler: ((StateProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func respond(_ json: String, status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class MemorySessions: SessionStoring {
    var credentials: [BrokerEndpoint: SessionCredentials] = [:]
    var saved: [BrokerEndpoint] = []
    var cleared: [BrokerEndpoint] = []
    var failClear = false
    var failLoad = false
    var failSave = false
    func load(for endpoint: BrokerEndpoint) throws -> SessionCredentials? {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        return credentials[endpoint]
    }
    func save(_ credentials: SessionCredentials, for endpoint: BrokerEndpoint) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        saved.append(endpoint)
        self.credentials[endpoint] = credentials
    }
    func clear(for endpoint: BrokerEndpoint) throws {
        cleared.append(endpoint)
        if failClear { throw CocoaError(.fileWriteNoPermission) }
        credentials[endpoint] = nil
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    let first = try! BrokerEndpoint("https://first.example")
    let second = try! BrokerEndpoint("https://second.example")
    let credential = SessionCredentials(cookieValue: String(repeating: "a", count: 43), tvProof: String(repeating: "b", count: 43))
    var storage: MemorySessions!
    var defaults: UserDefaults!
    var suite: String!

    override func setUp() async throws {
        storage = MemorySessions()
        suite = "BoostyAppStateTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        StateProtocol.handler = { stub in Self.standardResponse(stub) }
    }

    override func tearDown() async throws {
        StateProtocol.handler = nil
        defaults.removePersistentDomain(forName: suite)
    }

    func makeModel(progressFlushTimeout: Duration = .seconds(25)) -> AppModel {
        AppModel(storage: storage, defaults: defaults, progressFlushTimeout: progressFlushTimeout) { endpoint in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StateProtocol.self]
            return BrokerClient(endpoint: endpoint, session: URLSession(configuration: config))
        }
    }

    nonisolated static func pairJSON(_ id: String) -> String {
        "{\"id\":\"\(id)\",\"pollKey\":\"key\",\"linkUrl\":\"https://first.example/link\",\"qrImage\":\"data:image/png;base64,AA==\",\"expiresAt\":4102444800000}"
    }

    nonisolated static func standardResponse(_ stub: StateProtocol) {
        let url = stub.request.url!
        switch url.path {
        case "/api/me": stub.respond("{\"id\":\"\(url.host!)\",\"name\":\"Account\"}")
        case "/api/pairs": stub.respond(pairJSON(url.host == "first.example" ? "first-pair" : "second-pair"))
        case let path where path.hasPrefix("/api/pairs/"):
            stub.respond("{\"state\":\"confirm\",\"name\":\"TV\",\"expiresAt\":4102444800000,\"profile\":{\"id\":\"pending\",\"name\":\"Account\"}}")
        case let path where path.hasPrefix("/api/progress/"): stub.respond("{\"seconds\":10}")
        case "/api/subscriptions", "/api/feed": stub.respond("{\"items\":[],\"nextOffset\":null}")
        default: stub.respond("{\"ok\":true}")
        }
    }

    func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("State transition timed out", file: file, line: line)
    }

    func finishJSON() -> String {
        "{\"profile\":{\"id\":\"old-account\",\"name\":\"Old\"},\"tvProof\":\"\(credential.tvProof)\"}"
    }

    func testDelayedConfirmationCannotPersistAfterServerChange() async {
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await waitUntil { model.screen == .confirmation }
        let started = expectation(description: "finish pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasSuffix("/finish") { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let finish = Task { await model.confirmProfile() }
        await fulfillment(of: [started], timeout: 2)
        await model.connect(second.url.absoluteString)
        await waitUntil { model.screen == .confirmation }
        pending!.respond(finishJSON(), headers: ["Set-Cookie": "boostytv=\(credential.cookieValue); Secure; Path=/"])
        await finish.value
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.pair?.id, "second-pair")
        XCTAssertTrue(storage.saved.isEmpty)
        XCTAssertFalse(model.loading)
        model.changeServer()
    }

    func testDelayedConfirmationCannotPersistAfterAnotherAccount() async {
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await waitUntil { model.screen == .confirmation }
        let started = expectation(description: "finish pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasSuffix("/finish") { pending = stub; started.fulfill() }
            else if stub.request.url!.path == "/api/pairs" { stub.respond(Self.pairJSON("replacement")) }
            else { Self.standardResponse(stub) }
        }
        let finish = Task { await model.confirmProfile() }
        await fulfillment(of: [started], timeout: 2)
        await model.beginPairing()
        await waitUntil { model.pair?.id == "replacement" }
        pending!.respond(finishJSON(), headers: ["Set-Cookie": "boostytv=\(credential.cookieValue); Secure; Path=/"])
        await finish.value
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.pair?.id, "replacement")
        XCTAssertTrue(storage.saved.isEmpty)
        model.changeServer()
    }

    func testOverlappingPairCreationKeepsLatestOperation() async {
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let started = expectation(description: "first create pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/pairs", pending == nil { pending = stub; started.fulfill() }
            else if stub.request.url!.path == "/api/pairs" { stub.respond(Self.pairJSON("newest")) }
            else { Self.standardResponse(stub) }
        }
        let older = Task { await model.beginPairing() }
        await fulfillment(of: [started], timeout: 2)
        await model.beginPairing()
        pending!.respond(Self.pairJSON("stale"))
        await older.value
        XCTAssertEqual(model.pair?.id, "newest")
        model.changeServer()
    }

    func testOldSubscriptionSuccessCannotReplaceNewServerLibrary() async {
        await checkOldLibraryResponse(status: 200)
    }

    func testOldAuthenticationErrorCannotClearNewServerCredentials() async {
        await checkOldLibraryResponse(status: 401)
    }

    func checkOldLibraryResponse(status: Int) async {
        storage.credentials = [first: credential, second: credential]
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let started = expectation(description: "old subscriptions pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.host == "first.example", stub.request.url!.path == "/api/subscriptions" { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let oldLoad = Task { await model.loadLibrary() }
        await fulfillment(of: [started], timeout: 2)
        await model.connect(second.url.absoluteString)
        pending!.respond(status == 200 ? "{\"items\":[{\"blog\":\"old\",\"title\":\"Old\",\"name\":\"Old\"}],\"nextOffset\":null}" : "{\"code\":\"reconnect\"}", status: status)
        await oldLoad.value
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.profile?.id, "second.example")
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertFalse(storage.cleared.contains(second))
        model.changeServer()
    }

    func testPendingPlayCannotOpenAfterLogoutOrServerChange() async throws {
        storage.credentials = [first: credential, second: credential]
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        let started = expectation(description: "old post pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let play = Task { await model.play(post: post, videoID: "video") }
        await fulfillment(of: [started], timeout: 2)
        model.changeServer()
        await model.connect(second.url.absoluteString)
        pending!.respond(Self.postJSON)
        await play.value
        XCTAssertNil(model.playback)
        XCTAssertFalse(model.preparingVideo)
        XCTAssertEqual(model.profile?.id, "second.example")
        model.changeServer()
    }

    func testLogoutEndsAccessWhenSecureDeletionFailsAndPreventsRestore() async {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let oldClient = model.client!
        storage.failClear = true
        await model.logout()
        XCTAssertEqual(model.screen, .server)
        XCTAssertNil(model.profile)
        XCTAssertNil(model.client)
        let session = await oldClient.currentSession()
        XCTAssertNil(session)
        XCTAssertNotNil(model.errorMessage)
        let restored = makeModel()
        await restored.connect(first.url.absoluteString)
        XCTAssertNil(restored.profile)
        XCTAssertNotEqual(restored.screen, .library)
        restored.changeServer()
    }

    func testDelayedLogoutCannotResetNewConnection() async {
        storage.credentials = [first: credential, second: credential]
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let started = expectation(description: "logout pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/logout" { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let logout = Task { await model.logout() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.screen, .server)
        await model.connect(second.url.absoluteString)
        pending!.respond("{\"ok\":true}")
        await logout.value
        XCTAssertEqual(model.profile?.id, "second.example")
        XCTAssertEqual(model.screen, .library)
        model.changeServer()
    }

    func testSubscriptionsFailureSurvivesSuccessfulFeedLoad() async {
        storage.credentials[first] = credential
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/subscriptions" { stub.respond("{}", status: 503) }
            else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        XCTAssertEqual(model.screen, .library)
        XCTAssertNotNil(model.errorMessage)
        model.changeServer()
    }

    func testReopenWaitsForFinalProgressAndUsesLocalPositionIfWriteFailed() async throws {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        let started = expectation(description: "final write pending")
        var pendingWrite: StateProtocol?
        var requestedPost = false
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/progress" { pendingWrite = stub; started.fulfill() }
            else if stub.request.url!.path.hasPrefix("/api/post/") {
                requestedPost = true
                stub.respond(Self.postJSON)
            } else { Self.standardResponse(stub) }
        }
        model.progress!.enqueue(videoID: "video", seconds: 81)
        await fulfillment(of: [started], timeout: 2)
        let reopen = Task { await model.play(post: post, videoID: "video") }
        await Task.yield()
        XCTAssertNil(model.playback)
        XCTAssertFalse(requestedPost)
        pendingWrite!.respond("{}", status: 503)
        await reopen.value
        XCTAssertTrue(requestedPost)
        XCTAssertEqual(model.playback?.startSeconds, 81)
        XCTAssertTrue(model.playback?.progress === model.progress)
        XCTAssertNotNil(model.progress?.warning)
        XCTAssertEqual(model.resumeSeconds(for: post.videos[0]), 81)
        model.changeServer()
    }

    func testCorruptStoredSessionHasClearAndPairRecovery() async {
        storage.failLoad = true
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        XCTAssertEqual(model.screen, .pairing)
        XCTAssertTrue(model.needsStoredSessionRecovery)
        XCTAssertNil(model.profile)
        XCTAssertNotNil(model.errorMessage)
        storage.failLoad = false
        await model.clearStoredSessionAndPair()
        await waitUntil { model.screen == .confirmation }
        XCTAssertFalse(model.needsStoredSessionRecovery)
        XCTAssertEqual(storage.cleared, [first])
        model.changeServer()
    }

    func testFailedStoredDeletionCanBeRetriedWithoutRestoringAccess() async {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        storage.failClear = true
        await model.logout()
        XCTAssertTrue(model.canRetryStoredSessionRemoval)
        model.retryStoredSessionRemoval()
        XCTAssertTrue(model.canRetryStoredSessionRemoval)
        storage.failClear = false
        model.retryStoredSessionRemoval()
        XCTAssertFalse(model.canRetryStoredSessionRemoval)
        XCTAssertNil(storage.credentials[first])
        XCTAssertEqual(model.screen, .server)
        XCTAssertNil(model.client)
    }

    func testOldPostAuthenticationFailureIsCancelledWithoutClearingNewSession() async throws {
        storage.credentials = [first: credential, second: credential]
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        let started = expectation(description: "post detail pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let fetch = Task { try await model.fetchPost(post) }
        await fulfillment(of: [started], timeout: 2)
        await model.connect(second.url.absoluteString)
        pending!.respond("{\"code\":\"reconnect\"}", status: 401)
        do { _ = try await fetch.value; XCTFail("Stale post returned") }
        catch is CancellationError { }
        XCTAssertEqual(model.profile?.id, "second.example")
        XCTAssertFalse(storage.cleared.contains(second))
        XCTAssertNil(model.errorMessage)
        model.changeServer()
    }

    func testStaleConfirmationErrorDoesNotClearNewOperationLoadingOrError() async {
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await waitUntil { model.screen == .confirmation }
        let oldStarted = expectation(description: "old finish pending")
        let newStarted = expectation(description: "new finish pending")
        var oldFinish: StateProtocol?
        var newFinish: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasSuffix("/finish") {
                if oldFinish == nil { oldFinish = stub; oldStarted.fulfill() }
                else { newFinish = stub; newStarted.fulfill() }
            } else if stub.request.url!.path == "/api/pairs" { stub.respond(Self.pairJSON("new-pair")) }
            else { Self.standardResponse(stub) }
        }
        let old = Task { await model.confirmProfile() }
        await fulfillment(of: [oldStarted], timeout: 2)
        await model.beginPairing()
        await waitUntil { model.screen == .confirmation }
        let latest = Task { await model.confirmProfile() }
        await fulfillment(of: [newStarted], timeout: 2)
        oldFinish!.respond("{}", status: 410)
        await old.value
        XCTAssertTrue(model.loading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pair?.id, "new-pair")
        newFinish!.respond(finishJSON(), headers: ["Set-Cookie": "boostytv=\(credential.cookieValue); Secure; Path=/"])
        await latest.value
        XCTAssertEqual(model.screen, .library)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(storage.saved, [first])
        model.changeServer()
    }

    func testDeliberatePairClearsLogoutTombstoneOnlyAfterSuccessfulFinish() async {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await model.logout()
        let key = "loggedOut:" + first.url.absoluteString
        XCTAssertTrue(defaults.bool(forKey: key))
        await model.connect(first.url.absoluteString)
        await waitUntil { model.screen == .confirmation }
        XCTAssertTrue(defaults.bool(forKey: key))
        let json = finishJSON()
        let cookie = credential.cookieValue
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasSuffix("/finish") {
                stub.respond(json, headers: ["Set-Cookie": "boostytv=\(cookie); Secure; Path=/"])
            } else { Self.standardResponse(stub) }
        }
        await model.confirmProfile()
        XCTAssertEqual(model.screen, .library)
        XCTAssertFalse(defaults.bool(forKey: key))
        let restored = makeModel()
        await restored.connect(first.url.absoluteString)
        XCTAssertEqual(restored.screen, .library)
        XCTAssertEqual(restored.profile?.id, "first.example")
        model.changeServer()
        restored.changeServer()
    }

    func testInvalidStoredCredentialsHaveExplicitRecovery() async {
        storage.credentials[first] = SessionCredentials(cookieValue: "invalid", tvProof: credential.tvProof)
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        XCTAssertEqual(model.screen, .pairing)
        XCTAssertTrue(model.needsStoredSessionRecovery)
        XCTAssertNil(model.profile)
        await model.clearStoredSessionAndPair()
        await waitUntil { model.screen == .confirmation }
        XCTAssertNil(storage.credentials[first])
        model.changeServer()
    }

    func testTimedOutReopenRetainsFinalPositionAcknowledgedDuringPostRead() async throws {
        try await checkAcknowledgementDuringPostRead(newerBackwardPosition: nil)
    }

    func testTimedOutReopenPrefersNewerAcknowledgedBackwardPositionToSnapshot() async throws {
        try await checkAcknowledgementDuringPostRead(newerBackwardPosition: 12)
    }

    private func checkAcknowledgementDuringPostRead(newerBackwardPosition: Double?) async throws {
        storage.credentials[first] = credential
        let model = makeModel(progressFlushTimeout: .milliseconds(5))
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        let firstStarted = expectation(description: "save40 pending")
        let finalStarted = expectation(description: "save80 pending")
        let postStarted = expectation(description: "post captured server40 after bounded flush")
        let backwardStarted = newerBackwardPosition.map { _ in expectation(description: "backward save pending") }
        var firstWrite: StateProtocol?
        var finalWrite: StateProtocol?
        var backwardWrite: StateProtocol?
        var pendingPost: StateProtocol?
        var serverPosition = 0.0
        var capturedPosition = 0.0
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/progress" {
                if firstWrite == nil { firstWrite = stub; firstStarted.fulfill() }
                else if finalWrite == nil { finalWrite = stub; finalStarted.fulfill() }
                else { backwardWrite = stub; backwardStarted!.fulfill() }
            } else if stub.request.url!.path.hasPrefix("/api/post/") {
                capturedPosition = serverPosition
                pendingPost = stub
                postStarted.fulfill()
            } else { Self.standardResponse(stub) }
        }
        let progress = model.progress!
        progress.enqueue(videoID: "video", seconds: 40)
        await fulfillment(of: [firstStarted], timeout: 2)
        progress.enqueue(videoID: "video", seconds: 80)
        let reopen = Task { await model.play(post: post, videoID: "video") }
        serverPosition = 40
        firstWrite!.respond("{\"ok\":true}")
        await fulfillment(of: [finalStarted, postStarted], timeout: 2)
        XCTAssertEqual(capturedPosition, 40)
        XCTAssertNil(model.playback)
        XCTAssertNotNil(progress.warning)
        serverPosition = 80
        finalWrite!.respond("{\"ok\":true}")
        await progress.flush()
        XCTAssertNil(progress.localPosition(videoID: "video"))
        if let newerBackwardPosition {
            progress.enqueue(videoID: "video", seconds: newerBackwardPosition)
            await fulfillment(of: [backwardStarted!], timeout: 2)
            serverPosition = newerBackwardPosition
            backwardWrite!.respond("{\"ok\":true}")
            await progress.flush()
            XCTAssertNil(progress.localPosition(videoID: "video"))
        }
        pendingPost!.respond(Self.postJSON.replacingOccurrences(of: "\"timeCode\":10", with: "\"timeCode\":\(capturedPosition)"))
        await reopen.value
        XCTAssertEqual(model.playback?.startSeconds, newerBackwardPosition ?? 80)
        XCTAssertNil(progress.warning)
        // A later read with no overlapping local write must accept new progress from another device.
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") {
                stub.respond(Self.postJSON.replacingOccurrences(of: "\"timeCode\":10", with: "\"timeCode\":95"))
            } else if stub.request.url!.path.hasPrefix("/api/progress/") { stub.respond("{\"seconds\":95}") }
            else { Self.standardResponse(stub) }
        }
        model.playback = nil
        await model.play(post: post, videoID: "video")
        XCTAssertEqual(model.playback?.startSeconds, 95)
        model.changeServer()
    }

    nonisolated static func postJSON(id: String, blog: String, published: Int) -> String {
        postJSON.replacingOccurrences(of: "\"id\":\"post\"", with: "\"id\":\"\(id)\"")
            .replacingOccurrences(of: "\"blog\":\"blog\"", with: "\"blog\":\"\(blog)\"")
            .replacingOccurrences(of: "\"publishedAt\":1", with: "\"publishedAt\":\(published)")
    }

    func testParityFeedUsesCompositeIdentityDeduplicatesAndSortsAllPages() async {
        storage.credentials[first] = credential
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/feed" {
                let next = stub.request.url!.query != nil
                let items = next
                    ? [Self.postJSON(id: "shared", blog: "other", published: 30), Self.postJSON(id: "last", blog: "blog", published: 40), Self.postJSON(id: "last", blog: "blog", published: 40)]
                    : [Self.postJSON(id: "shared", blog: "blog", published: 10), Self.postJSON(id: "shared", blog: "blog", published: 10), Self.postJSON(id: "middle", blog: "blog", published: 20)]
                stub.respond("{\"items\":[" + items.joined(separator: ",") + "],\"nextOffset\":" + (next ? "null" : "\"page2\"") + "}")
            } else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await model.loadFeed(blog: nil, more: true)
        XCTAssertEqual(model.posts.map { $0.blog + "/" + $0.id }, ["blog/last", "other/shared", "blog/middle", "blog/shared"])
        model.changeServer()
    }

    func testParityRepeatedFeedCursorStopsPagination() async {
        storage.credentials[first] = credential
        var requests = 0
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/feed" {
                requests += 1
                stub.respond("{\"items\":[],\"nextOffset\":\"same\"}")
            } else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await model.loadFeed(blog: nil, more: true)
        XCTAssertFalse(model.hasMore)
        await model.loadFeed(blog: nil, more: true)
        XCTAssertEqual(requests, 2)
        model.changeServer()
    }

    func testParityPlaybackClosePreservesPagesAndAuthorWithoutFeedRequests() async {
        storage.credentials[first] = credential
        var requests = 0
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/feed" || stub.request.url!.path == "/api/blog/author" {
                requests += 1
                let more = stub.request.url!.query != nil
                stub.respond("{\"items\":[" + Self.postJSON(id: more ? "second" : "first", blog: "author", published: more ? 2 : 3) + "],\"nextOffset\":" + (more ? "\"third-page\"" : "\"page2\"") + "}")
            } else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await model.loadFeed(blog: "author")
        await model.loadFeed(blog: "author", more: true)
        let before = model.posts
        let count = requests
        await model.playbackClosed()
        XCTAssertEqual(model.posts, before)
        XCTAssertEqual(model.selectedBlog, "author")
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(requests, count)
        model.changeServer()
    }

    func testParityConsumedPairContinuesSessionWhenKeychainSaveFails() async {
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await waitUntil { model.screen == .confirmation }
        let json = finishJSON()
        let cookie = credential.cookieValue
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasSuffix("/finish") { stub.respond(json, headers: ["Set-Cookie": "boostytv=\(cookie); Secure; Path=/"]) }
            else { Self.standardResponse(stub) }
        }
        storage.failSave = true
        await model.confirmProfile()
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.profile?.id, "old-account")
        XCTAssertNil(model.pair)
        XCTAssertNotNil(model.errorMessage)
        model.changeServer()
    }

    func testParityOrdinaryPlaybackUsesProgressEndpointAndPrefersHLS() async throws {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        var progressReads = 0
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") {
                let sources = "{\"quality\":\"low\",\"label\":\"Low\",\"url\":\"https://cdn.example/low.mp4\"},{\"quality\":\"full_hd\",\"label\":\"Full HD\",\"url\":\"https://cdn.example/full.mp4\"},{\"quality\":\"hls\",\"label\":\"Auto\",\"url\":\"https://cdn.example/auto.m3u8\"}"
                let oldSources = "{\"quality\":\"mp4\",\"label\":\"MP4\",\"url\":\"https://cdn.example/video.mp4\"}"
                stub.respond(Self.postJSON.replacingOccurrences(of: oldSources, with: sources))
            } else if stub.request.url!.path.hasPrefix("/api/progress/") {
                progressReads += 1
                stub.respond("{\"seconds\":61}")
            } else { Self.standardResponse(stub) }
        }
        await model.play(post: post, videoID: "video")
        XCTAssertEqual(progressReads, 1)
        XCTAssertEqual(model.playback?.startSeconds, 61)
        XCTAssertEqual(model.playback?.source.quality, "hls")
        model.changeServer()
    }

    func testParityAccessDeniedProgressDoesNotFallBackToCachedPost() async throws {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { stub.respond(Self.postJSON) }
            else if stub.request.url!.path.hasPrefix("/api/progress/") { stub.respond("{\"code\":\"access_denied\"}", status: 403) }
            else { Self.standardResponse(stub) }
        }
        await model.play(post: post, videoID: "video")
        XCTAssertNil(model.playback)
        XCTAssertNotNil(model.errorMessage)
        model.changeServer()
    }

    func testParityFailedPageRetryKeepsCardsAndUsesExactCursor() async {
        storage.credentials[first] = credential
        var offsets: [String?] = []
        var failed = false
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/feed" {
                let offset = URLComponents(url: stub.request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first?.value
                offsets.append(offset)
                if offset != nil, !failed { failed = true; stub.respond("{}", status: 503) }
                else { stub.respond("{\"items\":[" + Self.postJSON(id: offset == nil ? "first" : "second", blog: "blog", published: offset == nil ? 2 : 1) + "],\"nextOffset\":" + (offset == nil ? "\"page+2\"" : "null") + "}") }
            } else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await model.loadFeed(blog: nil, more: true)
        XCTAssertEqual(model.posts.map(\.id), ["first"])
        XCTAssertNotNil(model.feedError)
        await model.retryFeed()
        XCTAssertEqual(offsets, [nil, "page+2", "page+2"])
        XCTAssertEqual(model.posts.map(\.id), ["first", "second"])
        XCTAssertNil(model.feedError)
        model.changeServer()
    }

    func testParityAutopaginationStartsOnlyWithinLastSixCards() async {
        storage.credentials[first] = credential
        var requests = 0
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/feed" {
                requests += 1
                let items = (1...10).reversed().map { Self.postJSON(id: "post-\($0)", blog: "blog", published: $0) }.joined(separator: ",")
                stub.respond("{\"items\":[" + items + "],\"nextOffset\":" + (requests == 1 ? "\"page2\"" : "null") + "}")
            } else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        await model.loadMoreIfNeeded(near: model.posts[3])
        XCTAssertEqual(requests, 1)
        await model.loadMoreIfNeeded(near: model.posts[4])
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(model.hasMore)
        model.changeServer()
    }

    func testParityBackCancelsPendingOpeningWithoutResettingSession() async throws {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        let started = expectation(description: "opening post pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let opening = Task { await model.play(post: post, videoID: "video") }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(model.openingID)
        model.cancelOpening()
        pending!.respond(Self.postJSON)
        await opening.value
        XCTAssertNil(model.playback)
        XCTAssertNil(model.openingID)
        XCTAssertFalse(model.preparingVideo)
        XCTAssertEqual(model.screen, .library)
        model.changeServer()
    }

    func testParityRuntimeUnauthorizedAutomaticallyCreatesNewQR() async {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/feed" { stub.respond("{\"code\":\"reconnect\"}", status: 401) }
            else { Self.standardResponse(stub) }
        }
        await model.loadFeed(blog: nil)
        await waitUntil { model.pair != nil }
        XCTAssertNil(model.profile)
        XCTAssertEqual(model.pair?.id, "first-pair")
        XCTAssertTrue(storage.cleared.contains(first))
        model.changeServer()
    }

    func testParityPollingPausesInBackgroundAndResumesSameQR() async {
        let model = makeModel()
        model.setActive(false)
        var polls = 0
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/pairs/") { polls += 1 }
            Self.standardResponse(stub)
        }
        await model.connect(first.url.absoluteString)
        let pairID = model.pair?.id
        XCTAssertEqual(model.screen, .pairing)
        XCTAssertEqual(polls, 0)
        model.setActive(true)
        await waitUntil { model.screen == .confirmation }
        XCTAssertEqual(polls, 1)
        XCTAssertEqual(model.pair?.id, pairID)
        model.changeServer()
    }

    func testParityLanguagePersistsWithoutNetworkOrNavigationReset() async {
        storage.credentials[first] = credential
        var requests = 0
        StateProtocol.handler = { stub in requests += 1; Self.standardResponse(stub) }
        let model = makeModel()
        XCTAssertEqual(model.language, .en)
        await model.connect(first.url.absoluteString)
        let client = model.client
        let count = requests
        let revision = model.playbackRevision
        model.language = .ru
        XCTAssertTrue(model.client === client)
        XCTAssertEqual(model.playbackRevision, revision)
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(requests, count)
        XCTAssertEqual(makeModel().language, .ru)
        model.language = .en
        XCTAssertEqual(makeModel().language, .en)
        model.changeServer()
    }

    func testParityReviewMalformedProgressNeverFallsBackToPost() async throws {
        for response in ["not JSON", "{\"seconds\":-1}", "{\"seconds\":\"invalid\"}"] {
            storage.credentials[first] = credential
            let model = makeModel()
            StateProtocol.handler = { stub in
                if stub.request.url!.path.hasPrefix("/api/post/") { stub.respond(Self.postJSON) }
                else if stub.request.url!.path.hasPrefix("/api/progress/") { stub.respond(response) }
                else { Self.standardResponse(stub) }
            }
            await model.connect(first.url.absoluteString)
            let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
            await model.play(post: post, videoID: "video")
            XCTAssertNil(model.playback, "Malformed progress must not start cached video: \(response)")
            XCTAssertNotNil(model.errorMessage)
            model.changeServer()
        }
    }

    func testParityReviewQRUnauthorizedAutomaticallyRepairsCurrentSession() async {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/qr" { stub.respond("{\"code\":\"reconnect\"}", status: 401) }
            else { Self.standardResponse(stub) }
        }
        do { _ = try await model.qrCode(for: URL(string: "https://example.com/handbook")!); XCTFail() }
        catch {}
        XCTAssertNil(model.profile)
        XCTAssertNotNil(model.pair)
        model.changeServer()
    }

    func testParityReviewStaleQRUnauthorizedCannotClearReplacementSession() async {
        storage.credentials = [first: credential, second: credential]
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let started = expectation(description: "old QR pending")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/qr" { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let qr = Task { try await model.qrCode(for: URL(string: "https://example.com/handbook")!) }
        await fulfillment(of: [started], timeout: 2)
        await model.connect(second.url.absoluteString)
        pending!.respond("{\"code\":\"reconnect\"}", status: 401)
        do { _ = try await qr.value; XCTFail("Stale QR should be cancelled") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error \(error)") }
        XCTAssertEqual(model.profile?.id, "second.example")
        XCTAssertEqual(model.screen, .library)
        XCTAssertFalse(storage.cleared.contains(second))
        model.changeServer()
    }

    func testParityReviewPlaybackAuthCallbackIsScopedToOriginatingSession() async throws {
        storage.credentials = [first: credential, second: credential]
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { stub.respond(Self.postJSON) }
            else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        await model.play(post: post, videoID: "video")
        let old = try XCTUnwrap(model.playback?.onAuthorizationFailure)
        await model.connect(second.url.absoluteString)
        await old()
        XCTAssertEqual(model.profile?.id, "second.example")
        XCTAssertFalse(storage.cleared.contains(second))
        await model.play(post: post, videoID: "video")
        let current = try XCTUnwrap(model.playback?.onAuthorizationFailure)
        await current()
        XCTAssertNil(model.profile)
        XCTAssertNotNil(model.pair)
        let pair = model.pair?.id
        await current()
        XCTAssertEqual(model.pair?.id, pair)
        model.changeServer()
    }

    func testParityReviewProgressServerFailureFallsBackToRefreshedPost() async throws {
        storage.credentials[first] = credential
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { stub.respond(Self.postJSON) }
            else if stub.request.url!.path.hasPrefix("/api/progress/") { stub.respond("{}", status: 503) }
            else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        await model.play(post: post, videoID: "video")
        XCTAssertEqual(model.playback?.startSeconds, 10)
        model.changeServer()
    }

    func testParityReviewQRRecoverySurvivesOriginatingSheetTaskCancellation() async {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let started = expectation(description: "recovery createPair delayed")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/qr" { stub.respond("{\"code\":\"reconnect\"}", status: 401) }
            else if stub.request.url!.path == "/api/pairs" { pending = stub; started.fulfill() }
            else if stub.request.url!.path.hasPrefix("/api/pairs/") {
                stub.respond("{\"state\":\"waiting\",\"name\":\"TV\",\"expiresAt\":4102444800000}")
            } else { Self.standardResponse(stub) }
        }
        let qr = Task { try await model.qrCode(for: URL(string: "https://example.com/handbook")!) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.screen, .connecting)
        qr.cancel() // SwiftUI cancels the sheet task after authentication removes its screen.
        pending!.respond(Self.pairJSON("recovery-pair"))
        do { _ = try await qr.value; XCTFail() }
        catch {}
        await waitUntil { model.pair?.id == "recovery-pair" }
        XCTAssertEqual(model.screen, .pairing)
        XCTAssertNil(model.profile)
        model.changeServer()
    }

    func testParityReviewPostRecoverySurvivesReaderTaskCancellation() async throws {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        let started = expectation(description: "post recovery createPair delayed")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { stub.respond("{\"code\":\"reconnect\"}", status: 401) }
            else if stub.request.url!.path == "/api/pairs" { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let reader = Task { try await model.fetchPost(post) }
        await fulfillment(of: [started], timeout: 2)
        reader.cancel()
        pending!.respond(Self.pairJSON("post-recovery"))
        do { _ = try await reader.value; XCTFail() }
        catch {}
        XCTAssertEqual(model.pair?.id, "post-recovery")
        model.changeServer()
    }

    func testParityReviewPlaybackRecoverySurvivesPlayerTaskCancellation() async throws {
        storage.credentials[first] = credential
        StateProtocol.handler = { stub in
            if stub.request.url!.path.hasPrefix("/api/post/") { stub.respond(Self.postJSON) }
            else { Self.standardResponse(stub) }
        }
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let post = try JSONDecoder().decode(Post.self, from: Data(Self.postJSON.utf8))
        await model.play(post: post, videoID: "video")
        let callback = try XCTUnwrap(model.playback?.onAuthorizationFailure)
        let started = expectation(description: "player recovery createPair delayed")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/pairs" { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let player = Task { await callback() }
        await fulfillment(of: [started], timeout: 2)
        player.cancel()
        pending!.respond(Self.pairJSON("player-recovery"))
        await player.value
        XCTAssertEqual(model.pair?.id, "player-recovery")
        model.changeServer()
    }

    func testParityReviewServerChangeCancelsOwnedRecovery() async {
        storage.credentials = [first: credential, second: credential]
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let started = expectation(description: "old recovery createPair delayed")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/qr" { stub.respond("{\"code\":\"reconnect\"}", status: 401) }
            else if stub.request.url!.path == "/api/pairs" { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let qr = Task { try await model.qrCode(for: URL(string: "https://example.com/handbook")!) }
        await fulfillment(of: [started], timeout: 2)
        await model.connect(second.url.absoluteString)
        pending!.respond(Self.pairJSON("abandoned-recovery"))
        do { _ = try await qr.value; XCTFail() }
        catch {}
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.profile?.id, "second.example")
        XCTAssertNil(model.pair)
        XCTAssertFalse(storage.cleared.contains(second))
        model.changeServer()
    }

    func testParityReviewLogoutCancelsOwnedRecovery() async {
        storage.credentials[first] = credential
        let model = makeModel()
        await model.connect(first.url.absoluteString)
        let started = expectation(description: "recovery createPair delayed before logout")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if stub.request.url!.path == "/api/qr" { stub.respond("{\"code\":\"reconnect\"}", status: 401) }
            else if stub.request.url!.path == "/api/pairs" { pending = stub; started.fulfill() }
            else { Self.standardResponse(stub) }
        }
        let qr = Task { try await model.qrCode(for: URL(string: "https://example.com/handbook")!) }
        await fulfillment(of: [started], timeout: 2)
        await model.logout()
        pending!.respond(Self.pairJSON("abandoned-after-logout"))
        do { _ = try await qr.value; XCTFail() }
        catch {}
        XCTAssertEqual(model.screen, .server)
        XCTAssertNil(model.profile)
        XCTAssertNil(model.pair)
        XCTAssertNil(model.client)
    }

    nonisolated static let postJSON = """
    {"id":"post","title":"Title","blog":"blog","author":"Author","summary":"Summary","createdAt":1,"publishedAt":1,"locked":false,"body":[],"videos":[{"id":"video","title":"Video","duration":100,"timeCode":10,"sources":[{"quality":"mp4","label":"MP4","url":"https://cdn.example/video.mp4"}]}]}
    """
}
