import Foundation

/// Browser connector. Enumerates open tabs across Safari and any Chromium browser (Chrome, Brave,
/// Edge, Vivaldi, Opera, Arc, Chromium, Helium, …) via Apple Events (JXA) — they all share Chrome's
/// scripting dictionary, so one parameterized script covers them. Each is `pgrep`-guarded, so only
/// running browsers are queried. A fork that strips the scripting dictionary won't enumerate.
struct BrowserService {
  private let maxRows = 12

  /// Chromium browsers that keep Chrome's `windows/tabs/activeTabIndex/url/title` dictionary.
  /// `name` is both the JXA application name and the `pgrep -x` process name.
  private struct Chromium { let name: String; let bundleID: String }
  private static let chromiumBrowsers = [
    Chromium(name: "Google Chrome", bundleID: "com.google.Chrome"),
    Chromium(name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary"),
    Chromium(name: "Brave Browser", bundleID: "com.brave.Browser"),
    Chromium(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
    Chromium(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
    Chromium(name: "Opera", bundleID: "com.operasoftware.Opera"),
    Chromium(name: "Arc", bundleID: "company.thebrowser.Browser"),
    Chromium(name: "Chromium", bundleID: "org.chromium.Chromium"),
    Chromium(name: "Helium", bundleID: "net.imput.helium"),
  ]

  func searchTabs(query: String) async throws -> [AppSearchResult] {
    var tabs: [BrowserTabReference] = []
    var firstError: Error?
    // A non-running browser returns [] (no error); a running-but-blocked one throws so the
    // panel can surface the Automation-permission hint. Only fail if nothing was readable.
    do { tabs += try await safariTabs() } catch { firstError = firstError ?? error }
    for browser in Self.chromiumBrowsers {
      do { tabs += try await chromiumTabs(browser) } catch { firstError = firstError ?? error }
    }
    if tabs.isEmpty, let firstError { throw firstError }

    let trimmed = query.trimmed

    let scored: [(BrowserTabReference, Int)] = tabs.compactMap { tab in
      guard let score = score(tab, query: trimmed) else { return nil }
      return (tab, score)
    }

    return scored.sorted { lhs, rhs in
      if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
      if lhs.0.isActive != rhs.0.isActive { return lhs.0.isActive && !rhs.0.isActive }
      return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
    }
    .prefix(maxRows)
    .map { tab, _ in result(for: tab) }
  }

  func render(_ reference: BrowserTabReference) -> String {
    var lines = [
      "## Browser — \(displayTitle(reference))",
      "Source: open \(reference.browser) tab",
      "Browser: \(reference.browser)",
      "Bundle ID: \(reference.bundleID.isEmpty ? "unknown" : reference.bundleID)",
      "Title: \(reference.title.isEmpty ? "(untitled)" : reference.title)",
      "URL: \(reference.url)",
    ]

    if let components = URLComponents(string: reference.url) {
      if let scheme = components.scheme { lines.append("Scheme: \(scheme)") }
      if let host = components.host { lines.append("Host: \(host)") }
      if !components.path.isEmpty { lines.append("Path: \(components.path)") }
      if let query = components.percentEncodedQuery, !query.isEmpty { lines.append("Query: \(query)") }
      if let fragment = components.percentEncodedFragment, !fragment.isEmpty { lines.append("Fragment: \(fragment)") }
    }

    if reference.windowIndex > 0 { lines.append("Window: \(reference.windowIndex)") }
    if reference.tabIndex > 0 { lines.append("Tab: \(reference.tabIndex)") }
    lines.append("Active when captured: \(reference.isActive ? "yes" : "no")")
    if !reference.capturedAt.isEmpty { lines.append("Captured: \(reference.capturedAt)") }
    lines.append("")
    lines.append("Use the URL/title as the canonical browser-tab reference. If the receiving harness has web access, fetch the URL for page content; otherwise ask for the page text, selected excerpt, or screenshot.")
    return lines.joined(separator: "\n")
  }

  // MARK: - Safari

  /// Both browser scripts emit the same JSON tab shape, so they share one decoder type.
  private struct DecodedTab: Decodable {
    let title: String
    let url: String
    let windowIndex: Int
    let tabIndex: Int
    let isActive: Bool
  }

  private func safariTabs() async throws -> [BrowserTabReference] {
    let running = try? await Shell.run(["pgrep", "-x", "Safari"])
    guard running?.status == 0 else { return [] }

    let result = try await Shell.run(["osascript", "-l", "JavaScript", "-e", Self.safariTabsScript])
    guard result.status == 0 else { throw browserError(result, app: "Safari") }

    let text = result.stdout.trimmed
    guard !text.isEmpty else { return [] }
    let decoded = try JSONDecoder().decode([DecodedTab].self, from: Data(text.utf8))
    let captured = ISO8601DateFormatter().string(from: Date())
    return decoded.map {
      BrowserTabReference(
        browser: "Safari",
        bundleID: "com.apple.Safari",
        title: $0.title,
        url: $0.url,
        windowIndex: $0.windowIndex,
        tabIndex: $0.tabIndex,
        isActive: $0.isActive,
        capturedAt: captured)
    }
  }

  private static let safariTabsScript = """
  function run() {
    const safari = Application('Safari');
    const windows = safari.windows();
    const tabs = [];

    for (let wi = 0; wi < windows.length; wi++) {
      const win = windows[wi];
      let activeTitle = '';
      let activeURL = '';
      try {
        const current = win.currentTab();
        activeTitle = current.name() || '';
        activeURL = current.url() || '';
      } catch (e) {}

      const winTabs = win.tabs();
      for (let ti = 0; ti < winTabs.length; ti++) {
        const tab = winTabs[ti];
        let title = '';
        let url = '';
        try { title = tab.name() || ''; } catch (e) {}
        try { url = tab.url() || ''; } catch (e) {}
        if (!title && !url) continue;
        tabs.push({
          title: title,
          url: url,
          windowIndex: wi + 1,
          tabIndex: ti + 1,
          isActive: title === activeTitle && url === activeURL
        });
      }
    }

    return JSON.stringify(tabs);
  }
  """

  // MARK: - Chromium (Chrome, Brave, Edge, Vivaldi, Opera, Arc, …)

  private func chromiumTabs(_ browser: Chromium) async throws -> [BrowserTabReference] {
    let running = try? await Shell.run(["pgrep", "-x", browser.name])
    guard running?.status == 0 else { return [] }

    let result = try await Shell.run(["osascript", "-l", "JavaScript", "-e", Self.chromiumScript(app: browser.name)])
    guard result.status == 0 else { throw browserError(result, app: browser.name) }

    let text = result.stdout.trimmed
    guard !text.isEmpty else { return [] }
    let decoded = try JSONDecoder().decode([DecodedTab].self, from: Data(text.utf8))
    let captured = ISO8601DateFormatter().string(from: Date())
    return decoded.map {
      BrowserTabReference(
        browser: browser.name,
        bundleID: browser.bundleID,
        title: $0.title,
        url: $0.url,
        windowIndex: $0.windowIndex,
        tabIndex: $0.tabIndex,
        isActive: $0.isActive,
        capturedAt: captured)
    }
  }

  // Every Chromium browser exposes the same tab URL/title/activeTabIndex dictionary — no extension
  // needed. `activeTabIndex` is 1-based, matching the indices we emit. The app name is interpolated
  // from the fixed `chromiumBrowsers` list (no injection surface).
  private static func chromiumScript(app: String) -> String {
    """
    function run() {
      const app = Application('\(app)');
      const windows = app.windows();
      const tabs = [];

      for (let wi = 0; wi < windows.length; wi++) {
        const win = windows[wi];
        let activeIndex = -1;
        try { activeIndex = win.activeTabIndex(); } catch (e) {}

        const winTabs = win.tabs();
        for (let ti = 0; ti < winTabs.length; ti++) {
          const tab = winTabs[ti];
          let title = '';
          let url = '';
          try { title = tab.title() || ''; } catch (e) {}
          try { url = tab.url() || ''; } catch (e) {}
          if (!title && !url) continue;
          tabs.push({
            title: title,
            url: url,
            windowIndex: wi + 1,
            tabIndex: ti + 1,
            isActive: ti + 1 === activeIndex
          });
        }
      }

      return JSON.stringify(tabs);
    }
    """
  }

  private func browserError(_ result: Shell.Result, app: String) -> AppSearchError {
    let text = result.diagnostic
    if text.contains("-1743") || text.localizedCaseInsensitiveContains("not authorized") {
      return .message("Allow Composer to control \(app) in System Settings → Privacy & Security → Automation.")
    }
    if text.localizedCaseInsensitiveContains("execution error") {
      return .message(String(text.prefix(160)))
    }
    return .message(UserFacingError.commandFailure(command: "Reading \(app) tabs", result: result))
  }

  // MARK: - Result shaping

  private func result(for tab: BrowserTabReference) -> AppSearchResult {
    let title = displayTitle(tab)
    let host = tab.host.isEmpty ? tab.url : tab.host
    var bits = [host, tab.browser, "Window \(tab.windowIndex), Tab \(tab.tabIndex)"]
    if tab.isActive { bits.append("active") }
    return AppSearchResult(
      id: "\(tab.bundleID):\(tab.windowIndex):\(tab.tabIndex):\(tab.url)",
      title: title,
      subtitle: bits.joined(separator: " · "),
      selection: .browser(tab))
  }

  private func score(_ tab: BrowserTabReference, query: String) -> Int? {
    guard !query.isEmpty else { return 1_000 + (tab.isActive ? 200 : 0) - tab.windowIndex * 10 - tab.tabIndex }
    let title = fuzzyScore(tab.title, query: query).map { $0 + 500 }
    let host = fuzzyScore(tab.host, query: query).map { $0 + 250 }
    let url = fuzzyScore(tab.url, query: query)
    return [title, host, url].compactMap { $0 }.max()
  }

  private func fuzzyScore(_ text: String, query: String) -> Int? {
    let haystack = Array(text.lowercased())
    let needle = Array(query.lowercased().filter { !$0.isWhitespace })
    guard !haystack.isEmpty, !needle.isEmpty else { return nil }

    let textString = String(haystack)
    let queryString = String(needle)
    if textString == queryString { return 10_000 - haystack.count }
    if textString.hasPrefix(queryString) { return 8_500 - haystack.count }
    if let range = textString.range(of: queryString) {
      let distance = textString.distance(from: textString.startIndex, to: range.lowerBound)
      return 7_000 - distance * 8 - haystack.count
    }

    var cursor = 0
    var last = -1
    var gapPenalty = 0
    var streak = 0
    var bestStreak = 0
    for ch in needle {
      var found: Int?
      while cursor < haystack.count {
        if haystack[cursor] == ch { found = cursor; cursor += 1; break }
        cursor += 1
      }
      guard let index = found else { return nil }
      if index == last + 1 {
        streak += 1
      } else {
        gapPenalty += max(0, index - last - 1)
        streak = 1
      }
      bestStreak = max(bestStreak, streak)
      last = index
    }
    return 4_500 + bestStreak * 70 - gapPenalty * 14 - haystack.count
  }
}

private func displayTitle(_ reference: BrowserTabReference) -> String {
  let title = reference.title.trimmed
  if !title.isEmpty { return title }
  if !reference.host.isEmpty { return reference.host }
  return reference.url.isEmpty ? "Browser tab" : reference.url
}
