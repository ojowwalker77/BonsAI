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

  func testClaudeAuthenticationFailureUsesStdoutAndGivesTheRecoveryAction() {
    let result = Shell.Result(
      stdout: "Failed to authenticate. API Error: 401 Invalid authentication credentials",
      stderr: "",
      status: 1)

    let message = UserFacingError.commandFailure(command: "Claude", result: result)

    XCTAssertTrue(message.contains("HTTP 401"))
    XCTAssertTrue(message.contains("Invalid authentication credentials"))
    XCTAssertTrue(message.contains("claude auth login"))
  }

  func testCommandFailureKeepsBothStreams() {
    let result = Shell.Result(stdout: "request rejected", stderr: "quota exhausted", status: 23)

    let message = UserFacingError.commandFailure(command: "Example CLI", result: result)

    XCTAssertTrue(message.contains("code 23"))
    XCTAssertTrue(message.contains("request rejected"))
    XCTAssertTrue(message.contains("quota exhausted"))
  }

  func testCommandFailureWithoutOutputSaysWhatIsMissing() {
    let result = Shell.Result(stdout: "", stderr: "", status: 7)

    XCTAssertEqual(
      UserFacingError.commandFailure(command: "Example CLI", result: result),
      "Example CLI exited with code 7 but returned no diagnostic.")
  }
}
