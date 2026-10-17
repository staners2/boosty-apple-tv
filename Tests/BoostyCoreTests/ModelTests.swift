import XCTest
@testable import BoostyCore

final class ModelTests: XCTestCase {
    func testPostDecodesNullsUnknownBlocksAndPlayablePriority() throws {
        let json = """
        {"id":"post","title":"Title","blog":"blog","author":"Author","summary":"Summary","avatar":null,"preview":null,"createdAt":123,"publishedAt":124,"locked":true,"body":[{"type":"future","url":{"future":"shape"},"seconds":"unknown","text":[]},{"type":"text","text":"Text"},{"type":"image","url":"https://cdn.example/image","title":"Image"},{"type":"timecode","seconds":12,"videoId":"v","title":"Chapter","description":null}],"videos":[{"id":"v","title":"Video","contentId":null,"preview":null,"duration":100,"timeCode":120,"sources":[{"quality":"hls","label":"Auto","url":"https://cdn.example/a.m3u8"},{"quality":"dash","label":"DASH","url":"https://cdn.example/a.mpd"},{"quality":"mp4","label":"MP4","url":"https://cdn.example/a.mp4"},{"quality":"low","label":"Unsafe","url":"http://cdn.example/a.mp4"},{"quality":"tiny","label":"Relative","url":"/a.mp4"},{"quality":"high","label":"Malformed","url":"https://["}]}]}
        """
        let post = try JSONDecoder().decode(Post.self, from: Data(json.utf8))
        XCTAssertTrue(post.locked)
        XCTAssertEqual(post.body.first?.type, "future")
        XCTAssertEqual(post.body.last?.seconds, 12)
        XCTAssertEqual(post.videos.first?.playableSources.map(\.quality), ["hls", "mp4"])
        XCTAssertEqual(post.videos.first?.resumeSeconds, 100)
        XCTAssertNil(post.avatar)
    }

    func testUnknownDurationRetainsBoundedUpstreamResume() throws {
        for (position, expected) in [(42.0, 42.0), (900000, 604800)] {
            // The broker normalizes a missing upstream duration to zero.
            let data = Data("{\"id\":\"v\",\"title\":\"V\",\"duration\":0,\"timeCode\":\(position),\"sources\":[]}".utf8)
            let video = try JSONDecoder().decode(Video.self, from: data)
            XCTAssertEqual(video.resumeSeconds, expected)
        }
    }

    func testResumePositionHandlesMissingNegativeAndNonfiniteTimes() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for (duration, time, expected) in [("100", "null", 0.0), ("100", "-2", 0), ("100", "\"Infinity\"", 0), ("100", "\"NaN\"", 0), ("-1", "42", 0), ("\"Infinity\"", "42", 0)] {
            let json = "{\"id\":\"v\",\"title\":\"V\",\"duration\":" + duration + ",\"timeCode\":" + time + ",\"sources\":[]}"
            let video = try decoder.decode(Video.self, from: Data(json.utf8))
            XCTAssertEqual(video.resumeSeconds, expected)
        }
    }
}
