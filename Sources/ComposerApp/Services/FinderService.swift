import Foundation

/// Local file/folder connector powered by `fd` with an in-process fuzzy scoring pass.
struct FinderService {
  private let maxSearchRows = 10
  private let maxExactRows = 180
  private let maxFuzzyRows = 520

  func search(_ query: String) async throws -> [AppSearchResult] {
    let trimmed = query.trimmed
    guard trimmed.count >= 2 else { return [] }

    var paths: [String] = []
    if let direct = existingExpandedPath(trimmed) { paths.append(direct) }

    if let fd = await fdBinary() {
      let includeHidden = trimmed.hasPrefix(".")
      async let exact = fdMatches(fd, pattern: trimmed, fixed: true, limit: maxExactRows, includeHidden: includeHidden)
      // An evicted iCloud file exists on disk only as a hidden ".name.icloud" placeholder, which
      // the normal (non-hidden) pass never sees — sweep just the iCloud root with --hidden so a
      // not-yet-downloaded file is still findable by name.
      async let cloudPlaceholders = iCloudPlaceholderMatches(fd, query: trimmed, includeHiddenAlready: includeHidden)
      if let fuzzy = fuzzyRegexPattern(for: trimmed) {
        async let fuzzyMatches = fdMatches(fd, pattern: fuzzy, fixed: false, limit: maxFuzzyRows, includeHidden: includeHidden)
        let (exactPaths, fuzzyPaths) = try await (exact, fuzzyMatches)
        paths.append(contentsOf: exactPaths)
        paths.append(contentsOf: fuzzyPaths)
      } else {
        paths.append(contentsOf: try await exact)
      }
      paths.append(contentsOf: await cloudPlaceholders)
    } else {
      paths.append(contentsOf: try await findFallback(trimmed, limit: maxExactRows))
    }

    var seen = Set<String>()
    let hits = paths.compactMap { raw -> SearchHit? in
      let path = URL(fileURLWithPath: raw).standardizedFileURL.path
      guard !seen.contains(path) else { return nil }
      seen.insert(path)
      return hit(for: path, query: trimmed)
    }

    return hits.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.result.title.localizedCaseInsensitiveCompare(rhs.result.title) == .orderedAscending
    }
    .prefix(maxSearchRows)
    .map(\.result)
  }

  func render(_ reference: FinderReference) async -> String {
    await Task.detached(priority: .userInitiated) {
      Self.renderSync(reference)
    }.value
  }

  // MARK: - Search

  private struct SearchHit {
    let score: Int
    let result: AppSearchResult
  }

  private func hit(for path: String, query: String) -> SearchHit? {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }

    let url = URL(fileURLWithPath: path)
    let resultPath = logicalPathForICloudPlaceholder(path) ?? path
    let title = displayName(url)
    let isDirectPath = existingExpandedPath(query).map { URL(fileURLWithPath: $0).standardizedFileURL.path == path } ?? false
    let nameScore = fuzzyScore(title, query: query)
    let pathScore = fuzzyScore(abbreviatedPath(resultPath), query: query).map { max(0, $0 - 900) }
    guard let baseScore = [isDirectPath ? 20_000 : nil, nameScore, pathScore, path.localizedCaseInsensitiveContains(query) ? 3_000 : nil].compactMap({ $0 }).max() else {
      return nil
    }
    let score = baseScore + pathScoreAdjustment(for: path)

    let kind = isDirectory.boolValue ? "Folder" : "File"
    let subtitle = [kind, abbreviatedPath(resultPath), lightMetadata(for: url)].filter { !$0.isEmpty }.joined(separator: " · ")
    return SearchHit(
      score: score,
      result: AppSearchResult(
        id: resultPath,
        title: title,
        subtitle: subtitle,
        selection: .finder(FinderReference(path: resultPath, isDirectory: isDirectory.boolValue))))
  }

  private func fdBinary() async -> String? {
    guard let result = try? await Shell.run(["sh", "-lc", "command -v fd || command -v fdfind || true"]),
          result.status == 0 else { return nil }
    return result.stdout
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
      .first
  }

  private func iCloudPlaceholderMatches(_ fd: String, query: String, includeHiddenAlready: Bool) async -> [String] {
    guard !includeHiddenAlready else { return [] }
    let root = "\(NSHomeDirectory())/Library/Mobile Documents/com~apple~CloudDocs"
    guard FileManager.default.fileExists(atPath: root) else { return [] }
    // The query matches the placeholder's full path (".report.pdf.icloud" contains "report"), so
    // the plain fixed-string pattern is enough. Best-effort: a failure here must not sink the
    // primary search.
    return (try? await fdMatches(fd, pattern: query, fixed: true, limit: maxExactRows,
                                 includeHidden: true, roots: [root])) ?? []
  }

  private func fdMatches(_ fd: String, pattern: String, fixed: Bool, limit: Int, includeHidden: Bool,
                         roots: [String]? = nil) async throws -> [String] {
    var args = [
      fd,
      "--full-path",
      "--ignore-case",
      "--color", "never",
      "--max-results", "\(limit)",
      "--exclude", ".git",
      "--exclude", ".build",
      "--exclude", ".cache",
      "--exclude", ".Trash",
      "--exclude", "node_modules",
      "--exclude", "DerivedData",
      "--exclude", "Library",
      "--exclude", "*.photoslibrary",
      "--exclude", "*.movpkg",
    ]
    if includeHidden { args.append("--hidden") }
    if fixed { args.append("--fixed-strings") }
    args.append("--")
    args.append(pattern)
    args.append(contentsOf: roots ?? searchRoots())

    let result = try await Shell.run(args)
    guard result.status == 0 else {
      throw AppSearchError.message(UserFacingError.commandFailure(command: "Finder search", result: result))
    }
    return result.stdout
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
  }

  private func findFallback(_ query: String, limit: Int) async throws -> [String] {
    let escaped = shellQuote("*\(query)*")
    let roots = searchRoots().map(shellQuote).joined(separator: " ")
    let command = "/usr/bin/find \(roots) -maxdepth 8 \\( -name .git -o -name node_modules -o -name Library -o -name .build -o -name .cache \\) -prune -o -iname \(escaped) -print 2>/dev/null | /usr/bin/head -n \(limit)"
    let result = try await Shell.run(["sh", "-lc", command])
    guard result.status == 0 else {
      throw AppSearchError.message(UserFacingError.commandFailure(command: "Finder fallback search", result: result))
    }
    return result.stdout
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
  }

  /// Convert a loose query into the same broad candidate shape a fuzzy finder would use:
  /// `composer canvas` → `c.*o.*m.*p.*o.*s.*e.*r.*c.*a.*n.*v.*a.*s`.
  /// We only do this for 3+ useful characters; for 2-char queries an fd fuzzy regex is
  /// too broad, so exact path/name matching stays much cleaner.
  private func fuzzyRegexPattern(for query: String) -> String? {
    let useful = query.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    guard useful.count >= 3 else { return nil }
    return useful.prefix(48)
      .map { NSRegularExpression.escapedPattern(for: String($0)) }
      .joined(separator: ".*")
  }

  private func searchRoots() -> [String] {
    let home = NSHomeDirectory()
    let candidates = [
      "\(home)/www",
      "\(home)/Developer",
      "\(home)/Projects",
      "\(home)/Desktop",
      "\(home)/Documents",
      "\(home)/Downloads",
      "\(home)/Library/Mobile Documents/com~apple~CloudDocs",
      "\(home)/Library/CloudStorage",
      home,
    ]
    var seen = Set<String>()
    return candidates.compactMap { path in
      let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
      guard !seen.contains(standardized), FileManager.default.fileExists(atPath: standardized) else { return nil }
      seen.insert(standardized)
      return standardized
    }
  }

  private func pathScoreAdjustment(for path: String) -> Int {
    let home = NSHomeDirectory()
    if path.hasPrefix("\(home)/www/") { return 1_400 }
    if path.hasPrefix("\(home)/Developer/") || path.hasPrefix("\(home)/Projects/") { return 1_100 }
    if path.hasPrefix("\(home)/Desktop/") || path.hasPrefix("\(home)/Documents/") { return 700 }
    if path.hasPrefix("\(home)/Downloads/") { return 450 }
    if path.contains("/Movies/") || path.contains("/Pictures/") || path.contains("/Music/") { return -1_200 }
    if path.contains("/.codex/.tmp/") || path.contains("/.claude/") { return -1_800 }
    return 0
  }

  private func existingExpandedPath(_ query: String) -> String? {
    let path: String
    if query == "~" {
      path = NSHomeDirectory()
    } else if query.hasPrefix("~/") {
      path = NSHomeDirectory() + String(query.dropFirst())
    } else {
      path = query
    }
    guard path.hasPrefix("/") else { return nil }
    return FileManager.default.fileExists(atPath: path) ? path : nil
  }

  private func fuzzyScore(_ text: String, query: String) -> Int? {
    let haystack = Array(text.lowercased())
    let needle = Array(query.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" })
    guard !haystack.isEmpty, !needle.isEmpty else { return nil }

    let textString = String(haystack)
    let queryString = String(needle)
    if textString == queryString { return 12_000 - haystack.count }
    if textString.hasPrefix(queryString) { return 10_000 - haystack.count }
    if let range = textString.range(of: queryString) {
      let distance = textString.distance(from: textString.startIndex, to: range.lowerBound)
      return 8_000 - (distance * 12) - haystack.count
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

    return 5_500 + (bestStreak * 80) - (gapPenalty * 18) - haystack.count
  }

  private func lightMetadata(for url: URL) -> String {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]) else { return "" }
    var bits: [String] = []
    if values.isDirectory != true, let size = values.fileSize { bits.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
    if let modified = values.contentModificationDate {
      bits.append("modified " + DateFormatter.localizedString(from: modified, dateStyle: .medium, timeStyle: .short))
    }
    return bits.joined(separator: " · ")
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  // MARK: - Render

  private static let maxFileBytes = 240_000
  private static let maxFileChars = 24_000
  private static let maxFolderEntries = 90
  private static let maxFolderDepth = 3

  private static func renderSync(_ reference: FinderReference) -> String {
    let url = URL(fileURLWithPath: reference.path).standardizedFileURL
    let path = url.path
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      if let placeholder = iCloudPlaceholderURL(forLogicalURL: url),
         FileManager.default.fileExists(atPath: placeholder.path) {
        _ = try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
        return "## Finder — \(displayName(url))\nPath: \(path)\nStatus: Downloading from iCloud — try again in a moment."
      }
      return "## Finder — \(displayName(url))\nPath: \(path)\nStatus: Not found on this Mac."
    }

    var lines = [
      "## Finder — \(displayName(url))",
      "Path: \(path)",
      "File URL: \(url.absoluteString)",
      "Kind: \(isDirectory.boolValue ? "Folder" : "File")",
    ]
    lines.append(contentsOf: metadataLines(for: url, isDirectory: isDirectory.boolValue))

    if isDirectory.boolValue {
      lines.append(contentsOf: folderListing(for: url))
    } else {
      lines.append(contentsOf: fileContents(for: url))
    }

    return lines.joined(separator: "\n")
  }

  private static func metadataLines(for url: URL, isDirectory: Bool) -> [String] {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .typeIdentifierKey]) else { return [] }
    var lines: [String] = []
    if !isDirectory, let size = values.fileSize { lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))") }
    if let type = values.typeIdentifier { lines.append("UTI: \(type)") }
    if let created = values.creationDate { lines.append("Created: \(DateFormatter.localizedString(from: created, dateStyle: .medium, timeStyle: .short))") }
    if let modified = values.contentModificationDate { lines.append("Modified: \(DateFormatter.localizedString(from: modified, dateStyle: .medium, timeStyle: .short))") }
    return lines
  }

  private static func folderListing(for url: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return ["", "### Folder Listing", "macOS did not provide a directory enumerator, so Composer could not list this folder’s contents."]
    }

    let baseComponents = url.standardizedFileURL.pathComponents.count
    var rows: [String] = []
    var truncated = false

    for case let child as URL in enumerator {
      let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
      let isDir = values?.isDirectory == true
      let depth = max(1, child.standardizedFileURL.pathComponents.count - baseComponents)
      if depth > maxFolderDepth {
        if isDir { enumerator.skipDescendants() }
        continue
      }
      if rows.count >= maxFolderEntries {
        truncated = true
        if isDir { enumerator.skipDescendants() }
        break
      }
      let indent = String(repeating: "  ", count: depth - 1)
      rows.append("\(indent)- \(child.lastPathComponent)\(isDir ? "/" : "")")
    }

    if rows.isEmpty { rows.append("(empty folder)") }
    if truncated { rows.append("…(truncated)") }
    return ["", "### Folder Listing", "```text"] + rows + ["```"]
  }

  private static func fileContents(for url: URL) -> [String] {
    switch readTextPrefix(url) {
    case let .text(read):
      let language = languageHint(forExtension: url.pathExtension)
      let fence = read.text.contains("```") ? "~~~~" : "```"
      let suffix = read.truncated ? "\n\n…(truncated)" : ""
      return ["", "### File Contents", "\(fence)\(language)", read.text + suffix, fence]
    case let .unavailable(reason):
      return ["", "Content not included: \(reason)"]
    }
  }

  private enum FileTextRead {
    case text((text: String, truncated: Bool))
    case unavailable(String)
  }

  private static func readTextPrefix(_ url: URL) -> FileTextRead {
    if let reason = iCloudDownloadReason(for: url) {
      return .unavailable(reason)
    }

    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      return .unavailable(UserFacingError.message(for: error, while: "Opening \(url.path)"))
    }
    defer { try? handle.close() }
    let data: Data
    do {
      data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
    } catch {
      return .unavailable(UserFacingError.message(for: error, while: "Reading \(url.path)"))
    }
    guard !data.isEmpty else { return .text(("", false)) }
    let truncatedByBytes = data.count > maxFileBytes
    let prefix = Data(data.prefix(maxFileBytes))
    if prefix.prefix(4096).contains(0) {
      return .unavailable("The file contains binary data, which Composer does not copy as text.")
    }

    let decoded = String(data: prefix, encoding: .utf8)
      ?? String(data: prefix, encoding: .utf16)
      ?? String(data: prefix, encoding: .isoLatin1)
    guard var text = decoded else {
      return .unavailable("The file is not valid UTF-8, UTF-16, or ISO-8859-1 text.")
    }

    let truncatedByChars = text.count > maxFileChars
    if truncatedByChars { text = String(text.prefix(maxFileChars)) }
    return .text((text, truncatedByBytes || truncatedByChars))
  }

  private static func iCloudDownloadReason(for url: URL) -> String? {
    if isICloudPlaceholder(url) {
      _ = try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      return "Downloading from iCloud — try again in a moment."
    }

    guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
          values.isUbiquitousItem == true,
          let status = values.ubiquitousItemDownloadingStatus,
          status != .current else { return nil }
    _ = try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    return "Downloading from iCloud — try again in a moment."
  }

  private static func languageHint(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "swift": return "swift"
    case "js", "mjs", "cjs": return "javascript"
    case "ts", "tsx": return "typescript"
    case "jsx": return "jsx"
    case "json": return "json"
    case "md", "markdown": return "markdown"
    case "html", "htm": return "html"
    case "css": return "css"
    case "py": return "python"
    case "rb": return "ruby"
    case "go": return "go"
    case "rs": return "rust"
    case "sh", "bash", "zsh": return "bash"
    case "yml", "yaml": return "yaml"
    case "xml": return "xml"
    default: return ""
    }
  }
}

private func displayName(_ url: URL) -> String {
  let name = url.lastPathComponent
  if let logicalName = logicalNameForICloudPlaceholder(name) { return logicalName }
  return name.isEmpty ? url.path : name
}

private func abbreviatedPath(_ path: String) -> String {
  let path = logicalPathForICloudPlaceholder(path) ?? path
  let home = NSHomeDirectory()
  let iCloudDrive = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
  if path == iCloudDrive { return "iCloud Drive" }
  if path.hasPrefix(iCloudDrive + "/") { return "iCloud Drive/" + path.dropFirst(iCloudDrive.count + 1) }
  if path == home { return "~" }
  if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
  return path
}

private func isICloudPlaceholder(_ url: URL) -> Bool {
  logicalNameForICloudPlaceholder(url.lastPathComponent) != nil
}

private func logicalNameForICloudPlaceholder(_ name: String) -> String? {
  let suffix = ".icloud"
  guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > suffix.count + 1 else { return nil }
  return String(name.dropFirst().dropLast(suffix.count))
}

private func logicalPathForICloudPlaceholder(_ path: String) -> String? {
  let url = URL(fileURLWithPath: path)
  guard let name = logicalNameForICloudPlaceholder(url.lastPathComponent) else { return nil }
  return url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL.path
}

private func iCloudPlaceholderURL(forLogicalURL url: URL) -> URL? {
  let name = url.lastPathComponent
  guard !name.isEmpty else { return nil }
  return url.deletingLastPathComponent().appendingPathComponent(".\(name).icloud")
}
