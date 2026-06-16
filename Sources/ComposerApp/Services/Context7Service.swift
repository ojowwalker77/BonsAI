import Foundation

/// Talks to the Context7 v2 HTTP API. Unauthenticated works (rate-limited); an optional
/// `CONTEXT7_API_KEY` in the environment raises the limit.
struct Context7Service {
  private let base = URL(string: "https://context7.com/api/v2")!

  /// Search libraries. The user's text drives both the library lookup and the relevance query.
  func search(_ query: String) async throws -> [AppSearchResult] {
    let trimmed = query.trimmed
    guard !trimmed.isEmpty else { return [] }

    var comps = URLComponents(url: base.appendingPathComponent("libs/search"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [
      URLQueryItem(name: "query", value: trimmed),
      URLQueryItem(name: "libraryName", value: trimmed),
    ]
    let data = try await get(comps.url!)
    let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
    return decoded.results.prefix(8).map { lib in
      AppSearchResult(
        id: lib.id,
        title: lib.title,
        subtitle: lib.subtitleLine,
        selection: .context7(libraryID: lib.id, query: trimmed))
    }
  }

  /// Markdown docs for a resolved library, narrowed by the stored topic query.
  func fetchDocs(libraryID: String, query: String?) async throws -> String {
    var comps = URLComponents(url: base.appendingPathComponent("context"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [
      URLQueryItem(name: "libraryId", value: libraryID),
      URLQueryItem(name: "type", value: "txt"),
    ]
    if let query, !query.isEmpty { comps.queryItems?.append(URLQueryItem(name: "query", value: query)) }
    let data = try await get(comps.url!)
    return String(data: data, encoding: .utf8)?.trimmed ?? ""
  }

  // MARK: HTTP

  private func get(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("composer-macos", forHTTPHeaderField: "X-Context7-Source")
    if let key = ProcessInfo.processInfo.environment["CONTEXT7_API_KEY"], !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AppSearchError.message("Context7 returned HTTP \(http.statusCode).")
    }
    return data
  }
}

// MARK: - Wire format

private struct SearchResponse: Decodable { let results: [Library] }

private struct Library: Decodable {
  let id: String
  let title: String
  let description: String?
  let trustScore: Double?
  let totalSnippets: Int?

  /// "★ 9.5 · <description>" trimmed to one line for the dropdown.
  var subtitleLine: String {
    var bits: [String] = []
    if let trustScore { bits.append("Trust \(trimZero(trustScore))") }
    if let totalSnippets, totalSnippets > 0 { bits.append("\(totalSnippets) snippets") }
    let meta = bits.joined(separator: " · ")
    let desc = (description ?? "").replacingOccurrences(of: "\n", with: " ").trimmed
    switch (meta.isEmpty, desc.isEmpty) {
    case (false, false): return "\(meta) · \(desc)"
    case (false, true): return meta
    default: return desc
    }
  }

  private func trimZero(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }
}
