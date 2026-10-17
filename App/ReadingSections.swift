import Foundation

func readingSections(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n\n").flatMap { paragraph -> [String] in
            var remaining = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)[...]
            var sections: [String] = []
            while !remaining.isEmpty {
                let limit = remaining.index(remaining.startIndex, offsetBy: 480, limitedBy: remaining.endIndex) ?? remaining.endIndex
                let end = limit == remaining.endIndex ? limit
                    : remaining[..<limit].lastIndex(where: \.isWhitespace) ?? limit
                sections.append(String(remaining[..<end]))
                remaining = remaining[end...].drop(while: \.isWhitespace)
            }
            return sections
        }
}
