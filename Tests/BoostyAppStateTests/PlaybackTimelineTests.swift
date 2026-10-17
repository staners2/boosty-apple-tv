import BoostyCore
import AVFoundation
import XCTest
@testable import BoostyAppState

final class PlaybackTimelineTests: XCTestCase {
    func testSortedUniqueChaptersUseMeasuredDurationAndCurrentVideoOnly() throws {
        let body = #"[{"type":"timecode","videoId":"video","seconds":40,"description":"Second"},{"type":"timecode","videoId":"other","seconds":10},{"type":"timecode","videoId":"video","seconds":20,"description":"First"},{"type":"timecode","videoId":"video","seconds":20},{"type":"timecode","videoId":"video","seconds":100},{"type":"timecode","videoId":"video","seconds":-1}]"#
        let blocks = try JSONDecoder().decode([PostBodyBlock].self, from: Data(body.utf8))
        let timeline = PlaybackTimeline(body: blocks, videoID: "video", duration: 80)
        XCTAssertEqual(timeline.segments.map(\.start), [0, 20, 40])
        XCTAssertEqual(timeline.segments.map(\.end), [20, 40, 80])
        XCTAssertNil(timeline.chapter(at: 19))
        XCTAssertEqual(timeline.chapter(at: 20)?.description, "First")
        XCTAssertEqual(timeline.chapter(at: 70)?.description, "Second")
        XCTAssertEqual(timeline.segments.map { $0.fill(at: 30) }, [1, 0.5, 0])
    }

    func testUnknownDurationHasNoSegments() {
        XCTAssertTrue(PlaybackTimeline(body: [], videoID: "video", duration: 0).segments.isEmpty)
    }

    func testChapterNamesRemainAvailableBeforeDurationIsKnown() throws {
        let data = Data(#"[{"type":"timecode","videoId":"video","seconds":20,"title":"Arrival"}]"#.utf8)
        let blocks = try JSONDecoder().decode([PostBodyBlock].self, from: data)
        let timeline = PlaybackTimeline(body: blocks, videoID: "video", duration: 0)
        XCTAssertEqual(timeline.chapter(at: 25)?.title, "Arrival")
        XCTAssertTrue(timeline.segments.isEmpty)
    }

    func testNativeChapterMetadataContainsTitlesAndCorrectRanges() async throws {
        let data = Data(#"[{"type":"timecode","videoId":"video","seconds":20,"title":"Arrival","description":"Reach the station"},{"type":"timecode","videoId":"video","seconds":40,"description":"Return home"}]"#.utf8)
        let blocks = try JSONDecoder().decode([PostBodyBlock].self, from: data)
        let groups = PlaybackTimeline(body: blocks, videoID: "video", duration: 80).navigationMetadata
        var titles: [String] = []
        for group in groups {
            if let title = try await group.items.first?.load(.stringValue) { titles.append(title) }
        }
        XCTAssertEqual(titles, ["Arrival", "Return home"])
        XCTAssertEqual(groups.map { $0.timeRange.start.seconds }, [20, 40])
        XCTAssertEqual(groups.map { $0.timeRange.duration.seconds }, [20, 40])
        XCTAssertTrue(PlaybackTimeline(body: blocks, videoID: "other", duration: 80).navigationMetadata.isEmpty)
        XCTAssertTrue(PlaybackTimeline(body: blocks, videoID: "video", duration: 0).navigationMetadata.isEmpty)
    }
}
