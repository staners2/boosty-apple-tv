import Foundation

public struct SessionCredentials: Codable, Equatable, Sendable {
    public let cookieValue: String
    public let tvProof: String

    public init(cookieValue: String, tvProof: String) {
        self.cookieValue = cookieValue
        self.tvProof = tvProof
    }

    var isValid: Bool { Self.validSecret(cookieValue) && Self.validSecret(tvProof) }
    private static func validSecret(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
}

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let avatar: URL?
}

public struct PairCreated: Decodable, Sendable {
    public let id: String
    public let pollKey: String
    public let linkUrl: URL
    public let qrImage: String
    public let expiresAt: Double
}

public struct PairStatus: Decodable, Sendable {
    public enum State: String, Decodable, Sendable { case waiting, confirm }
    public let state: State
    public let name: String
    public let expiresAt: Double
    public let profile: Profile?
}

public struct Subscription: Decodable, Hashable, Sendable, Identifiable {
    public let blog: String
    public let title: String
    public let name: String
    public let avatar: URL?
    public var id: String { blog }
}

public struct SubscriptionPage: Decodable, Sendable {
    public let items: [Subscription]
    public let nextOffset: Int?
}

public struct PostPage: Decodable, Sendable {
    public let items: [Post]
    public let nextOffset: String?
}

public struct Post: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let blog: String
    public let author: String
    public let summary: String
    public let avatar: URL?
    public let preview: URL?
    public let createdAt: Double
    public let publishedAt: Double
    public let locked: Bool
    public let body: [PostBodyBlock]
    public let videos: [Video]
}

public struct PostBodyBlock: Decodable, Hashable, Sendable {
    public let type: String
    public let text: String?
    public let url: URL?
    public let title: String?
    public let seconds: Double?
    public let videoId: String?
    public let description: String?

    private enum CodingKeys: String, CodingKey { case type, text, url, title, seconds, videoId, description }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        guard ["text", "image", "link", "file", "timecode"].contains(type) else {
            text = nil; url = nil; title = nil; seconds = nil; videoId = nil; description = nil
            return
        }
        text = try values.decodeIfPresent(String.self, forKey: .text)
        url = try values.decodeIfPresent(URL.self, forKey: .url)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds)
        videoId = try values.decodeIfPresent(String.self, forKey: .videoId)
        description = try values.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct Video: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let contentId: String?
    public let preview: URL?
    public let duration: Double
    public let timeCode: Double?
    public let sources: [VideoSource]

    public var playableSources: [VideoSource] {
        sources.filter { source in
            source.quality.lowercased() != "dash" && source.quality.lowercased() != "ondemand_dash"
                && source.url.pathExtension.lowercased() != "mpd"
                && source.url.scheme?.lowercased() == "https" && source.url.host?.isEmpty == false
                && source.url.user == nil && source.url.password == nil
        }
    }

    public var resumeSeconds: Double {
        guard duration.isFinite, duration >= 0, let timeCode, timeCode.isFinite else { return 0 }
        let position = min(max(0, timeCode), 604800)
        return duration > 0 ? min(position, duration) : position
    }

    private enum CodingKeys: String, CodingKey { case id, title, contentId, preview, duration, timeCode, sources }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        contentId = try values.decodeIfPresent(String.self, forKey: .contentId)
        preview = try values.decodeIfPresent(URL.self, forKey: .preview)
        duration = try values.decode(Double.self, forKey: .duration)
        timeCode = try values.decodeIfPresent(Double.self, forKey: .timeCode)
        var entries = try values.nestedUnkeyedContainer(forKey: .sources)
        var sources: [VideoSource] = []
        while !entries.isAtEnd {
            // Consume each entry even if its URL is malformed; one bad source must not hide a valid fallback.
            let entry = try entries.superDecoder()
            if let source = try? VideoSource(from: entry) { sources.append(source) }
        }
        self.sources = sources
    }
}

public struct VideoSource: Decodable, Hashable, Sendable, Identifiable {
    public let quality: String
    public let label: String
    public let url: URL
    public var id: String { quality }
}

public struct VideoPreview: Decodable, Sendable {
    public let image: String
    public let seconds: Double
}
