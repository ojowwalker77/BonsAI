import Foundation

/// The model options offered in the Agent dock's per-engine model picker.
///
/// - **OpenCode** has a real list (`opencode models` → `provider/model` lines, grouped by provider),
///   fetched once and cached. It grows as the user logs into more providers.
/// - **Codex** has no model-list command, so the honest set is whatever the user configured
///   (`~/.codex/config.toml`) — surfaced so they can pick it explicitly (the chat otherwise runs with
///   `--ignore-user-config`). Other Codex models are a config edit away.
/// - **Claude** isn't served here — it keeps its fixed `ClaudeModel` tiers (Opus/Sonnet/Haiku).
@MainActor
final class ChatModelCatalog: ObservableObject {
  static let shared = ChatModelCatalog()

  /// `provider/model` ids from `opencode models`, in the CLI's order.
  @Published private(set) var opencodeModels: [String] = []
  private var startedOpenCodeFetch = false

  private init() {}

  /// The picker options for an engine (excluding the implicit "Default"). Claude returns [] — the
  /// dock renders its own `ClaudeModel` control.
  func models(for engine: HeadlessEngine) -> [String] {
    switch engine {
    case .claude: return []
    case .codex: return CodexConfig.defaultModel.map { [$0] } ?? []
    case .opencode: return opencodeModels
    }
  }

  /// `provider/model` grouped by provider (prefix before `/`), preserving first-seen order — for a
  /// sectioned menu. Ids without a `/` fall under an empty provider key.
  var opencodeModelsByProvider: [(provider: String, models: [String])] {
    Self.groupByProvider(opencodeModels)
  }

  /// Pure grouping helper (order-preserving), split out so it's unit-testable without the singleton.
  nonisolated static func groupByProvider(_ ids: [String]) -> [(provider: String, models: [String])] {
    var order: [String] = []
    var groups: [String: [String]] = [:]
    for id in ids {
      let provider = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
      if groups[provider] == nil { order.append(provider) }
      groups[provider, default: []].append(id)
    }
    return order.map { ($0, groups[$0] ?? []) }
  }

  /// Kick off the `opencode models` fetch once. Safe to call repeatedly (e.g. `onAppear`). A fetch
  /// that comes back empty (transient failure) does NOT latch — the next call retries — so a single
  /// hiccup can't strand the picker on "Default" forever.
  func loadOpenCodeModelsIfNeeded() {
    guard !startedOpenCodeFetch, opencodeModels.isEmpty else { return }
    startedOpenCodeFetch = true
    Task { [weak self] in
      let models = await Self.fetchOpenCodeModels()
      guard let self else { return }
      self.startedOpenCodeFetch = false
      if !models.isEmpty { self.opencodeModels = models }
    }
  }

  private static func fetchOpenCodeModels() async -> [String] {
    guard let executable = CommandLineToolLocator.executableURL(for: .opencode) else { return [] }
    guard let result = try? await Shell.run([executable.path, "models"]), result.status == 0 else { return [] }
    return result.stdout
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
