import XCTest
@testable import ComposerApp

final class CanvasServerSecurityTests: XCTestCase {
  private let secret = String(repeating: "ab", count: 32)

  func testCapabilityIsRandom256Bits() throws {
    let first = try CanvasSessionDescriptor.generate(apiVersion: "2", port: 7337)
    let second = try CanvasSessionDescriptor.generate(apiVersion: "2", port: 7337)

    XCTAssertEqual(first.capability.count, 64)
    XCTAssertNotNil(first.capability.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
    XCTAssertNotEqual(first.capability, second.capability)
    XCTAssertFalse(first.baseURL.contains(first.capability))
  }

  func testDescriptorIsPrivateAndAtomicallyReplaced() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("CanvasSessionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let destination = parent.appendingPathComponent("nested/session.json")
    let first = session(capability: secret)
    let second = session(capability: String(repeating: "cd", count: 32))

    try CanvasSessionDescriptorStore.publish(first, at: destination)
    XCTAssertEqual(try CanvasSessionDescriptorStore.load(from: destination), first)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: parent.appendingPathComponent("nested").path)[.posixPermissions] as? Int,
      0o700
    )
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int,
      0o600
    )

    try CanvasSessionDescriptorStore.publish(second, at: destination)
    XCTAssertEqual(try CanvasSessionDescriptorStore.load(from: destination), second)
    XCTAssertFalse(try String(contentsOf: destination, encoding: .utf8).contains(secret))

    try CanvasSessionDescriptorStore.invalidate(at: destination)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testForeignAndNullOriginsAreRejectedBeforeAuthorization() throws {
    let authorizer = CanvasRequestAuthorizer(session: session())
    for origin in ["https://attacker.example", "null"] {
      let request = try parse(
        "GET /canvas HTTP/1.1\r\nHost: 127.0.0.1:7337\r\nOrigin: \(origin)\r\nAuthorization: Bearer \(secret)\r\n\r\n"
      )
      XCTAssertEqual(authorizer.rejection(for: request)?.status, "403 Forbidden")
    }
  }

  func testForeignOriginSimplePostIsRejectedWithoutParsingBody() throws {
    let body = "this is deliberately not JSON"
    let request = try parse(
      "POST /canvas HTTP/1.1\r\nHost: 127.0.0.1:7337\r\nOrigin: https://attacker.example\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    )

    XCTAssertEqual(
      CanvasRequestAuthorizer(session: session()).rejection(for: request)?.status,
      "403 Forbidden"
    )
  }

  func testWrongHostAndDuplicateSensitiveHeadersAreRejected() throws {
    let authorizer = CanvasRequestAuthorizer(session: session())
    let wrongHost = try parse(
      "GET /health HTTP/1.1\r\nHost: attacker.example\r\n\r\n"
    )
    XCTAssertEqual(authorizer.rejection(for: wrongHost)?.status, "403 Forbidden")

    let duplicateAuthorization = try parse(
      "GET /canvas HTTP/1.1\r\nHost: 127.0.0.1:7337\r\nAuthorization: Bearer wrong\r\nAuthorization: Bearer \(secret)\r\n\r\n"
    )
    XCTAssertEqual(authorizer.rejection(for: duplicateAuthorization)?.status, "400 Bad Request")
  }

  func testHealthNeedsTrustedHostAndOriginButNoCapability() throws {
    let authorizer = CanvasRequestAuthorizer(session: session())
    let noOrigin = try parse("GET /health HTTP/1.1\r\nHost: 127.0.0.1:7337\r\n\r\n")
    let trustedOrigin = try parse(
      "GET /health HTTP/1.1\r\nHost: 127.0.0.1:7337\r\nOrigin: http://127.0.0.1:7337\r\n\r\n"
    )

    XCTAssertNil(authorizer.rejection(for: noOrigin))
    XCTAssertNil(authorizer.rejection(for: trustedOrigin))
  }

  func testEveryProtectedRouteRejectsMissingAndWrongCapabilities() throws {
    let authorizer = CanvasRequestAuthorizer(session: session())
    let routes = [
      ("GET", "/canvas"),
      ("POST", "/canvas"),
      ("POST", "/capture"),
      ("POST", "/mcp"),
      ("POST", "/permission"),
      ("GET", "/mcp"),
      ("GET", "/permission"),
    ]

    for (method, path) in routes {
      let missing = try parse("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:7337\r\n\r\n")
      XCTAssertEqual(authorizer.rejection(for: missing)?.status, "401 Unauthorized", "\(method) \(path)")

      let wrong = try parse(
        "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:7337\r\nAuthorization: Bearer wrong\r\n\r\n"
      )
      XCTAssertEqual(authorizer.rejection(for: wrong)?.status, "401 Unauthorized", "\(method) \(path)")
    }
  }

  func testEveryProtectedRouteAllowsTrustedCLIAndLoopbackOrigin() throws {
    let authorizer = CanvasRequestAuthorizer(session: session())
    let routes = [
      ("GET", "/canvas"),
      ("POST", "/canvas"),
      ("POST", "/capture"),
      ("POST", "/mcp"),
      ("POST", "/permission"),
      ("GET", "/mcp"),
      ("GET", "/permission"),
    ]

    for origin in [nil, "http://127.0.0.1:7337"] {
      for (method, path) in routes {
        let originHeader = origin.map { "Origin: \($0)\r\n" } ?? ""
        let request = try parse(
          "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:7337\r\n\(originHeader)Authorization: Bearer \(secret)\r\n\r\n"
        )
        XCTAssertNil(authorizer.rejection(for: request), "\(method) \(path), origin: \(origin ?? "none")")
      }
    }
  }

  func testFailuresAndStartupLogNeverRevealCapability() throws {
    let authorizer = CanvasRequestAuthorizer(session: session())
    let request = try parse("GET /canvas HTTP/1.1\r\nHost: 127.0.0.1:7337\r\n\r\n")
    let rejection = try XCTUnwrap(authorizer.rejection(for: request))

    XCTAssertFalse(rejection.message.contains(secret))
    XCTAssertFalse(CanvasServer.startupLogMessage.contains(secret))
    XCTAssertFalse(CanvasServer.startupLogMessage.contains("Authorization"))

    let health = try JSONSerialization.data(withJSONObject: CanvasServer.healthResponse)
    let response = CanvasServer.httpResponse(status: "200 OK", data: health)
    let responseText = try XCTUnwrap(String(data: response, encoding: .utf8))
    XCTAssertFalse(responseText.contains(secret))
    XCTAssertFalse(responseText.lowercased().contains("capability"))
    XCTAssertFalse(responseText.contains("Access-Control-Allow-Origin"))
    XCTAssertTrue(responseText.contains("Cache-Control: no-store"))
  }

  private func session(capability: String? = nil) -> CanvasSessionDescriptor {
    CanvasSessionDescriptor(
      apiVersion: "2",
      baseURL: "http://127.0.0.1:7337",
      capability: capability ?? secret
    )
  }

  private func parse(_ raw: String) throws -> HTTPRequest {
    try XCTUnwrap(HTTPRequest(Data(raw.utf8)))
  }
}
