import Foundation
import SwiftData

// MARK: - Model

/// One board. The whole memory layer is a stack of these. A board is a set of positioned
/// text cards (`cardsData`, JSON of `[CardState]`); `text` is kept as a lightweight mirror
/// of the cards' content so the history list (`title`/`isBlank`), legacy migration, and any
/// pre-canvas note keep working unchanged. Stored locally via SwiftData today; flipping on
/// iCloud later is a CloudKit config + entitlement, no model change.
@Model
final class Dump {
  /// Mirror of the board's text (joined card contents) — drives `title`/`isBlank` and is the
  /// single-card fallback for legacy/un-migrated boards. The cards are the real content.
  var text: String
  var createdAt: Date
  var updatedAt: Date
  /// JSON of `[CardState]`. `nil` on a legacy/fresh board → one card synthesized from `text`.
  var cardsData: Data?

  init(text: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), cardsData: Data? = nil) {
    self.text = text
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.cardsData = cardsData
  }
}

extension Dump {
  /// First non-empty line, for the history list.
  var title: String {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
    }
    return ""
  }
  var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Store

/// Owns the SwiftData stack and the notion of a "current" board the canvas is on.
/// Ordering is by creation (newest first) so editing an old board never reshuffles it.
@MainActor
final class DumpStore: ObservableObject {
  static let shared = DumpStore()

  let container: ModelContainer
  private var context: ModelContext { container.mainContext }
  private var saveWork: DispatchWorkItem?
  /// The next save asks the board for one fresh snapshot when the debounce fires. Keeping a
  /// closure (rather than an array captured by every queued work item) prevents fast typing from
  /// retaining many whole-board copies until their cancelled timers drain.
  private var pendingSnapshot: (() -> [CardState])?

  /// Newest first.
  @Published private(set) var dumps: [Dump] = []
  /// The board currently loaded in the canvas.
  @Published private(set) var currentID: PersistentIdentifier?
  /// The history list overlay is showing (the editor coordinator dismisses it on Esc).
  @Published var isHistoryOpen = false
  /// The separate Settings panel is showing (also dismissed on Esc).
  @Published var isSettingsOpen = false
  /// The compiled-draft overlay's text (nil = closed). Board-level, transient UI — kept
  /// here so the editor coordinator's Esc chain can dismiss it like the other overlays.
  @Published var compiledDraft: String?

  init() {
    let schema = Schema([Dump.self])
    let config = ModelConfiguration("Composer", schema: schema)
    if let c = try? ModelContainer(for: schema, configurations: config) {
      container = c
    } else {
      // Never block the editor on a storage failure — fall back to memory-only.
      container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    migrateLegacyNoteIfNeeded()
    seedWelcomeBoardIfFirstRun()
    reload()
    ensureCurrent()
  }

  // MARK: Derived

  var current: Dump? { dumps.first { $0.persistentModelID == currentID } }
  var currentText: String { current?.text ?? "" }
  private var currentIndex: Int { dumps.firstIndex { $0.persistentModelID == currentID } ?? 0 }
  var canGoOlder: Bool { currentIndex < dumps.count - 1 }
  var canGoNewer: Bool { currentIndex > 0 }
  /// Human position, e.g. "2 / 5" (1 = newest).
  var position: (index: Int, total: Int) { (currentIndex + 1, dumps.count) }

  // MARK: Cards

  /// The cards for a board: decoded from `cardsData`, or one card synthesized from the
  /// legacy `text` when a board predates the canvas (lazy, no migration pass).
  func cards(for dump: Dump?) -> [CardState] {
    guard let dump else { return [CardState.firstCard()] }
    if let data = dump.cardsData,
       let decoded = try? JSONDecoder().decode([CardState].self, from: data),
       !decoded.isEmpty {
      return decoded
    }
    return [CardState.firstCard(text: dump.text)]
  }

  /// Cards for the current board (always ≥ 1).
  var currentCards: [CardState] { cards(for: current) }

  // MARK: Editing

  /// Debounced autosave of the canvas's cards into the current board.
  func scheduleUpdate(snapshot: @escaping () -> [CardState]) {
    pendingSnapshot = snapshot
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let cards = self.pendingSnapshot?() else { return }
      self.pendingSnapshot = nil
      self.commit(cards: cards)
    }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  /// Force a pending save now — call before navigating away so nothing is lost.
  func flush(cards: [CardState]) {
    saveWork?.cancel()
    pendingSnapshot = nil
    commit(cards: cards)
  }

  private func commit(cards: [CardState]) {
    let data = try? JSONEncoder().encode(cards)
    let mirror = Self.titleMirror(for: cards)
    guard let dump = current else {
      let dump = Dump(text: mirror, cardsData: data)
      context.insert(dump)
      try? context.save()
      reload()
      currentID = dump.persistentModelID
      return
    }
    guard dump.cardsData != data || dump.text != mirror else { return }
    dump.cardsData = data
    dump.text = mirror
    dump.updatedAt = Date()
    try? context.save()
    objectWillChange.send()   // the array identity is unchanged; nudge the list
  }

  /// The mirror text whose first non-empty line becomes the history title.
  private static func titleMirror(for cards: [CardState]) -> String {
    cards.map(\.text).joined(separator: "\n\n")
  }

  // MARK: Navigation

  func goOlder() { move(by: +1) }
  func goNewer() { move(by: -1) }

  private func move(by delta: Int) {
    let target = currentIndex + delta
    guard dumps.indices.contains(target) else { return }
    let destination = dumps[target].persistentModelID
    pruneCurrentIfEmpty()
    reload()
    currentID = destination
  }

  func select(_ id: PersistentIdentifier) {
    guard dumps.contains(where: { $0.persistentModelID == id }) else { return }
    pruneCurrentIfEmpty()
    reload()
    currentID = id
    isHistoryOpen = false
  }

  /// Start a fresh board — but never stack two blanks.
  func newDump() {
    if let dump = current, dump.isBlank { isHistoryOpen = false; return }
    let dump = Dump()
    context.insert(dump)
    try? context.save()
    reload()
    currentID = dump.persistentModelID
    isHistoryOpen = false
  }

  func delete(_ id: PersistentIdentifier) {
    guard let dump = dumps.first(where: { $0.persistentModelID == id }) else { return }
    let wasCurrent = id == currentID
    context.delete(dump)
    try? context.save()
    reload()
    if wasCurrent { currentID = dumps.first?.persistentModelID }
    ensureCurrent()
  }

  // MARK: Housekeeping

  private func pruneCurrentIfEmpty() {
    guard dumps.count > 1, let dump = current, dump.isBlank else { return }
    context.delete(dump)
    try? context.save()
    reload()
  }

  private func ensureCurrent() {
    if dumps.isEmpty {
      let dump = Dump()
      context.insert(dump)
      try? context.save()
      reload()
    }
    if current == nil { currentID = dumps.first?.persistentModelID }
  }

  private func reload() {
    let descriptor = FetchDescriptor<Dump>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    dumps = (try? context.fetch(descriptor)) ?? []
  }

  /// Seed the bundled welcome board the first time the app runs with an empty store, so new users
  /// land on it. Guarded by a flag so deleting it never brings it back, and so an existing user
  /// (who already has boards, or a migrated legacy note) never has it injected on a later launch.
  private func seedWelcomeBoardIfFirstRun() {
    let seededKey = "composer.didSeedWelcomeBoard"
    guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
    let existing = (try? context.fetchCount(FetchDescriptor<Dump>())) ?? 0
    guard existing == 0, let cards = WelcomeBoard.seedCards() else {
      // Returning user (or unreadable resource): mark seeded so we never inject it later.
      if existing > 0 { UserDefaults.standard.set(true, forKey: seededKey) }
      return
    }
    let data = try? JSONEncoder().encode(cards)
    context.insert(Dump(text: Self.titleMirror(for: cards), cardsData: data))
    try? context.save()
    UserDefaults.standard.set(true, forKey: seededKey)
  }

  private func migrateLegacyNoteIfNeeded() {
    let existing = (try? context.fetchCount(FetchDescriptor<Dump>())) ?? 0
    let legacy = NotePersistence.load()
    guard existing == 0, !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    context.insert(Dump(text: legacy))
    try? context.save()
  }
}
