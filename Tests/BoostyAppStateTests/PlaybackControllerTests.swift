import AVFoundation
import BoostyCore
import XCTest
@testable import BoostyAppState

private final class ControlledItem: AVPlayerItem {
    private var controlledStatus: AVPlayerItem.Status = .unknown
    override var status: AVPlayerItem.Status { controlledStatus }
    func becomeReady() {
        willChangeValue(forKey: "status")
        controlledStatus = .readyToPlay
        didChangeValue(forKey: "status")
    }
    func fail() {
        willChangeValue(forKey: "status")
        controlledStatus = .failed
        didChangeValue(forKey: "status")
    }
}

private final class ControlledPlayer: AVPlayer {
    private var installed: AVPlayerItem?
    var completions: [(Bool) -> Void] = []
    var playCount = 0
    var targets: [Double] = []
    var controlledRate: Float = 0
    override var rate: Float { get { controlledRate } set { controlledRate = newValue } }
    var seconds = 60.0
    override var currentItem: AVPlayerItem? { installed }
    override func replaceCurrentItem(with item: AVPlayerItem?) { installed = item }
    override func currentTime() -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    override func play() { playCount += 1; controlledRate = 1 }
    override func pause() { controlledRate = 0 }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: @escaping @Sendable (Bool) -> Void) {
        targets.append(time.seconds)
        completions.append(completionHandler)
    }
}

private final class ItemList { var values: [ControlledItem] = [] }

@MainActor
final class PlaybackControllerTests: XCTestCase {
    private func makeController(progress: PlaybackProgress? = nil,
                                onAuthorizationFailure: (@MainActor () async -> Void)? = nil,
                                postJSON: String = AppModelTests.postJSON) throws -> (PlaybackController, ControlledPlayer, ItemList) {
        let post = try JSONDecoder().decode(Post.self, from: Data(postJSON.utf8))
        let video = post.videos[0]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StateProtocol.self]
        let client = BrokerClient(endpoint: try BrokerEndpoint("https://first.example"), session: URLSession(configuration: config))
        let request = PlaybackRequest(post: post, video: video, source: video.sources[0], startSeconds: 10,
                                      client: client, progress: progress ?? PlaybackProgress { _, _ in },
                                      onAuthorizationFailure: onAuthorizationFailure)
        let player = ControlledPlayer()
        let items = ItemList()
        let controller = PlaybackController(request: request, player: player) { _ in
            let item = ControlledItem(asset: AVMutableComposition())
            items.values.append(item)
            return item
        }
        return (controller, player, items)
    }

    private func drainCallbacks() async {
        // KVO and seek handlers explicitly hop onto MainActor.
        for _ in 0..<5 { await Task.yield() }
    }

    func testScrubSelectionDoesNotSeekUntilConfirmedAndCancelKeepsPosition() async throws {
        let (controller, player, items) = try makeController()
        defer { controller.stop() }
        items.values[0].becomeReady(); await drainCallbacks()
        player.completions[0](true); await drainCallbacks()
        controller.beginScrub()
        controller.moveScrub(by: 10)
        controller.moveScrub(by: 10)
        XCTAssertEqual(controller.scrubSeconds, 80)
        XCTAssertEqual(player.targets, [10])
        controller.cancelScrub()
        XCTAssertNil(controller.scrubSeconds)
        XCTAssertEqual(player.targets, [10])
        controller.beginScrub(); controller.moveScrub(by: -10); controller.commitScrub()
        XCTAssertEqual(player.targets, [10, 50])
        player.seconds = 50; player.completions[1](true); await drainCallbacks()
        XCTAssertNil(controller.scrubSeconds)
    }

    func testQualitySwitchPreservesPausedPosition() async throws {
        let (controller, player, items) = try makeController()
        defer { controller.stop(); StateProtocol.handler = nil }
        items.values[0].becomeReady(); await drainCallbacks()
        player.completions[0](true); await drainCallbacks()
        player.pause(); player.seconds = 42
        StateProtocol.handler = { $0.respond(AppModelTests.postJSON) }
        await controller.changeQuality(controller.request.source)
        items.values[1].becomeReady(); await drainCallbacks()
        XCTAssertEqual(player.targets, [10, 42])
        player.completions[1](true); await drainCallbacks()
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(player.rate, 0)
    }

    func testNewQualityWinsOverPendingRetryInEitherResponseOrder() async throws {
        let json = AppModelTests.postJSON.replacingOccurrences(of: "\"sources\":[", with:
            "\"sources\":[{\"quality\":\"full_hd\",\"label\":\"1080p\",\"url\":\"https://cdn.example/full.mp4\"},")
        for oldFirst in [true, false] {
            let (controller, player, items) = try makeController(postJSON: json)
            items.values[0].becomeReady(); await drainCallbacks()
            player.completions[0](true); await drainCallbacks()
            player.pause(); player.seconds = 42
            items.values[0].fail(); await drainCallbacks()
            let retryStarted = expectation(description: "retry A pending")
            let qualityStarted = expectation(description: "quality B pending")
            var replies: [StateProtocol] = []
            StateProtocol.handler = {
                replies.append($0)
                if replies.count == 1 { retryStarted.fulfill() } else { qualityStarted.fulfill() }
            }
            let retry = Task { await controller.retry() }
            await fulfillment(of: [retryStarted], timeout: 2)
            let quality = Task { await controller.changeQuality(controller.request.video.sources[1]) }
            await fulfillment(of: [qualityStarted], timeout: 2)
            if oldFirst {
                replies[0].respond(json); await retry.value
                XCTAssertEqual(items.values.count, 1)
                XCTAssertTrue(controller.preparing)
                replies[1].respond(json); await quality.value
            } else {
                replies[1].respond(json); await quality.value
                replies[0].respond(json); await retry.value
            }
            XCTAssertEqual(controller.currentSource.quality, "mp4")
            XCTAssertEqual(items.values.count, 2)
            items.values[1].becomeReady(); await drainCallbacks()
            XCTAssertEqual(player.targets.last, 42)
            player.completions.last?(true); await drainCallbacks()
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.playCount, 1)
            controller.stop()
        }
        StateProtocol.handler = nil
    }

    func testOldRetryAuthorizationFailureCannotDefeatPendingQualityIntent() async throws {
        let json = AppModelTests.postJSON.replacingOccurrences(of: "\"sources\":[", with:
            "\"sources\":[{\"quality\":\"full_hd\",\"label\":\"1080p\",\"url\":\"https://cdn.example/full.mp4\"},")
        var reconnects = 0
        let (controller, player, items) = try makeController(onAuthorizationFailure: { reconnects += 1 }, postJSON: json)
        defer { controller.stop(); StateProtocol.handler = nil }
        items.values[0].becomeReady(); await drainCallbacks()
        player.completions[0](true); await drainCallbacks()
        let retryStarted = expectation(description: "retry pending")
        let qualityStarted = expectation(description: "quality pending")
        var replies: [StateProtocol] = []
        StateProtocol.handler = {
            replies.append($0)
            if replies.count == 1 { retryStarted.fulfill() } else { qualityStarted.fulfill() }
        }
        let retry = Task { await controller.retry() }
        await fulfillment(of: [retryStarted], timeout: 2)
        let quality = Task { await controller.changeQuality(controller.request.video.sources[1]) }
        await fulfillment(of: [qualityStarted], timeout: 2)
        replies[0].respond("{\"code\":\"reconnect\"}", status: 401)
        await retry.value
        XCTAssertEqual(reconnects, 0)
        replies[1].respond(json); await quality.value
        XCTAssertEqual(controller.currentSource.quality, "mp4")
        XCTAssertNil(controller.playbackError)
    }

    func testCompletedPlaybackRestartsAndChapterSeekResumes() async throws {
        let (controller, player, items) = try makeController()
        defer { controller.stop() }
        items.values[0].becomeReady(); await drainCallbacks()
        player.completions[0](true); await drainCallbacks()
        player.pause()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: items.values[0])
        await drainCallbacks()
        XCTAssertTrue(controller.ended)
        controller.togglePlayback()
        XCTAssertEqual(player.targets.last, 0)
        player.completions[1](true); await drainCallbacks()
        XCTAssertEqual(player.playCount, 2)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: items.values[0])
        await drainCallbacks()
        controller.seek(to: 25)
        player.completions[2](true); await drainCallbacks()
        XCTAssertEqual(player.targets.last, 25)
        XCTAssertEqual(player.playCount, 3)
        XCTAssertFalse(controller.ended)
    }

    func testFailedCurrentSeekIsVisibleButCancelledOldSeekIsIgnored() async throws {
        let (controller, player, items) = try makeController()
        defer { controller.stop() }
        items.values[0].becomeReady(); await drainCallbacks()
        player.completions[0](true); await drainCallbacks()
        controller.seek(to: 20); controller.seek(to: 30)
        player.completions[1](false); await drainCallbacks()
        XCTAssertNil(controller.playbackError)
        player.completions[2](false); await drainCallbacks()
        XCTAssertNotNil(controller.playbackError)
    }

    func testQualityCanRecoverFailedInitialSource() async throws {
        let (controller, _, items) = try makeController()
        defer { controller.stop(); StateProtocol.handler = nil }
        items.values[0].fail(); await drainCallbacks()
        XCTAssertNotNil(controller.playbackError)
        StateProtocol.handler = { $0.respond(AppModelTests.postJSON) }
        await controller.changeQuality(controller.request.source)
        XCTAssertEqual(items.values.count, 2)
        XCTAssertNil(controller.playbackError)
    }

    func testCurrentRetryAndQualityAuthorizationFailuresReachSessionOwner() async throws {
        for quality in [false, true] {
            var authorizationFailures = 0
            let (controller, player, items) = try makeController(onAuthorizationFailure: { authorizationFailures += 1 })
            items.values[0].becomeReady(); await drainCallbacks()
            player.completions[0](true); await drainCallbacks()
            StateProtocol.handler = { $0.respond("{\"code\":\"reconnect\"}", status: 401) }
            if quality { await controller.changeQuality(controller.request.source) }
            else { await controller.retry() }
            XCTAssertEqual(authorizationFailures, 1)
            XCTAssertNil(player.currentItem)
            controller.stop()
        }
        StateProtocol.handler = nil
    }

    func testStoppedRetryAndQualityAuthorizationFailuresCannotResetSession() async throws {
        for quality in [false, true] {
            var authorizationFailures = 0
            let (controller, player, items) = try makeController(onAuthorizationFailure: { authorizationFailures += 1 })
            items.values[0].becomeReady(); await drainCallbacks()
            player.completions[0](true); await drainCallbacks()
            let started = expectation(description: "old player request started")
            var pending: StateProtocol?
            StateProtocol.handler = { pending = $0; started.fulfill() }
            let operation = Task {
                if quality { await controller.changeQuality(controller.request.source) }
                else { await controller.retry() }
            }
            await fulfillment(of: [started], timeout: 2)
            controller.stop()
            pending?.respond("{\"code\":\"reconnect\"}", status: 401)
            await operation.value
            XCTAssertEqual(authorizationFailures, 0)
        }
        StateProtocol.handler = nil
    }

    func testOrdinaryForbiddenQualityFailureDoesNotRequestPairing() async throws {
        var authorizationFailures = 0
        let (controller, player, items) = try makeController(onAuthorizationFailure: { authorizationFailures += 1 })
        defer { controller.stop(); StateProtocol.handler = nil }
        items.values[0].becomeReady(); await drainCallbacks()
        player.completions[0](true); await drainCallbacks()
        StateProtocol.handler = { $0.respond("{\"code\":\"forbidden\"}", status: 403) }
        await controller.changeQuality(controller.request.source)
        XCTAssertEqual(authorizationFailures, 0)
        XCTAssertNotNil(controller.playbackError)
    }

    func testReplacedRetryCannotReportOldAuthorizationFailure() async throws {
        var authorizationFailures = 0
        let (controller, _, _) = try makeController(onAuthorizationFailure: { authorizationFailures += 1 })
        defer { controller.stop(); StateProtocol.handler = nil }
        let started = expectation(description: "old retry started")
        var pending: StateProtocol?
        StateProtocol.handler = { stub in
            if pending == nil { pending = stub; started.fulfill() }
            else { stub.respond(AppModelTests.postJSON) }
        }
        let oldRetry = Task { await controller.retry() }
        await fulfillment(of: [started], timeout: 2)
        await controller.retry()
        pending?.respond("{\"code\":\"reconnect\"}", status: 401)
        await oldRetry.value
        XCTAssertEqual(authorizationFailures, 0)
        XCTAssertNil(controller.playbackError)
    }

    func testCancelledRetryDoesNotRequestPairing() async throws {
        var authorizationFailures = 0
        let (controller, _, _) = try makeController(onAuthorizationFailure: { authorizationFailures += 1 })
        defer { controller.stop(); StateProtocol.handler = nil }
        let started = expectation(description: "cancellable retry started")
        StateProtocol.handler = { _ in started.fulfill() }
        let operation = Task { await controller.retry() }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        await operation.value
        XCTAssertEqual(authorizationFailures, 0)
        XCTAssertNil(controller.playbackError)
    }

    func testSuspendDuringLoadingAndForegroundDoNotAutoplay() async throws {
        let (controller, player, items) = try makeController()
        controller.suspend()
        items.values[0].becomeReady()
        await drainCallbacks()
        XCTAssertTrue(player.completions.isEmpty)
        XCTAssertEqual(player.playCount, 0)
        controller.activate()
        items.values[1].becomeReady()
        await drainCallbacks()
        XCTAssertEqual(player.completions.count, 1)
        player.completions[0](true)
        await drainCallbacks()
        XCTAssertEqual(player.playCount, 0)
        controller.stop()
    }

    func testSuspendDuringInitialSeekRejectsOldCompletionAfterForeground() async throws {
        let (controller, player, items) = try makeController()
        items.values[0].becomeReady()
        await drainCallbacks()
        XCTAssertEqual(player.completions.count, 1)
        controller.suspend()
        controller.activate()
        player.completions[0](true)
        await drainCallbacks()
        XCTAssertEqual(player.playCount, 0)
        items.values[1].becomeReady()
        await drainCallbacks()
        XCTAssertEqual(player.completions.count, 2)
        player.completions[1](true)
        await drainCallbacks()
        XCTAssertEqual(player.playCount, 0)
        controller.stop()
    }

    func testRetryReplacementRejectsPreviousItemSeekCompletion() async throws {
        let (controller, player, items) = try makeController()
        StateProtocol.handler = { $0.respond(AppModelTests.postJSON) }
        defer { StateProtocol.handler = nil; controller.stop() }
        items.values[0].becomeReady()
        await drainCallbacks()
        await controller.retry()
        player.completions[0](true)
        await drainCallbacks()
        XCTAssertEqual(player.playCount, 0)
        items.values[1].becomeReady()
        await drainCallbacks()
        player.completions[1](true)
        await drainCallbacks()
        XCTAssertEqual(player.playCount, 1)
    }

    func testStoppedControllerCannotAutoplayOrOverwriteReplacementBackwardPosition() async throws {
        var positions: [Double] = []
        let progress = PlaybackProgress { _, seconds in positions.append(seconds) }
        let (old, oldPlayer, oldItems) = try makeController(progress: progress)
        oldItems.values[0].becomeReady()
        await drainCallbacks()
        oldPlayer.completions[0](true)
        await drainCallbacks()
        old.stop()
        // The final position is registered before any asynchronous task runs.
        XCTAssertEqual(progress.localPosition(videoID: "video"), 60)
        let (latest, newPlayer, newItems) = try makeController(progress: progress)
        newItems.values[0].becomeReady()
        await drainCallbacks()
        newPlayer.completions[0](true)
        await drainCallbacks()
        newPlayer.seconds = 12
        latest.stop()
        oldPlayer.seconds = 99
        old.stop()
        oldPlayer.completions[0](true)
        await drainCallbacks()
        await progress.flush()
        XCTAssertEqual(positions, [60, 12])
        XCTAssertEqual(oldPlayer.playCount, 1)
        XCTAssertEqual(newPlayer.playCount, 1)
    }
}
