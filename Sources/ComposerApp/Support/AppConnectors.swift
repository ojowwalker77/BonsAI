import Foundation

/// Search-time knobs that are shared by connector implementations. Most apps ignore it;
/// GitHub uses it to switch between issue and PR search without needing a bespoke panel.
struct AppSearchContext: Equatable {
  var githubKind: GitHubItemKind = .issue
}

/// A connector is the scalable unit behind an app chip. The editor/panel only know how to
/// ask a connector for results and rendered context; each app owns its own API/CLI details.
protocol ComposerAppConnector {
  var id: String { get }
  var minimumQueryLength: Int { get }
  var supportsGitHubKindToggle: Bool { get }

  func placeholder(context: AppSearchContext) -> String
  func idleMessage(context: AppSearchContext) -> String
  func noResultsMessage(query: String, context: AppSearchContext) -> String
  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult]
  func render(selection: AppSelection?) async -> String
}

extension ComposerAppConnector {
  var minimumQueryLength: Int { 1 }
  var supportsGitHubKindToggle: Bool { false }

  func placeholder(context: AppSearchContext) -> String { "Search…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No results." }
}

enum AppConnectorRegistry {
  static let all: [any ComposerAppConnector] = [
    Context7AppConnector(),
    GitHubAppConnector(),
    FinderAppConnector(),
    BrowserAppConnector(),
  ]

  static func connector(for id: String) -> (any ComposerAppConnector)? {
    all.first { $0.id == id }
  }
}

// MARK: - Context7

private struct Context7AppConnector: ComposerAppConnector {
  let id = "@context7"
  private let service = Context7Service()

  func placeholder(context: AppSearchContext) -> String { "Search libraries…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search Context7 libraries." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async -> String {
    switch selection {
    case .none:
      return "## Context7\nUse Context7 to fetch current, version-accurate documentation for the libraries referenced above."
    case let .context7(libraryID, query):
      let docs = (try? await service.fetchDocs(libraryID: libraryID, query: query)) ?? ""
      let header = "## Context7 — \(libraryID)" + (query.map { " (topic: \($0))" } ?? "")
      guard !docs.isEmpty else {
        return "\(header)\nUse Context7 library `\(libraryID)` to pull current documentation" + (query.map { " on \($0)" } ?? "") + "."
      }
      return "\(header)\n\(truncate(docs, max: 12_000))"
    default:
      return ""
    }
  }
}

// MARK: - GitHub

private struct GitHubAppConnector: ComposerAppConnector {
  let id = "@github"
  let supportsGitHubKindToggle = true
  private let service = GitHubService()

  func placeholder(context: AppSearchContext) -> String {
    "Search \(context.githubKind.shortLabel.lowercased())…"
  }

  func idleMessage(context: AppSearchContext) -> String {
    "Type to search GitHub \(context.githubKind.shortLabel.lowercased())."
  }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query, kind: context.githubKind)
  }

  func render(selection: AppSelection?) async -> String {
    switch selection {
    case .none:
      return "## GitHub\nFetch and summarize the referenced GitHub issue or PR: state, body, key comments, constraints, and acceptance criteria."
    case let .github(kind, url):
      let detail = (try? await service.fetchDetail(url: url, kind: kind)) ?? ""
      let header = "## GitHub — \(AppToken.shortGitHub(url))"
      guard !detail.isEmpty else {
        return "\(header)\nReferenced \(kind == .pr ? "pull request" : "issue"): \(url)"
      }
      return "\(header)\n\(detail)"
    default:
      return ""
    }
  }
}

// MARK: - Finder

private struct FinderAppConnector: ComposerAppConnector {
  let id = "@finder"
  let minimumQueryLength = 2
  private let service = FinderService()

  func placeholder(context: AppSearchContext) -> String { "Fuzzy-find files and folders…" }
  func idleMessage(context: AppSearchContext) -> String { "Type at least 2 characters to find files and folders." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No matching files or folders." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async -> String {
    switch selection {
    case .none:
      return "## Finder\nReference the local file or folder needed for this prompt. Include the path and any relevant contents when available."
    case let .finder(reference):
      return await service.render(reference)
    default:
      return ""
    }
  }
}

// MARK: - Browser

private struct BrowserAppConnector: ComposerAppConnector {
  let id = "@browser"
  let minimumQueryLength = 0
  private let service = BrowserService()

  func placeholder(context: AppSearchContext) -> String { "Filter Safari tabs…" }
  func idleMessage(context: AppSearchContext) -> String { "Pick an open Safari tab, or type to filter." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String {
    query.trimmed.isEmpty ? "No open Safari tabs found." : "No matching Safari tabs."
  }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.searchSafariTabs(query: query)
  }

  func render(selection: AppSelection?) async -> String {
    switch selection {
    case .none:
      return "## Browser\nReference the relevant open browser tab. Include its URL, title, and browser metadata so the next tool can fetch or reason about it."
    case let .browser(reference):
      return service.render(reference)
    default:
      return ""
    }
  }
}

// MARK: - Shared

private func truncate(_ text: String, max: Int) -> String {
  guard text.count > max else { return text }
  return String(text.prefix(max)) + "\n\n…(truncated)"
}
