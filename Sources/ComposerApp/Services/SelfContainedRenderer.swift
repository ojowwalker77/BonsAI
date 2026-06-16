import AppKit

/// Expands the note's `@mentions` into a self-contained block of text ready to paste into
/// a coding harness. The note body stays first; resolved context is appended as labelled
/// sections. Resolved app chips (a specific Context7 library or GitHub issue/PR) are
/// fetched live and inlined; unresolved ones fall back to an instruction.
enum SelfContainedRenderer {
  /// Cap any single fetched doc so a paste stays reasonable.
  private static let maxDocChars = 12_000

  static func render(_ plain: String) async -> String {
    let body = plain.trimmed
    let clipboard = await MainActor.run { NSPasteboard.general.string(forType: .string)?.trimmed }

    var sections: [String] = []
    if !body.isEmpty { sections.append(body) }

    let skills = MentionCatalog.all
      .filter { $0.kind == .skill && plain.contains($0.id) }
      .map(\.id).sorted()
    if !skills.isEmpty {
      sections.append("## Skills To Use\n" + skills.map { "- \($0.dropFirst())" }.joined(separator: "\n"))
    }

    sections.append(contentsOf: await appSections(for: AppToken.scan(plain)))

    if plain.contains("@clipboard"), let clip = clipboard, !clip.isEmpty {
      sections.append("## Clipboard\n\(clip)")
    }

    return sections.joined(separator: "\n\n") + "\n"
  }

  // MARK: App sections (fetched concurrently, emitted in note order)

  private static func appSections(for tokens: [(token: String, appID: String, selection: AppSelection?)]) async -> [String] {
    guard !tokens.isEmpty else { return [] }
    let context7 = Context7Service()
    let github = GitHubService()

    return await withTaskGroup(of: (Int, String).self) { group in
      for (index, entry) in tokens.enumerated() {
        group.addTask { (index, await section(for: entry, context7: context7, github: github)) }
      }
      var collected: [(Int, String)] = []
      for await result in group { collected.append(result) }
      return collected.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.isEmpty }
    }
  }

  private static func section(
    for entry: (token: String, appID: String, selection: AppSelection?),
    context7: Context7Service, github: GitHubService
  ) async -> String {
    switch entry.selection {
    case .none where entry.appID == "@context7":
      return "## Context7\nUse Context7 to fetch current, version-accurate documentation for the libraries referenced above."
    case .none where entry.appID == "@github":
      return "## GitHub\nFetch and summarize the referenced GitHub issue or PR: state, body, key comments, constraints, and acceptance criteria."

    case let .context7(libraryID, query):
      let docs = (try? await context7.fetchDocs(libraryID: libraryID, query: query)) ?? ""
      let header = "## Context7 — \(libraryID)" + (query.map { " (topic: \($0))" } ?? "")
      guard !docs.isEmpty else {
        return "\(header)\nUse Context7 library `\(libraryID)` to pull current documentation" + (query.map { " on \($0)" } ?? "") + "."
      }
      return "\(header)\n\(truncate(docs))"

    case let .github(kind, url):
      let detail = (try? await github.fetchDetail(url: url, kind: kind)) ?? ""
      let header = "## GitHub — \(AppToken.shortGitHub(url))"
      guard !detail.isEmpty else {
        return "\(header)\nReferenced \(kind == .pr ? "pull request" : "issue"): \(url)"
      }
      return "\(header)\n\(detail)"

    default:
      return ""
    }
  }

  private static func truncate(_ text: String) -> String {
    guard text.count > maxDocChars else { return text }
    return String(text.prefix(maxDocChars)) + "\n\n…(truncated)"
  }
}
