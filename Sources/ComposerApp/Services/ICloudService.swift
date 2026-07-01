import Foundation

/// iCloud Drive connector (`@icloud`). Searches the user's iCloud Drive by filename via Spotlight
/// (`mdfind`, scoped to the CloudDocs container) and reuses `FinderService` to render the chosen file
/// or folder at copy time. `@finder` deliberately excludes `~/Library`, where iCloud Drive's local
/// mirror lives, so this is a distinct connector rather than a Finder search root. The app isn't
/// sandboxed, so the container is read as an ordinary path — no entitlement required.
struct ICloudService {
  private let maxRows = 10

  /// iCloud Drive's local mirror, or nil when the user hasn't turned iCloud Drive on.
  static var container: URL? {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func search(_ query: String) async throws -> [AppSearchResult] {
    let trimmed = query.trimmed
    guard trimmed.count >= 2 else { return [] }
    guard let root = Self.container else {
      throw AppSearchError.message(
        "iCloud Drive isn’t set up on this Mac — turn it on in System Settings → [your name] → iCloud → iCloud Drive.")
    }
    let needle = spotlightNeedle(trimmed)
    guard !needle.isEmpty else { return [] }

    // Spotlight indexes iCloud Drive (including files not yet downloaded), so a filename match works
    // even for placeholders. `cd` = case- and diacritic-insensitive.
    let result = try await Shell.run([
      "mdfind", "-onlyin", root.path, "kMDItemFSName == '*\(needle)*'cd",
    ])
    guard result.status == 0 else {
      throw AppSearchError.message(UserFacingError.commandFailure(command: "iCloud Drive search", result: result))
    }
    let paths = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

    var seen = Set<String>()
    let hits = paths.compactMap { raw -> (score: Int, result: AppSearchResult)? in
      let path = URL(fileURLWithPath: raw).standardizedFileURL.path
      guard !seen.contains(path), !Self.isNoise(path) else { return nil }
      seen.insert(path)
      return hit(for: path, query: trimmed, root: root)
    }
    return hits
      .sorted { lhs, rhs in
        lhs.score != rhs.score
          ? lhs.score > rhs.score
          : lhs.result.title.localizedCaseInsensitiveCompare(rhs.result.title) == .orderedAscending
      }
      .prefix(maxRows)
      .map(\.result)
  }

  func render(_ reference: FinderReference) async -> String {
    await FinderService().render(reference, heading: "iCloud Drive")
  }

  // MARK: - Helpers

  /// Dev/system cruft that syncs into iCloud Drive when a code folder (or Desktop & Documents) is
  /// stored there — the same noise `@finder` excludes. Keeps results to real documents.
  private static let excludedComponents: Set<String> = [
    "node_modules", ".git", ".build", ".cache", ".Trash", "DerivedData", ".next", "Pods", ".venv",
  ]

  private static func isNoise(_ path: String) -> Bool {
    for component in path.split(separator: "/") {
      if excludedComponents.contains(String(component)) { return true }
      if component.hasSuffix(".photoslibrary") || component.hasSuffix(".movpkg") { return true }
    }
    return false
  }

  private func hit(for path: String, query: String, root: URL) -> (score: Int, result: AppSearchResult)? {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    let relative = relativePath(path, under: root.path)
    let subtitle = [(isDirectory.boolValue ? "Folder" : "File"), relative]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    return (
      score: score(name: name, query: query),
      result: AppSearchResult(
        id: path,
        title: name.isEmpty ? path : name,
        subtitle: subtitle,
        selection: .icloud(FinderReference(path: path, isDirectory: isDirectory.boolValue))))
  }

  /// mdfind already filtered to a filename match, so this just ranks: exact name > prefix > earlier
  /// substring, shorter names first. Never nil — an unranked hit still shows (with a small base).
  private func score(name: String, query: String) -> Int {
    let haystack = name.lowercased()
    let needle = query.lowercased().filter { !$0.isWhitespace }
    guard !needle.isEmpty else { return 1_000 }
    if haystack == needle { return 10_000 - haystack.count }
    if haystack.hasPrefix(needle) { return 8_000 - haystack.count }
    if let range = haystack.range(of: needle) {
      return 6_000 - haystack.distance(from: haystack.startIndex, to: range.lowerBound) * 8 - haystack.count
    }
    return 1_000
  }

  /// `…/CloudDocs/Screens/shot.png` → `Screens/shot.png`; the container itself → its name.
  private func relativePath(_ path: String, under root: String) -> String {
    guard path.hasPrefix(root) else { return path }
    let tail = String(path.dropFirst(root.count)).drop { $0 == "/" }
    return tail.isEmpty ? "iCloud Drive" : String(tail)
  }

  /// Keep only characters safe to drop into an `mdfind` single-quoted literal, so a query can't break
  /// the query expression. Ranking on the raw query still handles the full text.
  private func spotlightNeedle(_ query: String) -> String {
    query.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }
      .trimmingCharacters(in: .whitespaces)
  }
}
