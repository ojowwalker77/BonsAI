import Foundation

/// Search-time knobs that are shared by connector implementations. Most apps ignore it;
/// GitHub uses it to switch between issue and PR search without needing a bespoke panel.
struct AppSearchContext: Equatable {
  var githubKind: GitHubItemKind = .issue
}

/// A connector is the scalable unit behind an app chip. The editor/panel only know how to
/// ask a connector for results and rendered context; each app owns its own API/CLI details.
/// Declares whether a connector needs a user-supplied secret, so Settings can render a token
/// field and the service can read it from ConnectorSecretStore.
enum ConnectorAuth: Equatable {
  case none
  /// A personal API token pasted in Settings. `createURL` deep-links to where the user mints one.
  case apiToken(label: String, hint: String, createURL: String?)
}

protocol ComposerAppConnector {
  var id: String { get }
  var minimumQueryLength: Int { get }
  var supportsGitHubKindToggle: Bool { get }
  var auth: ConnectorAuth { get }

  func placeholder(context: AppSearchContext) -> String
  func idleMessage(context: AppSearchContext) -> String
  func noResultsMessage(query: String, context: AppSearchContext) -> String
  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult]
  /// Resolve the selected reference into paste-ready context. Errors deliberately propagate to
  /// `SelfContainedRenderer`, which reports the affected connector instead of silently dropping it.
  func render(selection: AppSelection?) async throws -> String
}

extension ComposerAppConnector {
  var minimumQueryLength: Int { 1 }
  var supportsGitHubKindToggle: Bool { false }
  var auth: ConnectorAuth { .none }

  func placeholder(context: AppSearchContext) -> String { "Search…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No results." }
}

enum AppConnectorRegistry {
  static let all: [any ComposerAppConnector] = [
    Context7AppConnector(),
    GitHubAppConnector(),
    FinderAppConnector(),
    ICloudAppConnector(),
    NotesAppConnector(),
    BrowserAppConnector(),
    LinearAppConnector(),
    NotionAppConnector(),
    SentryAppConnector(),
    FigmaAppConnector(),
    XcodeAppConnector(),
  ]

  static func connector(for id: String) -> (any ComposerAppConnector)? {
    all.first { $0.id == id }
  }
}

// MARK: - Context7

private struct Context7AppConnector: ComposerAppConnector {
  let id = "@context7"
  let minimumQueryLength = 2
  private let service = Context7Service()

  func placeholder(context: AppSearchContext) -> String { "Search libraries…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search libraries." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No libraries found." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## Context7\nUse Context7 to fetch current, version-accurate documentation for the libraries referenced above."
    case let .context7(libraryID, query):
      let docs = try await service.fetchDocs(libraryID: libraryID, query: query)
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
  let minimumQueryLength = 2
  let supportsGitHubKindToggle = true
  private let service = GitHubService()

  func placeholder(context: AppSearchContext) -> String {
    "Search \(context.githubKind.shortLabel.lowercased())…"
  }

  func idleMessage(context: AppSearchContext) -> String {
    "Type to search your \(context.githubKind.shortLabel.lowercased())."
  }

  func noResultsMessage(query: String, context: AppSearchContext) -> String {
    "No \(context.githubKind.shortLabel.lowercased()) found."
  }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query, kind: context.githubKind)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## GitHub\nFetch and summarize the referenced GitHub issue or PR: state, body, key comments, constraints, and acceptance criteria."
    case let .github(kind, url):
      let detail = try await service.fetchDetail(url: url, kind: kind)
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

  func placeholder(context: AppSearchContext) -> String { "Search files & folders…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to find files and folders." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No matching files or folders." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
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

// MARK: - iCloud Drive

private struct ICloudAppConnector: ComposerAppConnector {
  let id = "@icloud"
  let minimumQueryLength = 2
  private let service = ICloudService()

  func placeholder(context: AppSearchContext) -> String { "Search iCloud Drive…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search your iCloud Drive." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No matching files in iCloud Drive." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## iCloud Drive\nReference the relevant file or folder from iCloud Drive — include its path and contents."
    case let .icloud(reference):
      return await service.render(reference)
    default:
      return ""
    }
  }
}

// MARK: - Apple Notes

private struct NotesAppConnector: ComposerAppConnector {
  let id = "@notes"
  let minimumQueryLength = 2
  private let service = NotesService()

  func placeholder(context: AppSearchContext) -> String { "Search notes…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search your Apple Notes." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No matching notes." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## Apple Notes\nReference the relevant Apple Note — pull its text so the next tool has the note's content."
    case let .notes(reference):
      return try await service.render(reference)
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

  func placeholder(context: AppSearchContext) -> String { "Filter open tabs…" }
  func idleMessage(context: AppSearchContext) -> String { "Pick an open browser tab, or type to filter." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String {
    query.trimmed.isEmpty ? "No open browser tabs found." : "No matching tabs."
  }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.searchTabs(query: query)
  }

  func render(selection: AppSelection?) async throws -> String {
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

// MARK: - Linear

private struct LinearAppConnector: ComposerAppConnector {
  let id = "@linear"
  let minimumQueryLength = 2
  var auth: ConnectorAuth {
    .apiToken(label: "API Key",
              hint: "Personal API key from Linear → Settings → API",
              createURL: "https://linear.app/settings/api")
  }
  private let service = LinearService()

  func placeholder(context: AppSearchContext) -> String { "Search issues, or paste an ID like ENG-123…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search your issues." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No matching issues." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## Linear\nReference the Linear issue — description, status, acceptance criteria, comments, and linked PRs."
    case let .linear(reference):
      return try await service.render(reference)
    default:
      return ""
    }
  }
}

// MARK: - Notion

private struct NotionAppConnector: ComposerAppConnector {
  let id = "@notion"
  let minimumQueryLength = 2
  var auth: ConnectorAuth {
    .apiToken(label: "Integration Token",
              hint: "Internal integration token from notion.so/my-integrations (share pages with it)",
              createURL: "https://www.notion.so/my-integrations")
  }
  private let service = NotionService()

  func placeholder(context: AppSearchContext) -> String { "Search pages…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search your pages." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String {
    "No matching pages — is it shared with your integration?"
  }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## Notion\nReference the relevant Notion page — spec, RFC, or decision doc — and pull its content."
    case let .notion(reference):
      return try await service.render(reference)
    default:
      return ""
    }
  }
}

// MARK: - Sentry

private struct SentryAppConnector: ComposerAppConnector {
  let id = "@sentry"
  let minimumQueryLength = 2
  var auth: ConnectorAuth {
    .apiToken(label: "Auth Token",
              hint: "Token from sentry.io/settings/account/api/auth-tokens (needs event:read)",
              createURL: "https://sentry.io/settings/account/api/auth-tokens/")
  }
  private let service = SentryService()

  func placeholder(context: AppSearchContext) -> String { "Search issues…" }
  func idleMessage(context: AppSearchContext) -> String { "Type to search your issues." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "No matching issues." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## Sentry\nReference the Sentry issue — error, level, affected release, and recent stack trace."
    case let .sentry(reference):
      return try await service.render(reference)
    default:
      return ""
    }
  }
}

// MARK: - Figma

private struct FigmaAppConnector: ComposerAppConnector {
  let id = "@figma"
  let minimumQueryLength = 8
  var auth: ConnectorAuth {
    .apiToken(label: "Access Token",
              hint: "Personal access token from figma.com → Settings → Security",
              createURL: "https://www.figma.com/settings")
  }
  private let service = FigmaService()

  func placeholder(context: AppSearchContext) -> String { "Paste a Figma frame URL…" }
  func idleMessage(context: AppSearchContext) -> String { "Paste a Figma file or frame URL to attach it." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String { "Not a Figma URL — copy a frame link from Figma." }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## Figma\nReference the Figma frame — its dimensions, text content, and a screenshot URL for the next tool."
    case let .figma(reference):
      return try await service.render(reference)
    default:
      return ""
    }
  }
}

// MARK: - Xcode

private struct XcodeAppConnector: ComposerAppConnector {
  let id = "@xcode"
  let minimumQueryLength = 0
  private let service = XcodeService()

  func placeholder(context: AppSearchContext) -> String { "Filter results, or paste a .xcresult path…" }
  func idleMessage(context: AppSearchContext) -> String { "Pick a recent build or test result." }
  func noResultsMessage(query: String, context: AppSearchContext) -> String {
    "No .xcresult bundles found."
  }

  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult] {
    try await service.search(query)
  }

  func render(selection: AppSelection?) async throws -> String {
    switch selection {
    case .none:
      return "## Xcode\nReference the latest Xcode build errors or test failures."
    case let .xcode(reference):
      return try await service.render(reference)
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
