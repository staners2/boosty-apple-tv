import Foundation

public struct BrokerEndpoint: Hashable, Sendable {
    public let url: URL

    public init(_ input: String) throws {
        guard !input.isEmpty,
              !input.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !input.contains("\\"),
              var components = URLComponents(string: input),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true
        else { throw BrokerError.invalidInput }
        var path = components.percentEncodedPath
        // Decode repeatedly so nested encodings cannot conceal traversal or separators.
        for _ in 0...path.count {
            guard let decoded = path.removingPercentEncoding,
                  !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
                  decoded.components(separatedBy: "/").count == path.components(separatedBy: "/").count
            else { throw BrokerError.invalidInput }
            if decoded == path { break }
            path = decoded
        }
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        components.scheme = "https"
        components.host = host.lowercased()
        guard let url = components.url, url.host != nil else { throw BrokerError.invalidInput }
        self.url = url
    }

    public func requestURL(path: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BrokerError.invalidInput }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for part in path {
            guard let encoded = part.addingPercentEncoding(withAllowedCharacters: allowed) else { throw BrokerError.invalidInput }
            components.percentEncodedPath += "/" + encoded
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let result = components.url else { throw BrokerError.invalidInput }
        return result
    }

    func contains(_ candidate: URL) -> Bool {
        guard candidate.scheme?.lowercased() == "https", candidate.host?.lowercased() == url.host?.lowercased(),
              (candidate.port ?? 443) == (url.port ?? 443), candidate.user == nil, candidate.password == nil,
              let parsed = try? BrokerEndpoint(candidate.absoluteString.components(separatedBy: "?")[0]),
              parsed.url.path == candidate.path
        else { return false }
        return url.path.isEmpty || candidate.path == url.path || candidate.path.hasPrefix(url.path + "/")
    }
}
