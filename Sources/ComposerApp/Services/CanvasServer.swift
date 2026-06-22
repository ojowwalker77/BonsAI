import Foundation
import Network

/// A tiny loopback-only HTTP server that exposes the canvas graph so a CLI / MCP server — and
/// thus an external agent — can read and manipulate the board live. Deliberately dependency-free
/// (Network.framework) and bound to 127.0.0.1 so it never leaves the machine.
///
/// Endpoints:
///   GET  /canvas   → the full `CanvasGraph`
///   POST /canvas   → one `{ "op": …, … }` mutation, returns `{ "ok": …, … }`
///   GET  /health   → liveness check
final class CanvasServer {
  static let shared = CanvasServer()
  static let port: UInt16 = 7337
  /// The server is loopback-only, but an agent/tool bug should still not be able to grow an
  /// in-memory request buffer without bound. Canvas mutations are deliberately tiny JSON.
  private static let maximumRequestBytes = 1 * 1_024 * 1_024

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "dev.jow.Composer.canvas-server")

  func start() {
    guard listener == nil else { return }
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
    let listener: NWListener
    do {
      listener = try NWListener(using: params)
    } catch {
      let message = UserFacingError.message(for: error, while: "Starting Composer’s local canvas service on 127.0.0.1:\(Self.port)")
      UserFacingError.report(message)
      NSLog("[canvas] \(message)")
      return
    }
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: queue)
    NSLog("[canvas] serving on http://127.0.0.1:\(Self.port)")
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, buffer: Data())
  }

  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      guard buffer.count <= Self.maximumRequestBytes else {
        self.send(connection, status: "413 Payload Too Large", json: ["ok": false, "error": "request too large"])
        return
      }
      if let request = HTTPRequest(buffer), request.bodyStart + request.contentLength <= Self.maximumRequestBytes,
         buffer.count - request.bodyStart >= request.contentLength {
        self.route(request, buffer: buffer, on: connection)
      } else if let request = HTTPRequest(buffer), request.bodyStart + request.contentLength > Self.maximumRequestBytes {
        self.send(connection, status: "413 Payload Too Large", json: ["ok": false, "error": "request too large"])
      } else if isComplete || error != nil {
        self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": "bad request"])
      } else {
        self.read(connection, buffer: buffer)
      }
    }
  }

  private func route(_ request: HTTPRequest, buffer: Data, on connection: NWConnection) {
    switch (request.method, request.path) {
    case ("GET", "/health"):
      send(connection, status: "200 OK", json: ["ok": true, "service": "composer-canvas"])

    case ("GET", "/canvas"):
      Task { @MainActor in
        let graph = CanvasBridge.shared.snapshot()
        do {
          self.send(connection, status: "200 OK", data: try JSONEncoder().encode(graph))
        } catch {
          self.send(connection, status: "500 Internal Server Error", json: [
            "ok": false,
            "error": UserFacingError.message(for: error, while: "Encoding the canvas graph"),
          ])
        }
      }

    case ("POST", "/canvas"):
      let body = self.body(of: buffer, request: request)
      Task { @MainActor in
        let op: [String: Any]
        do {
          guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": "Canvas request must be a JSON object."])
            return
          }
          op = decoded
        } catch {
          self.send(connection, status: "400 Bad Request", json: ["ok": false, "error": UserFacingError.message(for: error, while: "Decoding the canvas request")])
          return
        }
        let result = CanvasBridge.shared.apply(op)
        let ok = (result["ok"] as? Bool) ?? false
        self.send(connection, status: ok ? "200 OK" : "422 Unprocessable Entity", json: result)
      }

    // MCP (JSON-RPC) transport so a headless `claude` agent can use canvas tools.
    case ("POST", "/mcp"):
      let body = self.body(of: buffer, request: request)
      Task { @MainActor in
        let message: [String: Any]
        do {
          guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            self.send(connection, status: "400 Bad Request", json: ["error": "MCP request must be a JSON object."])
            return
          }
          message = decoded
        } catch {
          self.send(connection, status: "400 Bad Request", json: ["error": UserFacingError.message(for: error, while: "Decoding the MCP request")])
          return
        }
        if let response = CanvasMCP.handle(message) {
          self.send(connection, status: "200 OK", json: response)
        } else {
          self.send(connection, status: "202 Accepted", data: Data())   // notification: no body
        }
      }

    case ("GET", "/mcp"):
      // No server-initiated SSE stream; this server is request/response only.
      send(connection, status: "405 Method Not Allowed", json: ["error": "use POST"])

    default:
      send(connection, status: "404 Not Found", json: ["ok": false, "error": "not found"])
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
    let header = "HTTP/1.1 \(status)\r\n"
      + "Content-Type: application/json\r\n"
      + "Content-Length: \(data.count)\r\n"
      + "Access-Control-Allow-Origin: *\r\n"
      + "Connection: close\r\n\r\n"
    var payload = Data(header.utf8)
    payload.append(data)
    connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
  }
}

// MARK: - Minimal HTTP request parsing

private struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
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
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      parsed[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    headers = parsed
    bodyStart = separator.upperBound - buffer.startIndex
    guard let length = Int(parsed["content-length"] ?? "0"), length >= 0 else { return nil }
    contentLength = length
  }
}
