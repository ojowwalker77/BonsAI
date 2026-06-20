import Foundation

/// Xcode connector. Parses `.xcresult` bundles with `xcrun xcresulttool` (the modern
/// `build-results` and `test-results summary` subcommands — the legacy object dump is deprecated)
/// to surface build errors and test failures. Search lists recent bundles under DerivedData or
/// takes a pasted `.xcresult` path; render extracts the errors/failures at copy time.
struct XcodeService {
  private let maxRows = 10

  func search(_ query: String) async throws -> [AppSearchResult] {
    let trimmed = query.trimmed
    if trimmed.hasSuffix(".xcresult") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
      let path = (trimmed as NSString).expandingTildeInPath
      guard FileManager.default.fileExists(atPath: path) else { return [] }
      return [result(forPath: path)]
    }
    let scored: [(ResultBundle, Int)] = discoverResultBundles().compactMap { bundle in
      score(bundle.project, query: trimmed).map { (bundle, $0) }
    }
    return scored
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.modified > $1.0.modified }
      .prefix(maxRows)
      .map { result(forPath: $0.0.path) }
  }

  func render(_ reference: XcodeReference) async -> String {
    let path = reference.resultPath
    let header = "## Xcode — \(projectName(forResult: path))"
    guard FileManager.default.fileExists(atPath: path) else {
      return "\(header)\nResult bundle no longer exists: \(path)"
    }
    async let build = buildResults(path)
    async let tests = testSummary(path)
    let buildText = await build
    let testText = await tests

    var lines = [header, "Bundle: \(abbreviate(path))"]
    if buildText.isEmpty && testText.isEmpty {
      lines.append("")
      lines.append("_No build errors or test failures found._")
    } else {
      if !buildText.isEmpty { lines.append(""); lines.append(buildText) }
      if !testText.isEmpty { lines.append(""); lines.append(testText) }
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - build-results

  private func buildResults(_ path: String) async -> String {
    guard let json = try? await xcresultJSON(["get", "build-results", "--path", path, "--compact"]) else { return "" }
    let errors = (json["errors"] as? [[String: Any]]) ?? []
    let warnings = (json["warnings"] as? [[String: Any]]) ?? []
    guard !errors.isEmpty || !warnings.isEmpty else { return "" }

    var lines = ["### Build"]
    let status = json["status"] as? String ?? ""
    lines.append("\(status.isEmpty ? "" : "Status: \(status) · ")\(errors.count) error(s), \(warnings.count) warning(s)")
    for issue in errors.prefix(15) { lines.append("- ❌ \(issueLine(issue))") }
    for issue in warnings.prefix(8) { lines.append("- ⚠️ \(issueLine(issue))") }
    return lines.joined(separator: "\n")
  }

  private func issueLine(_ issue: [String: Any]) -> String {
    let message = (issue["message"] as? String ?? "").trimmed.replacingOccurrences(of: "\n", with: " ")
    var parts = [message]
    if let location = (issue["sourceURL"] as? String).flatMap(shortSourceURL) {
      parts.append("(\(location))")
    } else if let target = issue["targetName"] as? String, !target.isEmpty {
      parts.append("[\(target)]")
    }
    return parts.joined(separator: " ")
  }

  // MARK: - test-results summary

  private func testSummary(_ path: String) async -> String {
    guard let json = try? await xcresultJSON(["get", "test-results", "summary", "--path", path, "--compact"]) else { return "" }
    let failures = (json["testFailures"] as? [[String: Any]]) ?? []
    let result = json["result"] as? String ?? ""
    let total = json["totalTestCount"] as? Int
    // Suppress the section for build-only bundles (no tests ran, nothing failed).
    guard !failures.isEmpty || (total ?? 0) > 0 else { return "" }

    var lines = ["### Tests"]
    var summary: [String] = []
    if !result.isEmpty { summary.append("Result: \(result)") }
    if let total { summary.append("\(json["passedTests"] as? Int ?? 0)/\(total) passed") }
    if let failed = json["failedTests"] as? Int, failed > 0 { summary.append("\(failed) failed") }
    if !summary.isEmpty { lines.append(summary.joined(separator: " · ")) }
    for failure in failures.prefix(15) {
      let name = failure["testName"] as? String ?? "test"
      let text = (failure["failureText"] as? String ?? "").trimmed.replacingOccurrences(of: "\n", with: " ")
      lines.append(text.isEmpty ? "- ❌ \(name)" : "- ❌ \(name): \(text)")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Discovery

  private struct ResultBundle { let path: String; let project: String; let modified: Date }

  /// Shallow scan of `DerivedData/<project>/Logs/{Test,Build}` for `.xcresult` bundles.
  private func discoverResultBundles() -> [ResultBundle] {
    let derived = "\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData"
    let fm = FileManager.default
    guard let projects = try? fm.contentsOfDirectory(atPath: derived) else { return [] }
    var out: [ResultBundle] = []
    for project in projects where !project.hasPrefix(".") {
      for kind in ["Test", "Build"] {
        let dir = "\(derived)/\(project)/Logs/\(kind)"
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for entry in entries where entry.hasSuffix(".xcresult") {
          let path = "\(dir)/\(entry)"
          let modified = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
          out.append(ResultBundle(path: path, project: cleanProjectName(project), modified: modified))
        }
      }
    }
    return out.sorted { $0.modified > $1.modified }
  }

  // MARK: - Helpers

  private func result(forPath path: String) -> AppSearchResult {
    let kind = path.contains("/Logs/Test/") ? "Test" : (path.contains("/Logs/Build/") ? "Build" : "Result")
    return AppSearchResult(
      id: path,
      title: projectName(forResult: path),
      subtitle: "\(kind) · \(abbreviate(path))",
      selection: .xcode(XcodeReference(resultPath: path)))
  }

  private func xcresultJSON(_ args: [String]) async throws -> [String: Any] {
    let result = try await Shell.run(["xcrun", "xcresulttool"] + args)
    guard result.status == 0 else { throw AppSearchError.message(String(result.stderr.prefix(160))) }
    return (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]) ?? [:]
  }

  /// `MyApp-abcdef0123456789…` (DerivedData) → `MyApp`.
  private func cleanProjectName(_ folder: String) -> String {
    if let range = folder.range(of: "-[a-z0-9]{20,}$", options: .regularExpression) {
      return String(folder[folder.startIndex..<range.lowerBound])
    }
    return folder
  }

  private func projectName(forResult path: String) -> String {
    if let range = path.range(of: "DerivedData/") {
      let after = path[range.upperBound...]
      if let slash = after.firstIndex(of: "/") {
        return cleanProjectName(String(after[after.startIndex..<slash]))
      }
    }
    let name = (path as NSString).lastPathComponent
    return name.hasSuffix(".xcresult") ? String(name.dropLast(".xcresult".count)) : name
  }

  /// `file:///…/File.swift#…StartingLineNumber=9…` → `File.swift:10` (xcresult lines are 0-based).
  private func shortSourceURL(_ url: String) -> String? {
    guard let components = URLComponents(string: url) else { return nil }
    let file = (components.path as NSString).lastPathComponent
    guard !file.isEmpty else { return nil }
    if let fragment = components.fragment, let range = fragment.range(of: "StartingLineNumber=") {
      let digits = fragment[range.upperBound...].prefix { $0.isNumber }
      if let line = Int(digits) { return "\(file):\(line + 1)" }
    }
    return file
  }

  private func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  private func score(_ text: String, query: String) -> Int? {
    let lower = text.lowercased(), q = query.lowercased()
    if q.isEmpty { return 0 }
    if lower.hasPrefix(q) { return 800 - lower.count }
    if lower.contains(q) { return 500 - lower.count }
    return nil
  }
}
