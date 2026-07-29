import Foundation
import Network

/// A tiny loopback-only HTTP server that exposes the canvas graph so a CLI / MCP server — and
/// thus an external agent — can read and manipulate the board live. Deliberately dependency-free
/// (Network.framework) and bound to 127.0.0.1 so it never leaves the machine.
///
/// Endpoints:
///   GET  /health   → liveness + API version
///   GET  /canvas   → the full `CanvasGraph`
///   POST /canvas   → one `{ "op": …, … }` mutation, returns `{ "ok": …, … }`
///   POST /capture  → `{ "text": "…" }` append a card to the open board
///   POST /mcp      → JSON-RPC for MCP tools
final class CanvasServer {
  static let shared = CanvasServer()
  static let port: UInt16 = 7337
  static let apiVersion = "2"
  /// The server is loopback-only, but an agent/tool bug should still not be able to grow an
  /// in-memory request buffer without bound. Canvas mutations are deliberately tiny JSON.
  private static let maximumRequestBytes = 1 * 1_024 * 1_024
  /// A partial HTTP request should not retain a loopback connection forever.
  private static let requestDeadline: TimeInterval = 15

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "dev.jow.Composer.canvas-server")
  private let sessionResult: Result<CanvasSessionDescriptor, Error>
  private let sessionDescriptorURL: URL

  init(
    session: CanvasSessionDescriptor? = nil,
    sessionDescriptorURL: URL = CanvasSessionDescriptorStore.defaultURL
  ) {
    self.sessionDescriptorURL = sessionDescriptorURL
    if let session {
      sessionResult = .success(session)
    } else {
      sessionResult = Result {
        try CanvasSessionDescriptor.generate(apiVersion: Self.apiVersion, port: Self.port)
      }
    }
  }

  /// Raw capability for a child process environment. Callers must never put it in argv or logs.
  func capabilityForClient() throws -> String {
    try sessionResult.get().capability
  }

  func start() {
    guard listener == nil else { return }
    do {
      try CanvasSessionDescriptorStore.invalidate(at: sessionDescriptorURL)
    } catch {
      let message = UserFacingError.message(
        for: error,
        while: "Invalidating the previous local canvas session".localizedUI
      )
      UserFacingError.report(message)
      NSLog("[canvas] secure session unavailable")
      return
    }
    let session: CanvasSessionDescriptor
    do {
      session = try sessionResult.get()
    } catch {
      let message = UserFacingError.message(
        for: error,
        while: "Creating a secure local canvas session".localizedUI
      )
      UserFacingError.report(message)
      NSLog("[canvas] secure session unavailable")
      return
    }
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
    let listener: NWListener
    do {
      listener = try NWListener(using: params)
    } catch {
      let message = UserFacingError.message(for: error, while: "Starting Composer's local canvas service on 127.0.0.1:%d".localizedUI(Self.port))
      UserFacingError.report(message)
      NSLog("[canvas] \(message)")
      return
    }
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      guard let self, let listener, self.listener === listener else { return }
      switch state {
      case .ready:
        do {
          try CanvasSessionDescriptorStore.publish(session, at: self.sessionDescriptorURL)
          NSLog(Self.startupLogMessage)
        } catch {
          listener.cancel()
          self.listener = nil
          let message = UserFacingError.message(
            for: error,
            while: "Publishing the private canvas-session descriptor".localizedUI
          )
          UserFacingError.report(message)
          NSLog("[canvas] secure session unavailable")
        }
      case .failed(let error):
        self.listener = nil
        let message = UserFacingError.message(
          for: error,
          while: "Starting Composer's local canvas service on 127.0.0.1:%d".localizedUI(Self.port)
        )
        UserFacingError.report(message)
        NSLog("[canvas] local service failed")
      default:
        break
      }
    }
    listener.start(queue: queue)
  }

  static var startupLogMessage: String {
    "[canvas] serving on http://127.0.0.1:\(port)"
  }

  static var healthResponse: [String: Any] {
    [
      "ok": true,
      "service": "bonsai-canvas",
      "apiVersion": apiVersion,
      "port": port,
    ]
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    let deadline = DispatchWorkItem { connection.cancel() }
    queue.asyncAfter(deadline: .now() + Self.requestDeadline, execute: deadline)
    read(connection, buffer: Data(), deadline: deadline)
  }

  private func read(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      guard buffer.count <= Self.maximumRequestBytes else {
        deadline.cancel()
        self.send(connection, status: "413 Payload Too Large", json: ["ok": false, "error": "request too large".localizedUI])
        return
      }
      if let request = HTTPRequest(buffer), request.bodyStart + request.contentLength <= Self.maximumRequestBytes,
         buffer.count - request.bodyStart >= request.contentLength {
        deadline.cancel()
        self.route(request, buffer: buffer, on: connection)
      } else if let request = HTTPRequest(buffer), request.bodyStart + request.contentLength > Self.maximumRequestBytes {
        deadline.cancel()
        self.send(connection, status: "413 Payload Too Large", json: ["ok": false, "error": "request too large".localizedUI])
      } else if isComplete || error != nil {
        deadline.cancel()
        self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": "bad request".localizedUI])
      } else {
        self.read(connection, buffer: buffer, deadline: deadline)
      }
    }
  }

  private func route(_ request: HTTPRequest, buffer: Data, on connection: NWConnection) {
    let session: CanvasSessionDescriptor
    do {
      session = try sessionResult.get()
    } catch {
      send(connection, status: "503 Service Unavailable", json: [
        "ok": false,
        "error": "secure canvas session unavailable".localizedUI,
      ])
      return
    }
    if let rejection = CanvasRequestAuthorizer(session: session).rejection(for: request) {
      send(connection, status: rejection.status, json: [
        "ok": false,
        "error": rejection.message,
      ])
      return
    }

    switch (request.method, request.path) {
    case ("GET", "/health"):
      send(connection, status: "200 OK", json: Self.healthResponse)

    case ("GET", "/canvas"):
      Task { @MainActor in
        let graph = CanvasBridge.shared.snapshot()
        do {
          self.send(connection, status: "200 OK", data: try JSONEncoder().encode(graph))
        } catch {
          self.send(connection, status: "500 Internal Server Error", json: [
            "ok": false,
            "error": UserFacingError.message(for: error, while: "Encoding the canvas graph".localizedUI),
          ])
        }
      }

    case ("POST", "/capture"):
      let body = self.body(of: buffer, request: request)
      Task { @MainActor in
        let payload: [String: Any]
        do {
          guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": "Capture request must be a JSON object.".localizedUI])
            return
          }
          payload = decoded
        } catch {
          self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": UserFacingError.message(for: error, while: "Decoding the capture request".localizedUI)])
          return
        }
        let text = payload["text"]
        var op: [String: Any] = ["op": "capture"]
        if let text { op["text"] = text }
        let result = CanvasBridge.shared.apply(op)
        let ok = (result["ok"] as? Bool) ?? false
        self.send(connection, status: ok ? "200 OK" : "422 Unprocessable Entity", json: result)
      }

    case ("POST", "/canvas"):
      let body = self.body(of: buffer, request: request)
      Task { @MainActor in
        let op: [String: Any]
        do {
          guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": "Canvas request must be a JSON object.".localizedUI])
            return
          }
          op = decoded
        } catch {
          self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": UserFacingError.message(for: error, while: "Decoding the canvas request".localizedUI)])
          return
        }
        let result = CanvasBridge.shared.apply(op)
        let ok = (result["ok"] as? Bool) ?? false
        self.send(connection, status: ok ? "200 OK" : "422 Unprocessable Entity", json: result)
      }

    // MCP (JSON-RPC) transport so a headless coding agent can use canvas tools. The handshake
    // (initialize / tools/list / ping / notifications) is answered right here, off the MainActor, so
    // a busy UI can't stall a client's startup handshake; only `tools/call` hops to the MainActor to
    // touch the board. See CanvasMCP for why.
    case ("POST", "/mcp"):
      let body = self.body(of: buffer, request: request)
      let message: [String: Any]
      do {
        guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
          self.send(connection, status: "400 Bad Request", json: ["error": "MCP request must be a JSON object.".localizedUI])
          return
        }
        message = decoded
      } catch {
        self.send(connection, status: "400 Bad Request", json: ["error": UserFacingError.message(for: error, while: "Decoding the MCP request".localizedUI)])
        return
      }
      switch CanvasMCP.dispatch(message) {
      case let .reply(response):
        self.send(connection, status: "200 OK", json: response)
      case .notification:
        self.send(connection, status: "202 Accepted", data: Data())   // notification: no body
      case let .toolCall(name, arguments, id):
        Task { @MainActor in
          let response = CanvasMCP.callToolReply(name: name, arguments: arguments, id: id)
          self.send(connection, status: "200 OK", json: response)
        }
      }

    // MCP permission-prompt server: the agent's `--permission-prompt-tool` calls this so a tool
    // outside the canvas allow-list (an account connector, a built-in) gets a real allow/deny
    // dialog instead of a silent wall. Separate server name (`composer`) from `/mcp`'s `canvas`
    // so the model can't reach the arbiter through `--allowedTools mcp__canvas__*`.
    case ("POST", "/permission"):
      let body = self.body(of: buffer, request: request)
      Task { @MainActor in
        let message: [String: Any]
        do {
          guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            self.send(connection, status: "400 Bad Request", json: ["error": "MCP request must be a JSON object.".localizedUI])
            return
          }
          message = decoded
        } catch {
          self.send(connection, status: "400 Bad Request", json: ["error": UserFacingError.message(for: error, while: "Decoding the MCP request".localizedUI)])
          return
        }
        if let response = PermissionMCP.handle(message) {
          self.send(connection, status: "200 OK", json: response)
        } else {
          self.send(connection, status: "202 Accepted", data: Data())   // notification: no body
        }
      }

    case ("GET", "/mcp"), ("GET", "/permission"):
      // No server-initiated SSE stream; these servers are request/response only.
      send(connection, status: "405 Method Not Allowed", json: ["error": "use POST".localizedUI])

    default:
      send(connection, status: "404 Not Found", json: ["ok": false, "error": "not found".localizedUI])
    }
  }

  /// Slice the request body out of the raw buffer.
  private func body(of buffer: Data, request: HTTPRequest) -> Data {
    let start = buffer.startIndex + request.bodyStart
    let end = min(buffer.endIndex, start + request.contentLength)
    return start <= end ? buffer.subdata(in: start..<end) : Data()
  }

  // MARK: Response

  private func send(_ connection: NWConnection, status: String, json: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    send(connection, status: status, data: data)
  }

  private func send(_ connection: NWConnection, status: String, data: Data) {
    let payload = Self.httpResponse(status: status, data: data)
    connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
  }

  static func httpResponse(status: String, data: Data) -> Data {
    let header = "HTTP/1.1 \(status)\r\n"
      + "Content-Type: application/json\r\n"
      + "Content-Length: \(data.count)\r\n"
      + "Cache-Control: no-store\r\n"
      + "Connection: close\r\n\r\n"
    var payload = Data(header.utf8)
    payload.append(data)
    return payload
  }
}

// MARK: - Minimal HTTP request parsing

struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let duplicateHeaders: Set<String>
  let bodyStart: Int
  let contentLength: Int

  init?(_ buffer: Data) {
    guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
          let headerText = String(data: buffer.subdata(in: buffer.startIndex..<separator.lowerBound), encoding: .utf8)
    else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count >= 2 else { return nil }
    method = String(requestLine[0])
    path = String(requestLine[1])
    var parsed: [String: String] = [:]
    var duplicates = Set<String>()
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      if parsed[name] != nil { duplicates.insert(name) }
      parsed[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    headers = parsed
    duplicateHeaders = duplicates
    bodyStart = separator.upperBound - buffer.startIndex
    guard let length = Int(parsed["content-length"] ?? "0"), length >= 0 else { return nil }
    contentLength = length
  }
}

// MARK: - Request security

struct CanvasRequestRejection: Equatable {
  let status: String
  let message: String
}

/// Host/origin/capability checks kept separate from routing so tests can prove the gate without
/// opening a real user board. `CanvasServer.route` calls this before slicing or decoding the body
/// and before dispatching any work to the MainActor.
struct CanvasRequestAuthorizer {
  private static let sensitiveHeaders: Set<String> = [
    "authorization", "content-length", "host", "origin",
  ]

  let session: CanvasSessionDescriptor

  func rejection(for request: HTTPRequest) -> CanvasRequestRejection? {
    if !request.duplicateHeaders.isDisjoint(with: Self.sensitiveHeaders) {
      return CanvasRequestRejection(
        status: "400 Bad Request",
        message: "duplicate security-sensitive header".localizedUI
      )
    }
    guard request.headers["host"] == expectedHost else {
      return CanvasRequestRejection(
        status: "403 Forbidden",
        message: "request host is not allowed".localizedUI
      )
    }
    if let origin = request.headers["origin"], origin != session.baseURL {
      return CanvasRequestRejection(
        status: "403 Forbidden",
        message: "request origin is not allowed".localizedUI
      )
    }
    guard request.path == "/health" || request.headers["authorization"] == session.authorizationHeader else {
      return CanvasRequestRejection(
        status: "401 Unauthorized",
        message: "canvas authorization required".localizedUI
      )
    }
    return nil
  }

  private var expectedHost: String {
    URL(string: session.baseURL)?.host.map { host in
      let port = URL(string: session.baseURL)?.port ?? Int(CanvasServer.port)
      return "\(host):\(port)"
    } ?? "127.0.0.1:\(CanvasServer.port)"
  }
}
