import XCTest
@testable import ComposerApp

final class ShellTests: XCTestCase {
  func testShellDrainsLargeStdoutAndStderrConcurrently() async throws {
    let byteCount = 262_144
    let command = "head -c \(byteCount) /dev/zero | tr '\\0' o; head -c \(byteCount) /dev/zero | tr '\\0' e >&2"

    let result = try await Shell.run(["sh", "-c", command])

    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.stdout.utf8.count, byteCount)
    XCTAssertEqual(result.stderr.utf8.count, byteCount)
  }
}
