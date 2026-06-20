import Foundation

/// Notion API client for the `@notion` connector. Auth is `Authorization: Bearer <token>` plus the
/// required `Notion-Version` header. Search lists pages the integration can see; render pulls a
/// page's top-level block children and flattens them to markdown text.
///
/// Setup the user must do once: create an internal integration at notion.so/my-integrations and
/// share the relevant pages with it — otherwise search returns nothing and render is empty.
/// Property keys are dynamic (the title property name varies per page), so this walks JSON with
/// JSONSerialization rather than fighting Codable over unknown keys.
struct NotionService {
  private let base = "https://api.notion.com/v1"
  private let version = "2022-06-28"   // long-stable; response shapes are coded against this version
  private let textCap = 10_000

  func search(_ query: String) async throws -> [AppSearchResult] {
    guard let token = ConnectorSecretStore.token(for: "@notion") else {
      throw AppSearchError.message("Add a Notion integration token in Settings → Connectors → Notion.")
    }
    let body: [String: Any] = [
      "query": query.trimmed,
      "filter": ["property": "object", "value": "page"],
      "page_size": 10,
    ]
    let json = try await request("POST", "/search", token: token, body: body)
    let results = json["results"] as? [[String: Any]] ?? []
    return results.prefix(10).compactMap { page -> AppSearchResult? in
      guard (page["object"] as? String) == "page", let id = page["id"] as? String, !id.isEmpty else { return nil }
      let title = Self.titleText(from: page)
      return AppSearchResult(
        id: id,
        title: title.isEmpty ? "Untitled" : title,
        subtitle: (page["url"] as? String) ?? "Notion page",
        selection: .notion(NotionReference(id: id, title: title)))
    }
  }

  func render(_ reference: NotionReference) async -> String {
    let header = "## Notion — \(reference.title.isEmpty ? "page" : reference.title)"
    guard let token = ConnectorSecretStore.token(for: "@notion") else {
      return "\(header)\nAdd a Notion integration token in Settings → Connectors → Notion."
    }
    do {
      let json = try await request("GET", "/blocks/\(reference.id)/children?page_size=100", token: token, body: nil)
      let blocks = json["results"] as? [[String: Any]] ?? []
      let text = Self.flatten(blocks)
      var lines = [header, "URL: https://www.notion.so/\(reference.id.replacingOccurrences(of: "-", with: ""))", ""]
      lines.append(text.isEmpty ? "_(no readable content — is the page shared with the integration?)_" : truncate(text))
      return lines.joined(separator: "\n")
    } catch let error as AppSearchError {
      return "\(header)\n\(error.errorDescription ?? "Could not load the Notion page.")"
    } catch {
      return "\(header)\nCould not load the Notion page: \(error.localizedDescription)"
    }
  }

  // MARK: - JSON shaping

  /// The page title is whichever property has `"type": "title"`; its name varies per page.
  private static func titleText(from page: [String: Any]) -> String {
    guard let properties = page["properties"] as? [String: Any] else { return "" }
    for (_, value) in properties {
      guard let property = value as? [String: Any], (property["type"] as? String) == "title",
            let runs = property["title"] as? [[String: Any]] else { continue }
      return runs.compactMap { $0["plain_text"] as? String }.joined()
    }
    return ""
  }

  private static func flatten(_ blocks: [[String: Any]]) -> String {
    var out: [String] = []
    for block in blocks {
      guard let type = block["type"] as? String else { continue }
      if type == "divider" { out.append("---"); continue }
      guard let payload = block[type] as? [String: Any] else { continue }
      let runs = (payload["rich_text"] as? [[String: Any]]) ?? []
      let text = runs.compactMap { $0["plain_text"] as? String }.joined().trimmed
      guard !text.isEmpty else { continue }
      switch type {
      case "heading_1": out.append("# \(text)")
      case "heading_2": out.append("## \(text)")
      case "heading_3": out.append("### \(text)")
      case "bulleted_list_item", "numbered_list_item": out.append("- \(text)")
      case "to_do": out.append("- [\((payload["checked"] as? Bool) == true ? "x" : " ")] \(text)")
      case "quote": out.append("> \(text)")
      case "code": out.append("```\n\(text)\n```")
      default: out.append(text)
      }
    }
    return out.joined(separator: "\n")
  }

  private func truncate(_ text: String) -> String {
    guard text.count > textCap else { return text }
    return String(text.prefix(textCap)) + "\n\n…(truncated)"
  }

  // MARK: - Networking

  private func request(_ method: String, _ path: String, token: String, body: [String: Any]?) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: base + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(version, forHTTPHeaderField: "Notion-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 12
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AppSearchError.message("No response from Notion.") }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 {
        throw AppSearchError.message("Notion rejected the token (401). Check Settings → Connectors → Notion.")
      }
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
      throw AppSearchError.message(message.map { "Notion: \($0)" } ?? "Notion API error (\(http.statusCode)).")
    }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }
}
