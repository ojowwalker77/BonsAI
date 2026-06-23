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
  /// A user-given board name. When set it overrides the auto-derived `title` and survives card
  /// edits, so a rename sticks. `nil`/empty falls back to the first line of the content.
  var customTitle: String?

  init(text: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), cardsData: Data? = nil, customTitle: String? = nil) {
    self.text = text
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.cardsData = cardsData
    self.customTitle = customTitle
  }
}

extension Dump {
  /// The board's display name: the user-set `customTitle` if present, else the first non-empty
  /// line of the content.
  var title: String {
    if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
      return String(custom.prefix(80))
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
    }
    return ""
  }
  /// Blank = no content AND no user-given name — a named board is worth keeping even while empty,
  /// so it isn't auto-pruned out from under the user.
  var isBlank: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }
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
  private var reportedUnreadableBoardIDs = Set<String>()
  /// The next save asks the board for one fresh snapshot when the debounce fires. Keeping a
  /// closure (rather than an array captured by every queued work item) prevents fast typing from
  /// retaining many whole-board copies until their cancelled timers drain.
  private var pendingSnapshot: (() -> [CardState]?)?

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
    do {
      container = try ModelContainer(for: schema, configurations: config)
    } catch {
      // Never block the editor on a storage failure — fall back to memory-only.
      UserFacingError.report(error, while: "Opening Composer’s on-disk board storage")
      do {
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        UserFacingError.report("Composer is running with temporary memory-only storage. Boards created in this session will not survive a restart.")
      } catch {
        fatalError("Composer could not create either persistent or temporary board storage: \(error.localizedDescription)")
      }
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
    if let data = dump.cardsData {
      do {
        let decoded = try JSONDecoder().decode([CardState].self, from: data)
        if !decoded.isEmpty { return decoded }
        reportUnreadableBoard(dump, message: "A saved board contained no cards. Composer loaded its text fallback instead.")
      } catch {
        reportUnreadableBoard(dump, message: UserFacingError.message(for: error, while: "Reading this saved board"))
      }
    }
    return [CardState.firstCard(text: dump.text)]
  }

  /// Cards for the current board (always ≥ 1).
  var currentCards: [CardState] { cards(for: current) }

  // MARK: Editing

  /// Debounced autosave of the canvas's cards into the current board.
  func scheduleUpdate(snapshot: @escaping () -> [CardState]?) {
    pendingSnapshot = snapshot
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let snapshot = self.pendingSnapshot
      self.pendingSnapshot = nil
      guard let cards = snapshot?() else { return }
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
    let data: Data
    do {
      data = try JSONEncoder().encode(cards)
    } catch {
      UserFacingError.report(error, while: "Encoding the board before autosave")
      return
    }
    let mirror = Self.titleMirror(for: cards)
    guard let dump = current else {
      let dump = Dump(text: mirror, cardsData: data)
      context.insert(dump)
      guard save("Creating a new board") else { return }
      reload()
      currentID = dump.persistentModelID
      return
    }
    guard dump.cardsData != data || dump.text != mirror else { return }
    dump.cardsData = data
    dump.text = mirror
    dump.updatedAt = Date()
    guard save("Autosaving the board") else { return }
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
    guard save("Creating a new board") else { return }
    reload()
    currentID = dump.persistentModelID
    isHistoryOpen = false
  }

  func delete(_ id: PersistentIdentifier) {
    guard let dump = dumps.first(where: { $0.persistentModelID == id }) else { return }
    let wasCurrent = id == currentID
    context.delete(dump)
    guard save("Deleting the board") else { return }
    reload()
    if wasCurrent { currentID = dumps.first?.persistentModelID }
    ensureCurrent()
  }

  /// Give a board a custom name. An empty/whitespace name clears it back to the auto-derived title.
  /// Doesn't touch the cards, so it's safe to rename the board you're currently editing.
  func rename(_ id: PersistentIdentifier, to name: String) {
    guard let dump = dumps.first(where: { $0.persistentModelID == id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    dump.customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    dump.updatedAt = Date()
    try? context.save()
    objectWillChange.send()
  }

  // MARK: Housekeeping

  private func pruneCurrentIfEmpty() {
    guard dumps.count > 1, let dump = current, dump.isBlank else { return }
    context.delete(dump)
    guard save("Removing the empty board") else { return }
    reload()
  }

  private func ensureCurrent() {
    if dumps.isEmpty {
      let dump = Dump()
      context.insert(dump)
      guard save("Creating the first board") else { return }
      reload()
    }
    if current == nil { currentID = dumps.first?.persistentModelID }
  }

  private func reload() {
    let descriptor = FetchDescriptor<Dump>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    do {
      dumps = try context.fetch(descriptor)
    } catch {
      UserFacingError.report(error, while: "Loading saved boards")
    }
  }

  /// Seed the bundled welcome board the first time the app runs with an empty store, so new users
  /// land on it. Guarded by a flag so deleting it never brings it back, and so an existing user
  /// (who already has boards, or a migrated legacy note) never has it injected on a later launch.
  private func seedWelcomeBoardIfFirstRun() {
    let seededKey = "composer.didSeedWelcomeBoard"
    guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
    let existing: Int
    do {
      existing = try context.fetchCount(FetchDescriptor<Dump>())
    } catch {
      UserFacingError.report(error, while: "Checking whether Composer has existing boards")
      return
    }
    guard existing == 0, let cards = WelcomeBoard.seedCards() else {
      // Returning user (or unreadable resource): mark seeded so we never inject it later.
      if existing > 0 { UserDefaults.standard.set(true, forKey: seededKey) }
      return
    }
    let data: Data
    do {
      data = try JSONEncoder().encode(cards)
    } catch {
      UserFacingError.report(error, while: "Encoding the welcome board")
      return
    }
    context.insert(Dump(text: Self.titleMirror(for: cards), cardsData: data))
    if save("Saving the welcome board") {
      UserDefaults.standard.set(true, forKey: seededKey)
    }
  }

  private func migrateLegacyNoteIfNeeded() {
    let existing: Int
    do {
      existing = try context.fetchCount(FetchDescriptor<Dump>())
    } catch {
      UserFacingError.report(error, while: "Checking whether Composer has existing boards")
      return
    }
    let legacy = NotePersistence.load()
    guard existing == 0, !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    context.insert(Dump(text: legacy))
    _ = save("Importing the previous Composer note")
  }

  private func save(_ action: String) -> Bool {
    do {
      try context.save()
      return true
    } catch {
      UserFacingError.report(error, while: action)
      return false
    }
  }

  private func reportUnreadableBoard(_ dump: Dump, message: String) {
    let id = String(describing: dump.persistentModelID)
    guard reportedUnreadableBoardIDs.insert(id).inserted else { return }
    UserFacingError.report(message)
  }
}
