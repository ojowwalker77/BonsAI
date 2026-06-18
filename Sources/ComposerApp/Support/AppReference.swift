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

/// A Finder target captured by the `@finder` connector. `isDirectory` is advisory;
/// rendering re-checks the path because the file system can change after insertion.
struct FinderReference: Codable, Equatable, Hashable {
  let path: String
  let isDirectory: Bool?
}

/// A browser tab captured by the `@browser` connector. The first implementation is
/// Safari-only, but the shape deliberately names the browser and bundle so Chrome/Arc/etc.
/// can be added without changing the token format.
struct BrowserTabReference: Codable, Equatable, Hashable {
  let browser: String
  let bundleID: String
  let title: String
  let url: String
  let windowIndex: Int
  let tabIndex: Int
  let isActive: Bool
  let capturedAt: String

  var host: String {
    URL(string: url)?.host(percentEncoded: false) ?? ""
  }
}

/// The concrete thing a resolved app chip points at. `nil` (absent) means the app is
/// tagged but not yet narrowed — the chip shows a disclosure so the user can search it.
enum AppSelection: Equatable, Hashable {
  /// A Context7 library id (e.g. `/vercel/next.js`) plus the query that found it,
  /// reused as the natural-language topic when fetching docs.
  case context7(libraryID: String, query: String?)
  /// A GitHub issue/PR by its html URL; kind is also derivable from the URL.
  case github(kind: GitHubItemKind, url: String)
  /// A local file or folder found through Finder/Spotlight.
  case finder(FinderReference)
  /// An open browser tab. Currently populated from Safari.
  case browser(BrowserTabReference)
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
/// - `@finder:/Users/me/Project/README.md`
/// - `@browser:<base64url-json>`                    (Safari tab metadata)
enum AppToken {
  static var appIDs: Set<String> { Set(MentionCatalog.apps.map(\.id)) }

  /// Build the serialized token for an app + optional resolved selection.
  static func string(appID: String, selection: AppSelection?) -> String {
    guard let selection else { return appID }
    switch selection {
    case let .context7(libraryID, query):
      if let query, !query.isEmpty, let encoded = percentEncodeTokenComponent(query) {
        return "\(appID):\(libraryID)?q=\(encoded)"
      }
      return "\(appID):\(libraryID)"
    case let .github(_, url):
      return "\(appID):\(url)"
    case let .finder(reference):
      return "\(appID):\(percentEncodePath(reference.path))"
    case let .browser(reference):
      return "\(appID):\(encodeJSONPayload(reference) ?? percentEncodeTokenComponent(reference.url) ?? reference.url)"
    }
  }

  /// Parse one token. Returns nil unless it's a known app token, so non-app mentions
  /// (skills, clipboard) are left untouched and non-interactive.
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
    case "@finder":
      return (appID, .finder(FinderReference(path: percentDecode(payload), isDirectory: nil)))
    case "@browser":
      if let reference = decodeJSONPayload(payload, as: BrowserTabReference.self) {
        return (appID, .browser(reference))
      }
      // Backward-compatible/fallback shape: treat the payload as a URL-only tab.
      let url = percentDecode(payload)
      return (appID, .browser(BrowserTabReference(
        browser: "Browser", bundleID: "", title: shortBrowserTitle(url: url), url: url,
        windowIndex: 0, tabIndex: 0, isActive: false, capturedAt: "")))
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
    case let .finder(reference):
      return shortPath(reference.path)
    case let .browser(reference):
      return shortBrowser(reference)
    }
  }

  /// Every app token in a plain-text note, in order, de-duplicated by exact token string.
  static func scan(_ plain: String) -> [(token: String, appID: String, selection: AppSelection?)] {
    let ids = MentionCatalog.apps.map { NSRegularExpression.escapedPattern(for: $0.id) }.joined(separator: "|")
    let pattern = "(?:\(ids))(?::\\S+)?"
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

  private static func shortPath(_ path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? path : name
  }

  private static func shortBrowser(_ reference: BrowserTabReference) -> String {
    let title = reference.title.trimmed
    if !title.isEmpty { return String(title.prefix(28)) }
    if !reference.host.isEmpty { return reference.host }
    return shortBrowserTitle(url: reference.url)
  }

  private static func shortBrowserTitle(url: String) -> String {
    URL(string: url)?.host(percentEncoded: false) ?? "Browser tab"
  }

  // MARK: Encoding

  private static func percentEncodeTokenComponent(_ s: String) -> String? {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed)
  }

  private static func percentEncodePath(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~/")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
  }

  private static func percentDecode(_ s: String) -> String { s.removingPercentEncoding ?? s }

  private static func encodeJSONPayload<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeJSONPayload<T: Decodable>(_ payload: String, as type: T.Type) -> T? {
    var normalized = payload
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - normalized.count % 4) % 4
    if padding > 0 { normalized += String(repeating: "=", count: padding) }
    guard let data = Data(base64Encoded: normalized) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }
}

// MARK: - Search result

/// One row in the inline app-search panel. Committing it stamps `selection` into the chip.
struct AppSearchResult: Identifiable, Hashable {
  let id: String        // stable: library id, gh url, local path, or tab id
  let title: String     // primary line
  let subtitle: String  // secondary line
  let selection: AppSelection
}
