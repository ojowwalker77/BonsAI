import Foundation

// MARK: - Resolved selection

/// Which kind of GitHub item the search is scoped to.
enum GitHubItemKind: String, Equatable, Hashable, CaseIterable {
  case issue, pr
  var pluralLabel: String { self == .issue ? "Issues" : "Pull Requests" }
  var shortLabel: String { self == .issue ? "Issues" : "PRs" }
  /// `gh search <subcommand>` and `gh <subcommand> view`.
  var ghSubcommand: String { self == .issue ? "issues" : "prs" }
  var ghViewNoun: String { self == .issue ? "issue" : "pr" }
}

/// The concrete thing a resolved app chip points at. `nil` (absent) means the app is
/// tagged but not yet narrowed — the chip shows a disclosure so the user can search it.
enum AppSelection: Equatable, Hashable {
  /// A Context7 library id (e.g. `/vercel/next.js`) plus the query that found it,
  /// reused as the natural-language topic when fetching docs.
  case context7(libraryID: String, query: String?)
  /// A GitHub issue/PR by its html URL; kind is also derivable from the URL.
  case github(kind: GitHubItemKind, url: String)
}

// MARK: - Token codec

/// Serializes an app + optional selection to/from the `@token` string that lives in the
/// note's plain text (the source of truth — chips are a cosmetic, within-session layer).
///
/// Forms:
/// - `@context7`                                    (unresolved)
/// - `@context7:/vercel/next.js`                    (library)
/// - `@context7:/vercel/next.js?q=middleware%20auth`(library + topic)
/// - `@github`                                      (unresolved)
/// - `@github:https://github.com/owner/repo/issues/1`
/// - `@github:https://github.com/owner/repo/pull/2`
enum AppToken {
  static let appIDs: Set<String> = ["@context7", "@github"]

  /// Build the serialized token for an app + optional resolved selection.
  static func string(appID: String, selection: AppSelection?) -> String {
    guard let selection else { return appID }
    switch selection {
    case let .context7(libraryID, query):
      if let query, !query.isEmpty, let encoded = percentEncode(query) {
        return "\(appID):\(libraryID)?q=\(encoded)"
      }
      return "\(appID):\(libraryID)"
    case let .github(_, url):
      return "\(appID):\(url)"
    }
  }

  /// Parse one token. Returns nil unless it's a known app token (`@context7`/`@github`),
  /// so non-app mentions (skills, clipboard) are left untouched and non-interactive.
  static func parse(_ token: String) -> (appID: String, selection: AppSelection?)? {
    guard let colon = token.firstIndex(of: ":") else {
      return appIDs.contains(token) ? (token, nil) : nil
    }
    let appID = String(token[token.startIndex..<colon])
    guard appIDs.contains(appID) else { return nil }
    let payload = String(token[token.index(after: colon)...])
    guard !payload.isEmpty else { return (appID, nil) }

    switch appID {
    case "@context7":
      if let q = payload.range(of: "?q=") {
        let lib = String(payload[payload.startIndex..<q.lowerBound])
        let query = percentDecode(String(payload[q.upperBound...]))
        return (appID, .context7(libraryID: lib, query: query))
      }
      return (appID, .context7(libraryID: payload, query: nil))
    case "@github":
      return (appID, .github(kind: gitHubKind(forURL: payload), url: payload))
    default:
      return (appID, nil)
    }
  }

  /// Human chip label, derived purely from the token (no network) so reloaded notes
  /// and async restyles render identically.
  static func label(appID: String, selection: AppSelection?) -> String {
    switch selection {
    case .none:
      return MentionCatalog.all.first { $0.id == appID }?.label ?? appID
    case let .context7(libraryID, _):
      return shortLibrary(libraryID)
    case let .github(_, url):
      return shortGitHub(url)
    }
  }

  /// Every app token in a plain-text note, in order, de-duplicated by exact token string.
  static func scan(_ plain: String) -> [(token: String, appID: String, selection: AppSelection?)] {
    let pattern = "@(?:context7|github)(?::\\S+)?"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = plain as NSString
    var seen = Set<String>()
    var out: [(String, String, AppSelection?)] = []
    for match in regex.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
      let token = ns.substring(with: match.range)
      guard !seen.contains(token), let parsed = parse(token) else { continue }
      seen.insert(token)
      out.append((token, parsed.appID, parsed.selection))
    }
    return out
  }

  // MARK: Label helpers

  /// `/vercel/next.js` → `next.js`; skips a trailing version segment (`/v15`, `@v15`).
  private static func shortLibrary(_ id: String) -> String {
    let base = id.split(separator: "@").first.map(String.init) ?? id
    let parts = base.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    guard let last = parts.last else { return id }
    if parts.count >= 2, last.first == "v", last.dropFirst().first?.isNumber == true {
      return parts[parts.count - 2]
    }
    return last
  }

  /// `https://github.com/facebook/react/issues/123` → `react#123`.
  static func shortGitHub(_ url: String) -> String {
    let parts = (URL(string: url)?.pathComponents ?? []).filter { $0 != "/" }
    guard parts.count >= 4 else { return "GitHub" }
    let repo = parts[1]
    let number = parts[3]
    return "\(repo)#\(number)"
  }

  static func gitHubKind(forURL url: String) -> GitHubItemKind {
    url.contains("/pull/") ? .pr : .issue
  }

  // MARK: Encoding

  private static func percentEncode(_ s: String) -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed)
  }
  private static func percentDecode(_ s: String) -> String { s.removingPercentEncoding ?? s }
}

// MARK: - Search result

/// One row in the inline app-search panel. Committing it stamps `selection` into the chip.
struct AppSearchResult: Identifiable, Hashable {
  let id: String        // stable: library id or gh url
  let title: String     // primary line
  let subtitle: String  // secondary line (description, or "owner/repo · state")
  let selection: AppSelection
}
