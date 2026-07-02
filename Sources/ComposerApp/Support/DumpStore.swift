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
  private static let welcomeSeededKey = "composer.didSeedWelcomeBoard"
  private static let welcomeBoard13InstalledKey = "composer.didInstallWelcomeBoard.1.3.0"
  private static let previousWelcomeCardIDs: Set<UUID> = [
    UUID(uuidString: "990EE873-F529-4CA0-BAC1-AD42237F85BE")!,
    UUID(uuidString: "45AB0AE2-18DD-4DE0-8F47-77E1480A6066")!,
    UUID(uuidString: "1144979D-8BEE-48FF-8C5C-4601937EF03F")!,
    UUID(uuidString: "CC947873-A07D-4996-9737-2D0D29960507")!,
    UUID(uuidString: "54F3F1BC-8559-4031-B109-A23CEE54C183")!,
    UUID(uuidString: "8B247774-CA4D-4756-8780-4E4A6A1EDA74")!,
    UUID(uuidString: "963EB88C-4950-48A7-AA07-944F7659F571")!,
    UUID(uuidString: "0203037F-778F-486B-A432-39F7E45D9818")!,
    UUID(uuidString: "21A24D7C-17E4-434F-96FE-C385C68E50C6")!,
  ]

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

  /// `inMemoryOnly` exists for tests: `swift test` runs unsandboxed, so the default on-disk
  /// configuration resolves to the user's REAL `Composer.store` — a test that touched it could
  /// persist junk cards into a real board.
  init(inMemoryOnly: Bool = false) {
    let schema = Schema([Dump.self])
    let config = inMemoryOnly
      ? ModelConfiguration(isStoredInMemoryOnly: true)
      : ModelConfiguration("Composer", schema: schema)
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
    installWelcomeBoard13IfNeeded()
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
        if !decoded.isEmpty { return migrateImagePaths(in: decoded, for: dump) }
        reportUnreadableBoard(dump, message: "A saved board contained no cards. Composer loaded its text fallback instead.")
      } catch {
        reportUnreadableBoard(dump, message: UserFacingError.message(for: error, while: "Reading this saved board"))
      }
    }
    return [CardState.firstCard(text: dump.text)]
  }

  private func migrateImagePaths(in cards: [CardState], for dump: Dump) -> [CardState] {
    var changed = false
    let migrated = cards.map { card -> CardState in
      guard let path = card.imagePath, path.hasPrefix("/") else { return card }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let replacement: String?
      if let filename = AssetStore.filenameIfInsideStore(url) {
        replacement = filename
      } else if FileManager.default.fileExists(atPath: url.path) {
        replacement = AssetStore.ingest(fileURL: url)
      } else {
        replacement = nil
      }
      guard let replacement, replacement != path else { return card }
      var updated = card
      updated.imagePath = replacement
      changed = true
      return updated
    }
    guard changed else { return cards }
    do {
      dump.cardsData = try JSONEncoder().encode(migrated)
      _ = save("Migrating board image attachments")
    } catch {
      UserFacingError.report(error, while: "Encoding migrated board image attachments")
    }
    return migrated
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
  /// land on it. Guarded by a flag so the first-run seed itself never repeats, and so an existing
  /// user (who already has boards, or a migrated legacy note) never gets the first-run board later.
  private func seedWelcomeBoardIfFirstRun() {
    guard !UserDefaults.standard.bool(forKey: Self.welcomeSeededKey) else { return }
    let existing: Int
    do {
      existing = try context.fetchCount(FetchDescriptor<Dump>())
    } catch {
      UserFacingError.report(error, while: "Checking whether Composer has existing boards")
      return
    }
    guard existing == 0, let cards = WelcomeBoard.seedCards() else {
      // Returning user (or unreadable resource): mark seeded so we never inject it later.
      if existing > 0 { UserDefaults.standard.set(true, forKey: Self.welcomeSeededKey) }
      return
    }
    let data: Data
    do {
      data = try JSONEncoder().encode(cards)
    } catch {
      UserFacingError.report(error, while: "Encoding the welcome board")
      return
    }
    context.insert(Dump(text: Self.titleMirror(for: cards), cardsData: data, customTitle: WelcomeBoard.title))
    if save("Saving the welcome board") {
      UserDefaults.standard.set(true, forKey: Self.welcomeSeededKey)
    }
  }

  /// BonsAI 1.3.0 ships a new welcome canvas. Install it once for every user: replace the old
  /// bundled welcome board when present, otherwise add the new one without touching user boards.
  private func installWelcomeBoard13IfNeeded() {
    guard !UserDefaults.standard.bool(forKey: Self.welcomeBoard13InstalledKey) else { return }
    guard let cards = WelcomeBoard.seedCards() else { return }
    let data: Data
    do {
      data = try JSONEncoder().encode(cards)
    } catch {
      UserFacingError.report(error, while: "Encoding the BonsAI 1.3 welcome board")
      return
    }

    let existing: [Dump]
    do {
      existing = try context.fetch(FetchDescriptor<Dump>())
    } catch {
      UserFacingError.report(error, while: "Checking saved boards for the BonsAI 1.3 welcome board")
      return
    }

    if let dump = existing.first(where: isBundledWelcomeBoard) {
      dump.cardsData = data
      dump.text = Self.titleMirror(for: cards)
      dump.customTitle = WelcomeBoard.title
      dump.updatedAt = Date()
    } else {
      context.insert(Dump(text: Self.titleMirror(for: cards), cardsData: data, customTitle: WelcomeBoard.title))
    }

    if save("Installing the BonsAI 1.3 welcome board") {
      UserDefaults.standard.set(true, forKey: Self.welcomeBoard13InstalledKey)
    }
  }

  private func isBundledWelcomeBoard(_ dump: Dump) -> Bool {
    if dump.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) == WelcomeBoard.title { return true }
    guard let cards = decodedCards(for: dump) else { return false }
    let ids = Set(cards.map(\.id))
    return ids.intersection(Self.previousWelcomeCardIDs).count >= 3
  }

  private func decodedCards(for dump: Dump) -> [CardState]? {
    guard let data = dump.cardsData else { return nil }
    return try? JSONDecoder().decode([CardState].self, from: data)
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
