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

/// A browser tab captured by the `@browser` connector. Populated from Safari and Chrome;
/// the shape names the browser and bundle so more browsers can be added without changing
/// the token format.
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

/// A Linear issue captured by the `@linear` connector. `id` is the UUID used to fetch detail;
/// `identifier` (e.g. `ENG-123`) is the human key shown on the chip.
struct LinearReference: Codable, Equatable, Hashable {
  let id: String
  let identifier: String
}

/// A Notion page captured by the `@notion` connector. `id` is the page UUID; `title` is the chip
/// label, with the page content re-fetched at copy time.
struct NotionReference: Codable, Equatable, Hashable {
  let id: String
  let title: String
}

/// A Sentry issue captured by the `@sentry` connector. Issues are org-scoped, so `org` (the slug)
/// travels with the issue `id`; `shortID` (e.g. `FRONTEND-1AB`) is the chip label.
struct SentryReference: Codable, Equatable, Hashable {
  let org: String
  let id: String
  let shortID: String
}

/// A Figma frame/file captured by the `@figma` connector, parsed from a pasted Figma URL. `fileKey`
/// + optional `nodeId` (colon form, e.g. `1:2`) address the node; `name` is the chip label.
struct FigmaReference: Codable, Equatable, Hashable {
  let fileKey: String
  let nodeId: String
  let name: String
}

/// An Xcode `.xcresult` bundle captured by the `@xcode` connector. `resultPath` is parsed at copy
/// time for build errors and test failures.
struct XcodeReference: Codable, Equatable, Hashable {
  let resultPath: String
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
  /// An open browser tab, populated from Safari and Chromium browsers.
  case browser(BrowserTabReference)
  /// A Linear issue (description, status, comments, links rendered at copy time).
  case linear(LinearReference)
  /// A Notion page (title + flattened block text rendered at copy time).
  case notion(NotionReference)
  /// A Sentry issue (summary + latest-event stack trace rendered at copy time).
  case sentry(SentryReference)
  /// A Figma frame/file (dimensions, text layers, screenshot URL rendered at copy time).
  case figma(FigmaReference)
  /// An Xcode result bundle (build errors + test failures rendered at copy time).
  case xcode(XcodeReference)
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
/// - `@browser:<base64url-json>`                    (Safari/Chrome tab metadata)
/// - `@linear:<uuid>?k=ENG-123`                      (issue uuid + identifier)
/// - `@notion:<uuid>?t=Page%20Title`                 (page uuid + title)
/// - `@sentry:my-org/12345?s=FRONTEND-1AB`           (org slug / issue id + short id)
/// - `@figma:<base64url-json>`                        (file key + node id + name)
/// - `@xcode:/path/to/Result.xcresult`               (result bundle path)
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
    case let .linear(reference):
      if let identifier = percentEncodeTokenComponent(reference.identifier), !reference.identifier.isEmpty {
        return "\(appID):\(reference.id)?k=\(identifier)"
      }
      return "\(appID):\(reference.id)"
    case let .notion(reference):
      if let title = percentEncodeTokenComponent(reference.title), !reference.title.isEmpty {
        return "\(appID):\(reference.id)?t=\(title)"
      }
      return "\(appID):\(reference.id)"
    case let .sentry(reference):
      let base = "\(appID):\(reference.org)/\(reference.id)"
      if let short = percentEncodeTokenComponent(reference.shortID), !reference.shortID.isEmpty {
        return "\(base)?s=\(short)"
      }
      return base
    case let .figma(reference):
      return "\(appID):\(encodeJSONPayload(reference) ?? "")"
    case let .xcode(reference):
      return "\(appID):\(percentEncodePath(reference.resultPath))"
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
    case "@linear":
      if let separator = payload.range(of: "?k=") {
        let id = String(payload[payload.startIndex..<separator.lowerBound])
        let identifier = percentDecode(String(payload[separator.upperBound...]))
        return (appID, .linear(LinearReference(id: id, identifier: identifier)))
      }
      return (appID, .linear(LinearReference(id: payload, identifier: payload)))
    case "@notion":
      if let separator = payload.range(of: "?t=") {
        let id = String(payload[payload.startIndex..<separator.lowerBound])
        let title = percentDecode(String(payload[separator.upperBound...]))
        return (appID, .notion(NotionReference(id: id, title: title)))
      }
      return (appID, .notion(NotionReference(id: payload, title: payload)))
    case "@sentry":
      var rest = payload
      var shortID = ""
      if let separator = rest.range(of: "?s=") {
        shortID = percentDecode(String(rest[separator.upperBound...]))
        rest = String(rest[rest.startIndex..<separator.lowerBound])
      }
      guard let slash = rest.firstIndex(of: "/") else {
        return (appID, .sentry(SentryReference(org: rest, id: "", shortID: shortID.isEmpty ? rest : shortID)))
      }
      let org = String(rest[rest.startIndex..<slash])
      let id = String(rest[rest.index(after: slash)...])
      return (appID, .sentry(SentryReference(org: org, id: id, shortID: shortID.isEmpty ? id : shortID)))
    case "@figma":
      if let reference = decodeJSONPayload(payload, as: FigmaReference.self) {
        return (appID, .figma(reference))
      }
      return (appID, nil)
    case "@xcode":
      return (appID, .xcode(XcodeReference(resultPath: percentDecode(payload))))
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
    case let .linear(reference):
      return reference.identifier.isEmpty ? "Linear" : reference.identifier
    case let .notion(reference):
      return reference.title.isEmpty ? "Notion" : String(reference.title.prefix(28))
    case let .sentry(reference):
      return reference.shortID.isEmpty ? "Sentry" : reference.shortID
    case let .figma(reference):
      return reference.name.isEmpty ? "Figma" : String(reference.name.prefix(28))
    case let .xcode(reference):
      return shortXcode(reference.resultPath)
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
    let label = name.isEmpty ? path : name
    return label.count > 28 ? String(label.prefix(27)) + "…" : label
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

  /// `…/DerivedData/MyApp-<hash>/Logs/Test/X.xcresult` → `MyApp`; a pasted path → the file stem.
  private static func shortXcode(_ path: String) -> String {
    if let range = path.range(of: "DerivedData/") {
      let after = path[range.upperBound...]
      if let slash = after.firstIndex(of: "/") {
        let folder = String(after[after.startIndex..<slash])
        if let hash = folder.range(of: "-[a-z0-9]{20,}$", options: .regularExpression) {
          return String(folder[folder.startIndex..<hash.lowerBound])
        }
        return folder
      }
    }
    let name = (path as NSString).lastPathComponent
    if name.hasSuffix(".xcresult") { return String(name.dropLast(9)) }
    return name.isEmpty ? "Xcode" : name
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
