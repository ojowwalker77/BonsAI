import XCTest
@testable import ComposerApp

final class SmartPasteTests: XCTestCase {
  func testGitHubIssueURLBecomesChip() {
    let url = "https://github.com/acme/widget/issues/42"
    let token = SmartPaste.syncToken(for: url)
    XCTAssertEqual(token, AppToken.string(appID: "@github", selection: .github(kind: .issue, url: url)))
  }

  func testGitHubPullURLBecomesChip() {
    let url = "https://github.com/acme/widget/pull/7"
    let token = SmartPaste.syncToken(for: url)
    guard case let .github(kind, parsed)? = AppToken.parse(token ?? "")?.selection else {
      return XCTFail("expected github selection")
    }
    XCTAssertEqual(kind, .pr)
    XCTAssertEqual(parsed, url)
  }

  func testExistingFilePathBecomesFinderChip() throws {
    let dir = FileManager.default.temporaryDirectory
    let file = dir.appendingPathComponent("bonsai-smart-paste-\(UUID().uuidString).txt")
    try "hello".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    let token = SmartPaste.syncToken(for: file.path)
    guard case let .finder(ref)? = AppToken.parse(token ?? "")?.selection else {
      return XCTFail("expected finder selection")
    }
    XCTAssertEqual(ref.path, file.path)
  }

  func testLibraryQueryHeuristic() {
    XCTAssertTrue(SmartPaste.looksLikeLibraryQuery("next.js"))
    XCTAssertTrue(SmartPaste.looksLikeLibraryQuery("vercel/next.js"))
    XCTAssertFalse(SmartPaste.looksLikeLibraryQuery("hello world"))
    XCTAssertFalse(SmartPaste.looksLikeLibraryQuery("https://example.com"))
  }
}
