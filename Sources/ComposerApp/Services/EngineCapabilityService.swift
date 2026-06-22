import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The live availability state behind Composer's local intelligence features. A user preference
/// answers "may I use this?"; this answers the separate, practical question: "can I use it now?".
enum RuntimeAvailability: Equatable, Sendable, Codable {
  case checking
  case available(path: String, version: String?)
  case unavailable(String)

  var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }

  var statusLabel: String {
    switch self {
    case .checking: "Checking…"
    case let .available(_, version): version ?? "Ready"
    case let .unavailable(reason): reason
    }
  }

  var location: String? {
    if case let .available(path, _) = self { return path }
    return nil
  }
}

/// Resolves commands without opening a login shell. Finder-launched apps have a sparse PATH, so
/// this intentionally mirrors Composer's augmented launch environment and checks common CLI homes.
enum CommandLineToolLocator {
  static func executableURL(for engine: HeadlessEngine) -> URL? {
    executableURL(named: engine.rawValue)
  }

  static func executableURL(named command: String) -> URL? {
    let home = NSHomeDirectory()
    let preferredDirectories = [
      "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
      "\(home)/.cargo/bin", "\(home)/.claude/bin",
      "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ]
    let pathDirectories = (Shell.augmentedEnvironment()["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    var checked = Set<String>()
    for directory in preferredDirectories + pathDirectories where checked.insert(directory).inserted {
      let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(command)
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    return nil
  }

  static func detect(_ engine: HeadlessEngine) async -> RuntimeAvailability {
    guard let executable = executableURL(for: engine) else {
      return .unavailable("Not installed")
    }
    let result: Shell.Result
    do {
      result = try await Shell.run([executable.path, "--version"])
    } catch {
      return .unavailable(UserFacingError.message(for: error, while: "Starting \(engine.title)"))
    }
    guard result.status == 0 else {
      return .unavailable(UserFacingError.commandFailure(command: engine.title, result: result))
    }
    let output = [result.stdout, result.stderr]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    let version = output.map { String($0.split(separator: "\n", maxSplits: 1).first ?? "") }
    return .available(path: executable.path, version: version)
  }
}

/// One observable source of truth for Settings, refine actions, and the agent chrome.
@MainActor
final class EngineCapabilityStore: ObservableObject {
  static let shared = EngineCapabilityStore()

  @Published private(set) var cli: [HeadlessEngine: RuntimeAvailability] = [:]
  @Published private(set) var appleIntelligence: RuntimeAvailability = .checking
  private var refreshTask: Task<Void, Never>?
  private static let snapshotKey = "composer.engineCapabilities.v1"

  /// First-ever launch detects and persists; later launches restore that known state and only
  /// re-check when the user explicitly asks (Settings → Recheck), so opening Settings no longer
  /// re-shells `--version` for every engine and flickers "Checking…".
  private init() {
    if !restorePersisted() { refresh() }
  }

  func status(for engine: HeadlessEngine) -> RuntimeAvailability {
    cli[engine] ?? .checking
  }

  func isAvailable(_ engine: HeadlessEngine) -> Bool {
    status(for: engine).isAvailable
  }

  /// Re-detect every engine and persist the result. Wired to the Recheck button.
  func refresh() {
    refreshTask?.cancel()
    cli = Dictionary(uniqueKeysWithValues: HeadlessEngine.allCases.map { ($0, .checking) })
    appleIntelligence = appleIntelligenceAvailability()
    refreshTask = Task { [weak self] in
      let detected = await Task.detached(priority: .utility) {
        var statuses: [HeadlessEngine: RuntimeAvailability] = [:]
        for engine in HeadlessEngine.allCases {
          statuses[engine] = await CommandLineToolLocator.detect(engine)
        }
        return statuses
      }.value
      guard !Task.isCancelled, let self else { return }
      self.cli = detected
      self.persist()
    }
  }

  // MARK: - Known state between launches

  private struct Snapshot: Codable {
    var cli: [String: RuntimeAvailability]
    var appleIntelligence: RuntimeAvailability
  }

  /// Restore the last detected state. Returns false (→ caller runs a first detection) when nothing
  /// is stored yet — i.e. the first-ever launch.
  private func restorePersisted() -> Bool {
    guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey) else { return false }
    let snapshot: Snapshot
    do {
      snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
    } catch {
      UserFacingError.report(error, while: "Reading Composer’s saved runtime status")
      return false
    }
    let restored = snapshot.cli.reduce(into: [HeadlessEngine: RuntimeAvailability]()) { result, pair in
      if let engine = HeadlessEngine(rawValue: pair.key) { result[engine] = pair.value }
    }
    guard !restored.isEmpty else { return false }
    cli = restored
    appleIntelligence = snapshot.appleIntelligence
    return true
  }

  private func persist() {
    let resolved = cli.reduce(into: [String: RuntimeAvailability]()) { result, pair in
      if case .checking = pair.value { return }   // never persist the transient state
      result[pair.key.rawValue] = pair.value
    }
    let snapshot = Snapshot(cli: resolved, appleIntelligence: appleIntelligence)
    do {
      let data = try JSONEncoder().encode(snapshot)
      UserDefaults.standard.set(data, forKey: Self.snapshotKey)
    } catch {
      UserFacingError.report(error, while: "Saving Composer’s runtime status")
    }
  }

  private func appleIntelligenceAvailability() -> RuntimeAvailability {
    guard #available(macOS 26.0, *) else {
      return .unavailable("Requires macOS 26")
    }
    #if canImport(FoundationModels)
    switch SystemLanguageModel.default.availability {
    case .available:
      return .available(path: "On-device", version: nil)
    case .unavailable(.deviceNotEligible):
      return .unavailable("This Mac isn’t eligible")
    case .unavailable(.appleIntelligenceNotEnabled):
      return .unavailable("Turn on Apple Intelligence")
    case .unavailable(.modelNotReady):
      return .unavailable("Model is still preparing")
    @unknown default:
      return .unavailable("macOS reported an unrecognized Apple Intelligence availability state")
    }
    #else
    return .unavailable("Not included in this build")
    #endif
  }
}
