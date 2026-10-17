import XCTest
@testable import BoostyAppState

final class ReadingSectionsTests: XCTestCase {
    func testParagraphsAndWindowsLineEndingsKeepTheirOrder() {
        XCTAssertEqual(readingSections("First paragraph.\r\n\r\nSecond paragraph."),
                       ["First paragraph.", "Second paragraph."])
        XCTAssertEqual(readingSections(" \n\n\t"), [])
    }

    func testLongParagraphPreservesEveryWordInScreenSizedSections() {
        let words = (1...300).map { "word\($0)" }
        let sections = readingSections(words.joined(separator: " "))
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertTrue(sections.allSatisfy { !$0.isEmpty && $0.count <= 480 })
        XCTAssertEqual(sections.flatMap { $0.split(separator: " ").map(String.init) }, words)
    }

    func testUnbrokenUnicodeTextDoesNotLoseOrSplitCharacters() {
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 1000)
        let sections = readingSections(text)
        XCTAssertEqual(sections.map(\.count), [480, 480, 40])
        XCTAssertEqual(sections.joined(), text)
    }
}
