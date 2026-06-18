import AppKit

/// Expands the note's `@mentions` into a self-contained block of text ready to paste into
/// a coding harness. The note body stays first; resolved context is appended as labelled
/// sections. Resolved app chips are fetched live and inlined; unresolved ones fall back
/// to connector-specific instructions.
enum SelfContainedRenderer {
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
    return await withTaskGroup(of: (Int, String).self) { group in
      for (index, entry) in tokens.enumerated() {
        group.addTask { (index, await section(for: entry)) }
      }
      var collected: [(Int, String)] = []
      for await result in group { collected.append(result) }
      return collected.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.isEmpty }
    }
  }

  private static func section(for entry: (token: String, appID: String, selection: AppSelection?)) async -> String {
    guard let connector = AppConnectorRegistry.connector(for: entry.appID) else { return "" }
    return await connector.render(selection: entry.selection)
  }
}
