import Foundation

/// Sentry API client for the `@sentry` connector. Auth is `Authorization: Bearer <auth token>`.
/// Issues are organization-scoped, so search first resolves the org (`GET /organizations/`) and
/// then lists its issues; the resolved org slug travels inside the selection so render doesn't have
/// to re-discover it. Render shows the issue summary plus a best-effort exception + stack frames
/// pulled from the issue's latest event.
struct SentryService {
  private let base = "https://sentry.io/api/0"

  func search(_ query: String) async throws -> [AppSearchResult] {
    guard let token = ConnectorSecretStore.token(for: "@sentry") else {
      throw AppSearchError.message("Add a Sentry auth token in Settings → Connectors → Sentry.")
    }
    guard let org = try await firstOrg(token: token) else {
      throw AppSearchError.message("No Sentry organizations are visible to this token.")
    }
    var components = URLComponents(string: "\(base)/organizations/\(org)/issues/")!
    components.queryItems = [
      URLQueryItem(name: "query", value: query.trimmed),
      URLQueryItem(name: "limit", value: "8"),
    ]
    let issues: [Issue] = try await decode(components.url!, token: token)
    return issues.prefix(8).map { issue in
      let meta = [issue.level?.capitalized, issue.status?.capitalized, issue.count.map { "\($0)×" }]
        .compactMap { $0 }.joined(separator: " · ")
      let short = issue.shortId ?? issue.id
      return AppSearchResult(
        id: issue.id,
        title: "\(short)  \(issue.title)",
        subtitle: meta.isEmpty ? (issue.culprit ?? "") : meta,
        selection: .sentry(SentryReference(org: org, id: issue.id, shortID: short)))
    }
  }

  func render(_ reference: SentryReference) async -> String {
    let header = "## Sentry — \(reference.shortID)"
    guard let token = ConnectorSecretStore.token(for: "@sentry") else {
      return "\(header)\nAdd a Sentry auth token in Settings → Connectors → Sentry."
    }
    do {
      let issue: Issue = try await decode(URL(string: "\(base)/organizations/\(reference.org)/issues/\(reference.id)/")!, token: token)
      var lines = ["## Sentry — \(issue.shortId ?? reference.shortID)  \(issue.title)"]
      var meta: [String] = []
      if let level = issue.level { meta.append("Level: \(level)") }
      if let status = issue.status { meta.append("Status: \(status)") }
      if let count = issue.count { meta.append("Events: \(count)") }
      if let users = issue.userCount { meta.append("Users affected: \(users)") }
      if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
      if let culprit = issue.culprit, !culprit.isEmpty { lines.append("Culprit: \(culprit)") }
      if let first = issue.firstSeen { lines.append("First seen: \(first)") }
      if let last = issue.lastSeen { lines.append("Last seen: \(last)") }
      if let permalink = issue.permalink { lines.append("URL: \(permalink)") }

      // Best-effort: the latest event carries the exception + stack trace. Never fatal.
      if let trace = try? await latestEventTrace(reference: reference, token: token), !trace.isEmpty {
        lines.append("")
        lines.append("### Latest event")
        lines.append(trace)
      }
      return lines.joined(separator: "\n")
    } catch let error as AppSearchError {
      return "\(header)\n\(error.errorDescription ?? "Could not load the Sentry issue.")"
    } catch {
      return "\(header)\nCould not load the Sentry issue: \(error.localizedDescription)"
    }
  }

  // MARK: - Org + event

  private func firstOrg(token: String) async throws -> String? {
    let orgs: [Org] = try await decode(URL(string: "\(base)/organizations/")!, token: token)
    return orgs.first?.slug
  }

  /// Walk the latest event's `entries` for the exception entry, then pull its type/value and the
  /// crashing stack frames (Sentry orders frames oldest→newest, so the tail is the crash site).
  private func latestEventTrace(reference: SentryReference, token: String) async throws -> String {
    let url = URL(string: "\(base)/organizations/\(reference.org)/issues/\(reference.id)/events/latest/")!
    let data = try await rawGet(url, token: token)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = json["entries"] as? [[String: Any]],
          let exception = entries.first(where: { ($0["type"] as? String) == "exception" }),
          let payload = exception["data"] as? [String: Any],
          let values = payload["values"] as? [[String: Any]],
          let outermost = values.last else { return "" }

    var out: [String] = []
    let type = outermost["type"] as? String ?? "Error"
    let value = outermost["value"] as? String ?? ""
    out.append("**\(type)**\(value.isEmpty ? "" : ": \(value)")")

    if let stacktrace = outermost["stacktrace"] as? [String: Any], let frames = stacktrace["frames"] as? [[String: Any]] {
      let lines = frames.suffix(8).map { frame -> String in
        let function = frame["function"] as? String ?? "?"
        let file = (frame["filename"] as? String) ?? (frame["module"] as? String) ?? ""
        let lineNo = (frame["lineNo"] as? Int).map { ":\($0)" } ?? ""
        return "  at \(function) (\(file)\(lineNo))"
      }
      if !lines.isEmpty {
        out.append("```")
        out.append(contentsOf: lines)
        out.append("```")
      }
    }
    return out.joined(separator: "\n")
  }

  // MARK: - Networking

  private func decode<T: Decodable>(_ url: URL, token: String) async throws -> T {
    let data = try await rawGet(url, token: token)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func rawGet(_ url: URL, token: String) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 12
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AppSearchError.message("No response from Sentry.") }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw AppSearchError.message("Sentry rejected the token (\(http.statusCode)). Check Settings → Connectors → Sentry.")
      }
      throw AppSearchError.message("Sentry API error (\(http.statusCode)).")
    }
    return data
  }
}

// MARK: - Wire format

private struct Org: Decodable { let slug: String }

private struct Issue: Decodable {
  let id: String
  let shortId: String?
  let title: String
  let culprit: String?
  let level: String?
  let status: String?
  let count: String?       // Sentry returns the event count as a string
  let userCount: Int?
  let permalink: String?
  let firstSeen: String?
  let lastSeen: String?
}
