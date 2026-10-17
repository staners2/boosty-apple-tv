import BoostyCore
import XCTest
@testable import BoostyAppState

@MainActor
final class PlaybackProgressTests: XCTestCase {
    func testDelayedOldControllerWritesFinishBeforeNewBackwardPosition() async {
        let started = expectation(description: "first write started")
        var release: CheckedContinuation<Void, Never>?
        var arrivals: [Double] = []
        let progress = PlaybackProgress { _, seconds in
            if seconds == 40 {
                await withCheckedContinuation { release = $0; started.fulfill() }
            }
            arrivals.append(seconds)
        }
        progress.enqueue(videoID: "video", seconds: 40)
        await fulfillment(of: [started], timeout: 2)
        // Final old-controller sample is registered synchronously before its dismissal.
        progress.enqueue(videoID: "video", seconds: 80)
        // A replacement controller intentionally seeks backward.
        progress.enqueue(videoID: "video", seconds: 12)
        let flushed = expectation(description: "all registered samples flushed")
        let flush = Task { await progress.flush(); flushed.fulfill() }
        await Task.yield()
        XCTAssertTrue(arrivals.isEmpty)
        release!.resume()
        await fulfillment(of: [flushed], timeout: 2)
        await flush.value
        XCTAssertEqual(arrivals, [40, 80, 12])
        XCTAssertNil(progress.localPosition(videoID: "video"))
        XCTAssertNil(progress.warning)
    }

    func testFailedFlushRetainsLatestLocalPositionUntilSuccessfulRetry() async {
        var fails = true
        let progress = PlaybackProgress { _, _ in
            if fails { throw URLError(.notConnectedToInternet) }
        }
        progress.enqueue(videoID: "video", seconds: 70)
        progress.enqueue(videoID: "video", seconds: 11)
        await progress.flush()
        XCTAssertEqual(progress.localPosition(videoID: "video"), 11)
        XCTAssertNotNil(progress.warning)
        fails = false
        progress.enqueue(videoID: "video", seconds: 11)
        await progress.flush()
        XCTAssertNil(progress.localPosition(videoID: "video"))
        XCTAssertNil(progress.warning)
    }

    func testFlushTimeoutReturnsWithWarningAndRetainsPendingLocalPosition() async {
        let started = expectation(description: "write started")
        var release: CheckedContinuation<Void, Never>?
        let progress = PlaybackProgress { _, _ in
            await withCheckedContinuation { release = $0; started.fulfill() }
        }
        progress.enqueue(videoID: "video", seconds: 55)
        await fulfillment(of: [started], timeout: 2)
        await progress.flush(timeout: .milliseconds(10))
        XCTAssertEqual(progress.localPosition(videoID: "video"), 55)
        XCTAssertNotNil(progress.warning)
        release!.resume()
        await progress.flush()
        XCTAssertNil(progress.warning)
        XCTAssertNil(progress.localPosition(videoID: "video"))
    }

    func testInvalidatedSessionRejectsQueuedAndFutureWrites() async {
        let started = expectation(description: "write started")
        var release: CheckedContinuation<Void, Never>?
        var writes: [Double] = []
        let progress = PlaybackProgress { _, seconds in
            if seconds == 10 { await withCheckedContinuation { release = $0; started.fulfill() } }
            writes.append(seconds)
        }
        progress.enqueue(videoID: "video", seconds: 10)
        await fulfillment(of: [started], timeout: 2)
        progress.enqueue(videoID: "video", seconds: 20)
        progress.invalidate()
        progress.enqueue(videoID: "video", seconds: 30)
        release!.resume()
        await progress.flush()
        XCTAssertEqual(writes, [10])
        XCTAssertNil(progress.localPosition(videoID: "video"))
    }
}
