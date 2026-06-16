import Foundation

/// Wraps the `gh` CLI for issue/PR search and detail fetch.
struct GitHubService {
  /// True if `gh` is installed and authenticated (branch on exit code, not text).
  func isReady() async -> Bool {
    guard let result = try? await Shell.run(["gh", "auth", "status"]) else { return false }
    return result.status == 0
  }

  /// Global GitHub search for issues or PRs.
  func search(_ query: String, kind: GitHubItemKind) async throws -> [AppSearchResult] {
    let trimmed = query.trimmed
    guard !trimmed.isEmpty else { return [] }

    let result = try await Shell.run([
      "gh", "search", kind.ghSubcommand, trimmed,
      "--limit", "8", "--json", "number,title,state,url,repository",
    ])
    guard result.status == 0 else { throw AppSearchError.fromGH(result.stderr) }

    let items = try JSONDecoder().decode([Item].self, from: Data(result.stdout.utf8))
    return items.map { item in
      let repo = item.repository?.nameWithOwner ?? ""
      let state = item.state?.capitalized ?? ""
      let meta = [repo.isEmpty ? nil : repo, state.isEmpty ? nil : state].compactMap { $0 }.joined(separator: " · ")
      return AppSearchResult(
        id: item.url,
        title: "#\(item.number)  \(item.title)",
        subtitle: meta,
        selection: .github(kind: kind, url: item.url))
    }
  }

  /// A compact, self-contained text block for a resolved issue/PR (title, state, body).
  func fetchDetail(url: String, kind: GitHubItemKind) async throws -> String {
    let fields = kind == .pr
      ? "number,title,state,body,author,url,baseRefName,headRefName,reviewDecision"
      : "number,title,state,body,author,url,labels"
    let result = try await Shell.run(["gh", kind.ghViewNoun, "view", url, "--json", fields])
    guard result.status == 0 else { throw AppSearchError.fromGH(result.stderr) }

    let detail = try JSONDecoder().decode(Detail.self, from: Data(result.stdout.utf8))
    var lines = ["**\(detail.title)** (#\(detail.number)) — \(detail.state?.capitalized ?? "")"]
    if let login = detail.author?.login { lines.append("Author: @\(login)") }
    if kind == .pr {
      if let base = detail.baseRefName, let head = detail.headRefName { lines.append("Branch: \(head) → \(base)") }
      if let review = detail.reviewDecision, !review.isEmpty { lines.append("Review: \(review)") }
    }
    if let labels = detail.labels, !labels.isEmpty {
      lines.append("Labels: " + labels.map(\.name).joined(separator: ", "))
    }
    lines.append("URL: \(detail.url)")
    let body = (detail.body ?? "").trimmed
    lines.append("")
    lines.append(body.isEmpty ? "_(no description)_" : body)
    return lines.joined(separator: "\n")
  }
}

// MARK: - Wire format

private struct Item: Decodable {
  let number: Int
  let title: String
  let state: String?
  let url: String
  let repository: Repo?
  struct Repo: Decodable { let nameWithOwner: String }
}

private struct Detail: Decodable {
  let number: Int
  let title: String
  let state: String?
  let body: String?
  let url: String
  let author: Author?
  let baseRefName: String?
  let headRefName: String?
  let reviewDecision: String?
  let labels: [Label]?
  struct Author: Decodable { let login: String? }
  struct Label: Decodable { let name: String }
}

// MARK: - Errors

enum AppSearchError: LocalizedError {
  case message(String)
  var errorDescription: String? { switch self { case .message(let m): m } }

  /// Map common `gh` failures to a short, friendly line.
  static func fromGH(_ stderr: String) -> AppSearchError {
    let text = stderr.trimmed
    if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("logged in") {
      return .message("Run `gh auth login` to search GitHub.")
    }
    return .message(text.isEmpty ? "GitHub search failed." : String(text.prefix(140)))
  }
}
