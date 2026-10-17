import BoostyCore
import XCTest
@testable import BoostyAppState

@MainActor
final class FramePreviewTests: XCTestCase {
    private func post() throws -> Post {
        try JSONDecoder().decode(Post.self, from: Data(AppModelTests.postJSON.replacingOccurrences(of: "\"duration\":100", with: "\"contentId\":\"content\",\"duration\":100").utf8))
    }
    private func frame(_ seconds: Double) throws -> VideoPreview {
        try JSONDecoder().decode(VideoPreview.self, from: Data("{\"seconds\":\(seconds),\"image\":\"data:image/jpeg;base64,/9j/2Q==\"}".utf8))
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(320)) }

    func testDebounceUsesContentIdentityAndCancelRejectsLateFrame() async throws {
        let post = try post()
        var calls: [(String, Double)] = []
        var pending: CheckedContinuation<VideoPreview, Error>?
        let previews = FramePreview(request: { _, _, id, seconds in
            calls.append((id, seconds))
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        previews.select(post: post, video: post.videos[0], seconds: 10)
        previews.select(post: post, video: post.videos[0], seconds: 20)
        XCTAssertTrue(calls.isEmpty)
        try await settle()
        XCTAssertEqual(calls.map(\.0), ["content"])
        XCTAssertEqual(calls.map(\.1), [20])
        previews.cancel(); pending?.resume(returning: try frame(20))
        await Task.yield()
        XCTAssertNil(previews.frame)
        XCTAssertNil(previews.selectedSeconds)
        previews.invalidate()
    }

    func testNearestFrameShowsActualTimeAndExactResponseReplacesIt() async throws {
        let post = try post()
        var pending: CheckedContinuation<VideoPreview, Error>?
        let previews = FramePreview(request: { _, _, _, seconds in
            if seconds == 15 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return try self.frame(seconds)
        })
        previews.select(post: post, video: post.videos[0], seconds: 10)
        try await settle()
        previews.select(post: post, video: post.videos[0], seconds: 15)
        XCTAssertEqual(previews.selectedSeconds, 15)
        XCTAssertEqual(previews.frame?.seconds, 10)
        XCTAssertTrue(previews.loading)
        try await settle(); pending?.resume(returning: try frame(15))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(previews.frame?.seconds, 15)
        XCTAssertFalse(previews.loading)
        previews.invalidate()
    }

    func testMismatchedFrameIsRejectedAndAccessLossClearsCache() async throws {
        let post = try post()
        var denied = false
        let previews = FramePreview(request: { _, _, _, seconds in
            if denied { throw BrokerError(status: 403, code: "forbidden") }
            return try self.frame(seconds == 15 ? 99 : seconds)
        })
        previews.select(post: post, video: post.videos[0], seconds: 15)
        try await settle()
        XCTAssertNil(previews.frame)
        XCTAssertNotNil(previews.error)
        previews.select(post: post, video: post.videos[0], seconds: 10)
        try await settle()
        denied = true
        previews.select(post: post, video: post.videos[0], seconds: 50)
        try await settle()
        previews.select(post: post, video: post.videos[0], seconds: 10)
        XCTAssertNil(previews.frame)
        previews.invalidate()
    }

    func testCacheExpiresWithoutExtendingOnReuseAndSurvivesCancel() async throws {
        let post = try post()
        var now = Date(timeIntervalSince1970: 0)
        let previews = FramePreview(request: { _, _, _, seconds in try self.frame(seconds) }, now: { now })
        previews.select(post: post, video: post.videos[0], seconds: 10)
        try await settle(); previews.cancel()
        now = Date(timeIntervalSince1970: 290)
        previews.select(post: post, video: post.videos[0], seconds: 10)
        XCTAssertEqual(previews.frame?.seconds, 10)
        previews.cancel(); now = Date(timeIntervalSince1970: 301)
        previews.select(post: post, video: post.videos[0], seconds: 10)
        XCTAssertNil(previews.frame)
        XCTAssertTrue(previews.loading)
        previews.invalidate()
    }

    func testPrefetchPromotesMatchingRequestWithoutDuplicateOrForegroundReplacement() async throws {
        let post = try post()
        var calls: [Double] = []
        var pending: CheckedContinuation<VideoPreview, Error>?
        let previews = FramePreview(request: { _, _, _, seconds in
            calls.append(seconds)
            if seconds == 20 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return try self.frame(seconds)
        })
        previews.select(post: post, video: post.videos[0], seconds: 10)
        try await Task.sleep(for: .milliseconds(430))
        XCTAssertEqual(calls, [10, 20])
        XCTAssertEqual(previews.frame?.seconds, 10)
        previews.select(post: post, video: post.videos[0], seconds: 20)
        await Task.yield()
        pending?.resume(returning: try frame(20))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, [10, 20])
        XCTAssertEqual(previews.frame?.seconds, 20)
        previews.invalidate()
    }

    func testCacheNeverLeaksBetweenVideosOrPostsAndInvalidateCannotRestart() async throws {
        let first = try post()
        let other = try JSONDecoder().decode(Post.self, from: Data(AppModelTests.postJSON
            .replacingOccurrences(of: "\"duration\":100", with: "\"contentId\":\"other-content\",\"duration\":100").utf8))
        var calls = 0
        let previews = FramePreview(request: { _, _, _, seconds in calls += 1; return try self.frame(seconds) })
        previews.select(post: first, video: first.videos[0], seconds: 10)
        try await settle()
        previews.select(post: other, video: other.videos[0], seconds: 12)
        XCTAssertNil(previews.frame)
        previews.cancel()
        previews.select(post: first, video: first.videos[0], seconds: 10)
        XCTAssertEqual(previews.frame?.seconds, 10)
        previews.invalidate()
        let previousCalls = calls
        previews.select(post: first, video: first.videos[0], seconds: 10)
        try await settle()
        XCTAssertEqual(calls, previousCalls)
        XCTAssertNil(previews.frame)
    }

    func testCacheEvictsByCountAndEncodedImageMemory() async throws {
        let post = try post()
        for large in [false, true] {
            var selectedSeconds: Double = 0
            let previews = FramePreview(request: { _, _, _, seconds in
                // Fill with foreground frames only; prefetch scheduling must not determine whether the limit is reached.
                guard seconds == selectedSeconds else { throw BrokerError(status: 404, code: "preview_unavailable") }
                let image = large ? "data:image/jpeg;base64," + Data([0xff, 0xd8] + Array(repeating: 0, count: 65000) + [0xff, 0xd9]).base64EncodedString()
                                  : "data:image/jpeg;base64,/9j/2Q=="
                let data = try JSONSerialization.data(withJSONObject: ["seconds": seconds, "image": image])
                return try JSONDecoder().decode(VideoPreview.self, from: data)
            })
            for index in 0..<(large ? 25 : 33) {
                selectedSeconds = Double(index * 50 + 20)
                previews.select(post: post, video: post.videos[0], seconds: selectedSeconds, duration: 10_000)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while previews.loading && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertFalse(previews.loading)
                XCTAssertEqual(previews.frame?.seconds, selectedSeconds)
                previews.cancel()
            }
            previews.select(post: post, video: post.videos[0], seconds: 20, duration: 1000)
            XCTAssertTrue(previews.loading, "Old frame must be evicted by \(large ? "bytes" : "count")")
            XCTAssertNotEqual(previews.frame?.seconds, 20)
            previews.invalidate()
        }
    }

    func testChapterPrefetchPrioritizesSameVideoBoundariesAndMissingIdentityIsNonfatal() async throws {
        let json = AppModelTests.postJSON.replacingOccurrences(of: "\"body\":[]", with: #""body":[{"type":"timecode","videoId":"video","seconds":40},{"type":"timecode","videoId":"video","seconds":60},{"type":"timecode","videoId":"other","seconds":51}]"#)
            .replacingOccurrences(of: "\"duration\":100", with: "\"contentId\":\"content\",\"duration\":100")
        let post = try JSONDecoder().decode(Post.self, from: Data(json.utf8))
        var calls: [Double] = []
        let previews = FramePreview(request: { _, _, _, seconds in calls.append(seconds); return try self.frame(seconds) })
        previews.select(post: post, video: post.videos[0], seconds: 45, preferChapters: true)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(calls, [45, 40, 60, 55, 35])
        let missing = try JSONDecoder().decode(Post.self, from: Data(AppModelTests.postJSON.utf8))
        previews.select(post: missing, video: missing.videos[0], seconds: 10)
        XCTAssertNotNil(previews.error)
        XCTAssertFalse(previews.loading)
        previews.invalidate()
    }

    func testFractionalChapterTimestampIsRequestedExactly() async throws {
        let post = try post()
        var seconds: Double?
        let previews = FramePreview(request: { _, _, _, selected in
            seconds = selected; return try self.frame(selected)
        })
        previews.select(post: post, video: post.videos[0], seconds: 10.5, preferChapters: true)
        try await settle()
        XCTAssertEqual(seconds, 10.5)
        XCTAssertEqual(previews.frame?.seconds, 10.5)
        previews.invalidate()
    }
}
