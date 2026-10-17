import XCTest

extension XCTestCase {
    @MainActor
    func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline {
            guard !Task.isCancelled else {
                XCTFail("State transition wait cancelled", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "State transition timed out", file: file, line: line)
    }
}
