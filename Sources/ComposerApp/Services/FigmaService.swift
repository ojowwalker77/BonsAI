import Foundation

/// Figma REST client for the `@figma` connector. Auth is the **`X-Figma-Token`** header (a personal
/// access token — NOT `Authorization: Bearer`; that's the gotcha). Figma has no file-search API, so
/// the connector resolves a **pasted Figma URL**: render fetches the node's type/dimensions, its
/// text layers, and a rendered PNG URL. URL node-ids are hyphenated (`1-2`); the API wants colons
/// (`1:2`).
struct FigmaService {
  private let base = "https://api.figma.com/v1"

  func search(_ query: String) async throws -> [AppSearchResult] {
    guard let reference = Self.parseURL(query) else { return [] }
    let detail = reference.nodeId.isEmpty ? "whole file" : "node \(reference.nodeId)"
    return [AppSearchResult(
      id: "\(reference.fileKey):\(reference.nodeId)",
      title: reference.name.isEmpty ? "Figma file" : reference.name,
      subtitle: "Figma · \(detail)",
      selection: .figma(reference))]
  }

  func render(_ reference: FigmaReference) async throws -> String {
    guard let token = ConnectorSecretStore.token(for: "@figma") else {
      throw AppSearchError.message("Add a Figma access token in Settings → Connectors → Figma.")
    }
    if reference.nodeId.isEmpty {
      return try await renderFile(reference, token: token)
    }
    return try await renderNode(reference, token: token)
  }

  // MARK: - Render: whole file (no node in the URL)

  private func renderFile(_ reference: FigmaReference, token: String) async throws -> String {
    let json = try await get(url("/files/\(reference.fileKey)", ["depth": "1"]), token: token)
    let name = json["name"] as? String ?? reference.name
    var lines = ["## Figma — \(name.isEmpty ? "file" : name)", "File: \(reference.fileKey)", openLine(reference)]
    if let document = json["document"] as? [String: Any],
       let pages = document["children"] as? [[String: Any]] {
      let frames = pages.flatMap { ($0["children"] as? [[String: Any]]) ?? [] }
      if !frames.isEmpty {
        lines.append("")
        lines.append("### Top-level frames")
        for frame in frames.prefix(20) { lines.append("- \(frame["name"] as? String ?? "frame")") }
      }
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Render: a specific node

  private func renderNode(_ reference: FigmaReference, token: String) async throws -> String {
    let json = try await get(url("/files/\(reference.fileKey)/nodes", ["ids": reference.nodeId]), token: token)
    let image: String?
    var imageDiagnostic: String?
    do {
      image = try await renderedImage(reference, token: token)
      imageDiagnostic = nil
    } catch {
      image = nil
      imageDiagnostic = UserFacingError.message(for: error, while: "Fetching the Figma screenshot")
    }

    guard let nodes = json["nodes"] as? [String: Any],
          let entry = nodes[reference.nodeId] as? [String: Any],
          let document = entry["document"] as? [String: Any] else {
      return "## Figma — \(reference.name.isEmpty ? "frame" : reference.name)\nNode \(reference.nodeId) not found in this file."
    }
    let name = document["name"] as? String ?? reference.name
    var lines = ["## Figma — \(name.isEmpty ? "frame" : name)"]
    var meta = ["File: \(reference.fileKey)", "Node: \(reference.nodeId)"]
    if let type = document["type"] as? String { meta.append("Type: \(type)") }
    if let box = document["absoluteBoundingBox"] as? [String: Any],
       let width = box["width"] as? Double, let height = box["height"] as? Double {
      meta.append("\(Int(width.rounded()))×\(Int(height.rounded()))")
    }
    lines.append(meta.joined(separator: " · "))
    lines.append(openLine(reference))
    if let image, !image.isEmpty { lines.append("Screenshot: \(image)") }
    if let imageDiagnostic { lines.append("Screenshot unavailable: \(imageDiagnostic)") }

    let texts = Self.textLayers(document)
    if !texts.isEmpty {
      lines.append("")
      lines.append("### Text content")
      for text in texts.prefix(40) { lines.append("- \(text)") }
    }
    return lines.joined(separator: "\n")
  }

  private func renderedImage(_ reference: FigmaReference, token: String) async throws -> String? {
    let target = url("/images/\(reference.fileKey)", ["ids": reference.nodeId, "format": "png", "scale": "2"])
    let json = try await get(target, token: token)
    guard let images = json["images"] as? [String: Any] else { return nil }
    return images[reference.nodeId] as? String
  }

  private func openLine(_ reference: FigmaReference) -> String {
    let urlNode = reference.nodeId.replacingOccurrences(of: ":", with: "-")
    let suffix = urlNode.isEmpty ? "" : "?node-id=\(urlNode)"
    return "Open: https://www.figma.com/design/\(reference.fileKey)/\(suffix)"
  }

  // MARK: - Text extraction

  private static func textLayers(_ node: [String: Any]) -> [String] {
    var out: [String] = []
    func walk(_ node: [String: Any]) {
      if (node["type"] as? String) == "TEXT",
         let characters = (node["characters"] as? String)?.trimmed, !characters.isEmpty {
        out.append(characters.replacingOccurrences(of: "\n", with: " "))
      }
      if let children = node["children"] as? [[String: Any]] { children.forEach(walk) }
    }
    walk(node)
    return out
  }

  // MARK: - URL parsing

  /// `figma.com/{file|design|proto}/<key>/<Title-Slug>?node-id=1-2` → reference. Returns nil for a
  /// non-Figma or malformed URL so the panel shows "paste a Figma URL".
  static func parseURL(_ raw: String) -> FigmaReference? {
    let trimmed = raw.trimmed
    guard let url = URL(string: trimmed), let host = url.host, host.contains("figma.com") else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2, ["file", "design", "proto"].contains(parts[0]) else { return nil }
    let key = parts[1]
    let name: String = {
      guard parts.count >= 3 else { return "" }
      let slug = parts[2].replacingOccurrences(of: "-", with: " ")
      return slug.removingPercentEncoding ?? slug
    }()
    var nodeId = ""
    if let items = URLComponents(string: trimmed)?.queryItems,
       let value = items.first(where: { $0.name == "node-id" })?.value {
      nodeId = value.replacingOccurrences(of: "-", with: ":")
    }
    return FigmaReference(fileKey: key, nodeId: nodeId, name: name)
  }

  // MARK: - Networking

  private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
    var components = URLComponents(string: base + path)!
    if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
    return components.url!
  }

  private func get(_ url: URL, token: String) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.setValue(token, forHTTPHeaderField: "X-Figma-Token")   // personal token — NOT Bearer
    request.timeoutInterval = 15
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AppSearchError.message("No response from Figma.") }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 403 { throw AppSearchError.message("Figma rejected the token (403). Check Settings → Connectors → Figma.") }
      if http.statusCode == 404 { throw AppSearchError.message("Figma file not found (404) — does the token have access to it?") }
      throw AppSearchError.message("Figma returned HTTP \(http.statusCode) and did not provide an error message.")
    }
    do {
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AppSearchError.message("Figma returned JSON in an unexpected shape.")
      }
      return json
    } catch let error as AppSearchError {
      throw error
    } catch {
      throw AppSearchError.message(UserFacingError.message(for: error, while: "Decoding Figma’s response"))
    }
  }
}
