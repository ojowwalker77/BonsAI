import AppKit

/// Expands the note's `@mentions` into a self-contained block of text ready to paste into
/// a coding harness. The note body stays first; resolved context is appended as labelled
/// sections. Resolved app chips are fetched live and inlined; unresolved ones fall back
/// to connector-specific instructions.
enum SelfContainedRenderer {
  struct Result {
    let text: String
    /// Connector-specific failures, already phrased for display to the person who clicked Copy.
    let failures: [String]
  }

  static func render(_ plain: String) async -> Result {
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

    let appSections = await appSections(for: AppToken.scan(plain))
    sections.append(contentsOf: appSections.sections)

    if plain.contains("@clipboard"), let clip = clipboard, !clip.isEmpty {
      sections.append("## Clipboard\n\(clip)")
    }

    return Result(text: sections.joined(separator: "\n\n") + "\n", failures: appSections.failures)
  }

  // MARK: App sections (fetched concurrently, emitted in note order)

  private static func appSections(for tokens: [(token: String, appID: String, selection: AppSelection?)]) async -> (sections: [String], failures: [String]) {
    guard !tokens.isEmpty else { return ([], []) }
    return await withTaskGroup(of: (Int, String?, String?).self) { group in
      for (index, entry) in tokens.enumerated() {
        group.addTask {
          guard let connector = AppConnectorRegistry.connector(for: entry.appID) else {
            return (index, nil, "\(entry.appID): Composer does not have a connector for this token.")
          }
          do {
            return (index, try await connector.render(selection: entry.selection), nil)
          } catch {
            let action = "Resolving \(entry.appID)"
            return (index, nil, "\(entry.appID): \(UserFacingError.message(for: error, while: action))")
          }
        }
      }
      var collected: [(Int, String?, String?)] = []
      for await result in group { collected.append(result) }
      let ordered = collected.sorted { $0.0 < $1.0 }
      return (
        ordered.compactMap(\.1).filter { !$0.isEmpty },
        ordered.compactMap(\.2)
      )
    }
  }
}
