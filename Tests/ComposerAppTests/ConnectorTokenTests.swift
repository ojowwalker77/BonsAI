import XCTest
@testable import ComposerApp

/// Pure round-trip tests for the `@token` codec — the serialization that is the source of truth for
/// connector chips. No network and no secret-store I/O, so these are deterministic and side-effect free.
final class ConnectorTokenTests: XCTestCase {
  func testLinearTokenRoundTrips() {
    let selection = AppSelection.linear(LinearReference(id: "9b1deb4d-uuid", identifier: "ENG-482"))
    let token = AppToken.string(appID: "@linear", selection: selection)
    XCTAssertEqual(token, "@linear:9b1deb4d-uuid?k=ENG-482")

    let parsed = AppToken.parse(token)
    XCTAssertEqual(parsed?.appID, "@linear")
    guard case let .linear(ref)? = parsed?.selection else { return XCTFail("expected .linear") }
    XCTAssertEqual(ref.id, "9b1deb4d-uuid")
    XCTAssertEqual(ref.identifier, "ENG-482")
    XCTAssertEqual(AppToken.label(appID: "@linear", selection: selection), "ENG-482")
  }

  func testNotionTokenRoundTrips() {
    let selection = AppSelection.notion(NotionReference(id: "page-uuid", title: "My Spec"))
    let token = AppToken.string(appID: "@notion", selection: selection)
    XCTAssertEqual(token, "@notion:page-uuid?t=My%20Spec")
    guard case let .notion(ref)? = AppToken.parse(token)?.selection else { return XCTFail("expected .notion") }
    XCTAssertEqual(ref.id, "page-uuid")
    XCTAssertEqual(ref.title, "My Spec")
    XCTAssertEqual(AppToken.label(appID: "@notion", selection: selection), "My Spec")
  }

  func testICloudTokenRoundTrips() {
    let path = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Specs/Q3 Plan.pdf"
    let selection = AppSelection.icloud(FinderReference(path: path, isDirectory: false))
    let token = AppToken.string(appID: "@icloud", selection: selection)
    XCTAssertEqual(token, "@icloud:/Users/me/Library/Mobile%20Documents/com~apple~CloudDocs/Specs/Q3%20Plan.pdf")
    guard case let .icloud(ref)? = AppToken.parse(token)?.selection else { return XCTFail("expected .icloud") }
    XCTAssertEqual(ref.path, path)
    XCTAssertEqual(AppToken.label(appID: "@icloud", selection: selection), "Q3 Plan.pdf")
  }

  func testNotesTokenRoundTrips() {
    let selection = AppSelection.notes(NotesReference(id: "x-coredata://ABC-123/ICNote/p42", title: "Trip Ideas"))
    let token = AppToken.string(appID: "@notes", selection: selection)
    XCTAssertEqual(token, "@notes:x-coredata://ABC-123/ICNote/p42?t=Trip%20Ideas")
    let parsed = AppToken.parse(token)
    XCTAssertEqual(parsed?.appID, "@notes")
    guard case let .notes(ref)? = parsed?.selection else { return XCTFail("expected .notes") }
    XCTAssertEqual(ref.id, "x-coredata://ABC-123/ICNote/p42")
    XCTAssertEqual(ref.title, "Trip Ideas")
    XCTAssertEqual(AppToken.label(appID: "@notes", selection: selection), "Trip Ideas")
  }

  /// The note id (a `x-coredata://…` URL) survives a scan out of surrounding prose intact.
  func testNotesTokenScansFromText() {
    let plain = "Summarize @notes:x-coredata://S-1/ICNote/p7?t=Q3%20Plan before the call."
    let scanned = AppToken.scan(plain)
    guard let entry = scanned.first(where: { $0.appID == "@notes" }),
          case let .notes(ref)? = entry.selection else { return XCTFail("expected a scanned .notes token") }
    XCTAssertEqual(ref.id, "x-coredata://S-1/ICNote/p7")
    XCTAssertEqual(ref.title, "Q3 Plan")
  }

  func testNotesHTMLBodyFlattensToText() {
    let html = "<div>First line</div><div><br></div><ul><li>a &amp; b</li><li>c &lt; d</li></ul>"
    let text = NotesService.htmlToPlainText(html)
    XCTAssertEqual(text, "First line\n\n- a & b\n- c < d")
  }

  func testSentryTokenRoundTrips() {
    let selection = AppSelection.sentry(SentryReference(org: "my-org", id: "42", shortID: "WEB-1AB"))
    let token = AppToken.string(appID: "@sentry", selection: selection)
    XCTAssertEqual(token, "@sentry:my-org/42?s=WEB-1AB")
    guard case let .sentry(ref)? = AppToken.parse(token)?.selection else { return XCTFail("expected .sentry") }
    XCTAssertEqual(ref.org, "my-org")
    XCTAssertEqual(ref.id, "42")
    XCTAssertEqual(ref.shortID, "WEB-1AB")
    XCTAssertEqual(AppToken.label(appID: "@sentry", selection: selection), "WEB-1AB")
  }

  func testFigmaTokenRoundTrips() {
    let reference = FigmaReference(fileKey: "abc123", nodeId: "1:2", name: "Login Screen")
    let token = AppToken.string(appID: "@figma", selection: .figma(reference))
    XCTAssertTrue(token.hasPrefix("@figma:"))
    guard case let .figma(parsed)? = AppToken.parse(token)?.selection else { return XCTFail("expected .figma") }
    XCTAssertEqual(parsed, reference)
    XCTAssertEqual(AppToken.label(appID: "@figma", selection: .figma(reference)), "Login Screen")
  }

  func testFigmaURLParsing() {
    let reference = FigmaService.parseURL("https://www.figma.com/design/abc123/My-App?node-id=12-345")
    XCTAssertEqual(reference?.fileKey, "abc123")
    XCTAssertEqual(reference?.nodeId, "12:345")   // URL hyphen → API colon
    XCTAssertEqual(reference?.name, "My App")
    XCTAssertNil(FigmaService.parseURL("https://example.com/not-figma"))
  }

  func testXcodeTokenEncodesPath() {
    let reference = XcodeReference(resultPath: "/tmp/My Result.xcresult")
    let token = AppToken.string(appID: "@xcode", selection: .xcode(reference))
    XCTAssertEqual(token, "@xcode:/tmp/My%20Result.xcresult")
    guard case let .xcode(parsed)? = AppToken.parse(token)?.selection else { return XCTFail("expected .xcode") }
    XCTAssertEqual(parsed.resultPath, "/tmp/My Result.xcresult")
    XCTAssertEqual(AppToken.label(appID: "@xcode", selection: .xcode(reference)), "My Result")
  }

  func testScanFindsMultipleConnectors() {
    let plain = "Do @linear:uuid-1?k=ENG-1 alongside @notion:page-1?t=Spec"
    let ids = AppToken.scan(plain).map(\.appID)
    XCTAssertTrue(ids.contains("@linear"))
    XCTAssertTrue(ids.contains("@notion"))
  }

  func testParseRejectsUnknownApp() {
    XCTAssertNil(AppToken.parse("@nope:whatever"))
  }

  /// Every connector that declares an API-token requirement should also deep-link where to mint one.
  func testApiTokenConnectorsProvideCreateURL() {
    for app in MentionCatalog.apps {
      guard let connector = AppConnectorRegistry.connector(for: app.id) else { continue }
      if case let .apiToken(_, _, createURL) = connector.auth {
        XCTAssertNotNil(createURL, "\(app.id) apiToken should provide a createURL")
      }
    }
  }
}
