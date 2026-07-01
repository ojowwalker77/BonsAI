import Foundation

/// A coding agent that can be taught the BonsAI canvas API (`127.0.0.1:7337`). Each case maps to a
/// bundled doc in `Resources/AgentSkills/` and the on-disk location that agent reads instructions from.
enum AgentSkillTarget: String, CaseIterable, Identifiable {
  case claudeCode
  case codex
  case cursor

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex CLI"
    case .cursor: "Cursor"
    }
  }

  var symbol: String {
    switch self {
    case .claudeCode: "sparkle"
    case .codex: "terminal"
    case .cursor: "cursorarrow.rays"
    }
  }

  /// The directory whose presence implies the tool is installed, so a fresh BonsAI install only
  /// offers to wire up agents the user actually has — not every dotfile under the sun.
  fileprivate var markerDirectory: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    switch self {
    case .claudeCode: return home.appendingPathComponent(".claude", isDirectory: true)
    case .codex: return home.appendingPathComponent(".codex", isDirectory: true)
    case .cursor: return home.appendingPathComponent(".cursor", isDirectory: true)
    }
  }

  var isDetected: Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: markerDirectory.path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }

  fileprivate var resourceName: String {
    switch self {
    case .claudeCode: return "claude-code-SKILL"
    case .codex: return "codex-AGENTS"
    case .cursor: return "cursor-bonsai-board"
    }
  }

  fileprivate var resourceExtension: String {
    switch self {
    case .claudeCode: return "md"
    case .codex: return "md"
    case .cursor: return "mdc"
    }
  }

  /// Whether `destinationURL` is a file BonsAI owns outright (safe to overwrite) or one shared with
  /// the user's own content (must be merged — see `AgentSkillsInstaller.mergeMarkedSection`).
  fileprivate var ownsDestinationFile: Bool {
    switch self {
    case .claudeCode, .cursor: return true
    case .codex: return false
    }
  }

  fileprivate var destinationURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    switch self {
    case .claudeCode:
      return home.appendingPathComponent(".claude/skills/bonsai-board/SKILL.md")
    case .codex:
      // AGENTS.md is Codex's shared instructions file — it may already hold the user's own
      // project notes, so the installer merges a marked section instead of replacing it.
      return home.appendingPathComponent(".codex/AGENTS.md")
    case .cursor:
      return home.appendingPathComponent(".cursor/rules/bonsai-board.mdc")
    }
  }

  /// Whether the skill is already on disk at the expected location for this agent.
  var isInstalled: Bool {
    FileManager.default.fileExists(atPath: destinationURL.path)
  }
}

enum AgentSkillsInstallerError: LocalizedError {
  case missingBundledResource(AgentSkillTarget)

  var errorDescription: String? {
    switch self {
    case .missingBundledResource(let target):
      return "BonsAI's bundled skill file for \(target.displayName) is missing."
    }
  }
}

/// Installs the BonsAI canvas-API doc into the config locations coding agents (Claude Code, Codex
/// CLI, Cursor) read on their own. This is the cross-agent counterpart to the Claude Code-only
/// `bonsai-board` skill: any agent that can read a local file and run `curl` can drive the board.
enum AgentSkillsInstaller {
  private static let beginMarker = "<!-- BEGIN BONSAI BOARD SKILL (auto-managed by BonsAI; edits outside the markers are preserved) -->"
  private static let endMarker = "<!-- END BONSAI BOARD SKILL -->"

  static func install(_ target: AgentSkillTarget) throws {
    guard let resourceURL = Bundle.appResources.url(
      forResource: target.resourceName,
      withExtension: target.resourceExtension,
      subdirectory: "AgentSkills"
    ) else {
      throw AgentSkillsInstallerError.missingBundledResource(target)
    }

    let payload = try String(contentsOf: resourceURL, encoding: .utf8)
    let destination = target.destinationURL
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    if target.ownsDestinationFile {
      try payload.write(to: destination, atomically: true, encoding: .utf8)
    } else {
      try mergeMarkedSection(payload, into: destination)
    }
  }

  /// Installs into every detected agent, returning per-target failures (empty on full success).
  @discardableResult
  static func installAllDetected() -> [AgentSkillTarget: Error] {
    var failures: [AgentSkillTarget: Error] = [:]
    for target in AgentSkillTarget.allCases where target.isDetected {
      do { try install(target) } catch { failures[target] = error }
    }
    return failures
  }

  /// Replaces BonsAI's marked section in a shared instructions file (e.g. Codex's `AGENTS.md`)
  /// without touching anything the user wrote outside the markers. `internal` (not `private`) so
  /// `AgentSkillsInstallerTests` can exercise the merge against a throwaway tmp file instead of the
  /// real `destinationURL`, which always points at the user's actual home directory.
  static func mergeMarkedSection(_ payload: String, into destination: URL) throws {
    let section = "\(beginMarker)\n\(payload.trimmingCharacters(in: .newlines))\n\(endMarker)"
    var existing = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""

    if let beginRange = existing.range(of: beginMarker),
       let endRange = existing.range(of: endMarker) {
      existing.replaceSubrange(beginRange.lowerBound..<endRange.upperBound, with: section)
    } else {
      if !existing.isEmpty {
        existing += existing.hasSuffix("\n\n") ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
      }
      existing += section + "\n"
    }
    try existing.write(to: destination, atomically: true, encoding: .utf8)
  }
}
