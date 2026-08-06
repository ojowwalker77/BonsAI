import XCTest
import SwiftData
@testable import ComposerApp

@MainActor
final class BoardPersistenceTests: XCTestCase {
  func testNewPayloadHasExplicitVersionAndLegacyArraysStillDecode() throws {
    let cards = [CardState.firstCard(text: "Versioned")]

    let encoded = try BoardPayload.encode(cards: cards)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(root["formatVersion"] as? Int, BoardPayload.currentFormatVersion)
    XCTAssertNotNil(root["cards"] as? [Any])

    let legacyData = try JSONEncoder().encode(cards)
    let legacy = try BoardPayload.decode(legacyData)
    XCTAssertTrue(legacy.isLegacy)
    XCTAssertEqual(legacy.cards, cards)
    XCTAssertTrue(legacy.opaqueCards.isEmpty)
  }

  func testCorruptPayloadSurvivesDebouncedNavigationAndQuitTimeFlushes() async throws {
    let store = makeStore()
    let originalDump = try XCTUnwrap(store.current)
    let originalID = originalDump.persistentModelID
    let corruptData = Data(#"{"cards":["#.utf8)
    originalDump.cardsData = corruptData
    originalDump.text = ""
    try store.container.mainContext.save()

    let board = BoardViewModel(store: store)
    XCTAssertEqual(store.recoveryData(for: originalDump), corruptData)

    // Debounced saves include theme-driven snapshots and ordinary autosave.
    board.scheduleSave()
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(originalDump.cardsData, corruptData)

    // Match the canvas navigation path: flush, switch, then reload.
    board.flushSave()
    store.newDump()
    store.flush(cards: [CardState.firstCard(text: "Destination")])
    let destinationID = try XCTUnwrap(store.currentID)
    board.loadFromStore()
    board.flushSave()
    store.select(originalID)
    board.loadFromStore()
    XCTAssertEqual(originalDump.cardsData, corruptData)

    // AppDelegate's quit path ultimately invokes this same flush.
    board.flushSave()
    XCTAssertEqual(originalDump.cardsData, corruptData)
    XCTAssertEqual(store.recoveryData(for: originalDump), corruptData)

    board.flushSave()
    store.select(destinationID)
    XCTAssertTrue(store.dumps.contains { $0.persistentModelID == originalID })
    XCTAssertEqual(originalDump.cardsData, corruptData)
  }

  func testFuturePayloadVersionIsWriteProtectedAndRecoverable() throws {
    let store = makeStore()
    let dump = try XCTUnwrap(store.current)
    let futureData = Data(
      #"{"formatVersion":999,"cards":[{"id":"00000000-0000-0000-0000-000000000099","kind":"future","payload":{"value":42}}]}"#.utf8
    )
    dump.cardsData = futureData
    try store.container.mainContext.save()

    store.flush(cards: [CardState.firstCard(text: "Fallback must not replace future data")])

    XCTAssertEqual(dump.cardsData, futureData)
    XCTAssertEqual(store.recoveryData(for: dump), futureData)
    XCTAssertFalse(dump.isBlank)
  }

  func testRecoveryFailureNeverAuthorizesOverwritingSource() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("BonsAI-Blocked-Recovery-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: parent)
    defer { try? FileManager.default.removeItem(at: parent) }

    let store = DumpStore(
      inMemoryOnly: true,
      loadInitialContent: false,
      recoveryDirectory: parent.appendingPathComponent("Recovery")
    )
    let dump = try XCTUnwrap(store.current)
    let corruptData = Data(#"{"broken":"#.utf8)
    dump.cardsData = corruptData
    try store.container.mainContext.save()

    _ = store.cards(for: dump)
    store.flush(cards: [CardState.firstCard(text: "Must not replace source")])

    XCTAssertEqual(dump.cardsData, corruptData)
    XCTAssertNotNil(store.currentBoardProtection)
  }

  func testRecoveryFilesAreContentAddressedAndPrivate() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BonsAI-Board-Recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Data("first unreadable payload".utf8)
    let later = Data("later payload".utf8)

    let url = try BoardRecoveryStore.preserve(first, in: directory)
    let repeatedURL = try BoardRecoveryStore.preserve(first, in: directory)
    let laterURL = try BoardRecoveryStore.preserve(later, in: directory)

    XCTAssertEqual(try Data(contentsOf: url), first)
    XCTAssertEqual(repeatedURL, url)
    XCTAssertEqual(try Data(contentsOf: laterURL), later)
    XCTAssertNotEqual(laterURL, url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testRecoveryRefusesAChangedFileAtTheContentAddressedPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BonsAI-Board-Recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = Data("original unreadable payload".utf8)
    let url = try BoardRecoveryStore.preserve(original, in: directory)
    try Data("externally changed".utf8).write(to: url)

    XCTAssertThrowsError(try BoardRecoveryStore.preserve(original, in: directory))
  }

  func testUnknownElementRoundTripsAcrossNavigationAndQuitTimeFlushes() throws {
    let store = makeStore()
    let originalDump = try XCTUnwrap(store.current)
    let originalID = originalDump.persistentModelID
    let payload = Data(
      """
      [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "text": "Known card",
            "x": 1,
            "y": 2,
            "w": 360,
            "h": 56,
            "z": 0
          },
          {
            "id": "00000000-0000-0000-0000-000000000002",
            "kind": "futureWidget",
            "text": "",
            "x": 20,
            "y": 30,
            "w": 240,
            "h": 180,
            "z": 1,
            "futurePayload": {
              "mode": "spatial",
              "values": [1, 2, 3]
            }
          }
      ]
      """.utf8
    )
    originalDump.cardsData = payload
    originalDump.text = "Known card"
    try store.container.mainContext.save()

    let board = BoardViewModel(store: store)
    XCTAssertEqual(board.cards.map(\.text), ["Known card"])
    let legacy = try BoardPayload.decode(try XCTUnwrap(originalDump.cardsData))
    XCTAssertTrue(legacy.isLegacy)
    XCTAssertEqual(legacy.opaqueCards.count, 1)

    board.flushSave()
    assertFuturePayloadPreserved(in: try XCTUnwrap(originalDump.cardsData))

    store.newDump()
    store.flush(cards: [CardState.firstCard(text: "Destination")])
    let destinationID = try XCTUnwrap(store.currentID)
    board.loadFromStore()
    board.flushSave()
    store.select(originalID)
    board.loadFromStore()
    assertFuturePayloadPreserved(in: try XCTUnwrap(originalDump.cardsData))

    board.flushSave()
    assertFuturePayloadPreserved(in: try XCTUnwrap(originalDump.cardsData))
    store.select(destinationID)
    XCTAssertTrue(store.dumps.contains { $0.persistentModelID == originalID })
  }

  func testFreehandOnlyBoardSurvivesNavigation() throws {
    try assertSurvivesNavigation(
      CardState(kind: .freehand, x: 0, y: 0, points: CardState.defaultFreehandPoints())
    )
  }

  func testShapeOnlyBoardSurvivesNavigation() throws {
    try assertSurvivesNavigation(CardState(kind: .rectangle, x: 0, y: 0))
  }

  func testImageOnlyBoardSurvivesNavigation() throws {
    try assertSurvivesNavigation(CardState(kind: .image, x: 0, y: 0, imagePath: "board-image.png"))
  }

  func testStructuredOnlyBoardSurvivesNavigation() throws {
    let structuredCards = [
      CardState(kind: .equation, x: 0, y: 0, latex: "x^2"),
      CardState(kind: .graph, x: 0, y: 0, graph: .init()),
      CardState(kind: .sticky, x: 0, y: 0, stickyTitle: "Note"),
      CardState(kind: .checklist, x: 0, y: 0, checklist: [.init(text: "Ship")]),
      CardState(kind: .table, x: 0, y: 0, table: .init()),
    ]
    for card in structuredCards {
      try assertSurvivesNavigation(card)
    }
  }

  func testNamedEmptyBoardSurvivesNavigation() throws {
    let store = makeStore()
    let namedID = try XCTUnwrap(store.currentID)
    store.rename(namedID, to: "Keep this board")
    store.newDump()
    let destinationID = try XCTUnwrap(store.currentID)

    store.select(namedID)
    store.select(destinationID)

    XCTAssertTrue(store.dumps.contains { $0.persistentModelID == namedID })
  }

  func testRenameFailureRollsBackVisibleAndPersistedTitle() async throws {
    var failNextSave = false
    let store = DumpStore(
      inMemoryOnly: true,
      loadInitialContent: false,
      persistContext: { context in
        if failNextSave {
          failNextSave = false
          throw ForcedRenameSaveFailure()
        }
        try context.save()
      }
    )
    let id = try XCTUnwrap(store.currentID)
    XCTAssertTrue(store.rename(id, to: "Durable title"))

    _ = UserFacingErrorStore.shared.takeLatest()
    failNextSave = true
    XCTAssertFalse(store.rename(id, to: "Title that must not stick"))
    XCTAssertEqual(store.current?.customTitle, "Durable title")

    let verificationContext = ModelContext(store.container)
    let persisted = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Dump>()).first)
    XCTAssertEqual(persisted.customTitle, "Durable title")

    await Task.yield()
    XCTAssertEqual(UserFacingErrorStore.shared.takeLatest()?.message, "forced rename save failure")
  }

  func testDeleteRemovesNonCurrentAndCurrentBoardsSafely() throws {
    let store = makeStore()
    store.flush(cards: [CardState.firstCard(text: "First board")])
    let firstID = try XCTUnwrap(store.currentID)
    store.newDump()
    store.flush(cards: [CardState.firstCard(text: "Second board")])
    let secondID = try XCTUnwrap(store.currentID)
    store.newDump()
    store.flush(cards: [CardState.firstCard(text: "Third board")])
    let thirdID = try XCTUnwrap(store.currentID)

    XCTAssertTrue(store.delete(firstID))
    XCTAssertFalse(store.dumps.contains { $0.persistentModelID == firstID })
    XCTAssertEqual(store.currentID, thirdID)

    store.select(secondID)
    XCTAssertTrue(store.delete(secondID))
    XCTAssertFalse(store.dumps.contains { $0.persistentModelID == secondID })
    XCTAssertEqual(store.currentID, thirdID)
    XCTAssertEqual(store.current?.text, "Third board")
  }

  func testDeleteSaveFailureRollsBackAndKeepsBoardAvailable() throws {
    var failNextSave = false
    let store = DumpStore(
      inMemoryOnly: true,
      loadInitialContent: false,
      persistContext: { context in
        if failNextSave {
          failNextSave = false
          throw ForcedDeleteSaveFailure()
        }
        try context.save()
      }
    )
    store.flush(cards: [CardState.firstCard(text: "Keep this board")])
    let id = try XCTUnwrap(store.currentID)
    store.newDump()
    store.flush(cards: [CardState.firstCard(text: "Current board")])

    failNextSave = true
    XCTAssertFalse(store.delete(id))
    XCTAssertTrue(store.dumps.contains { $0.persistentModelID == id })
    XCTAssertEqual(store.dumps.first { $0.persistentModelID == id }?.text, "Keep this board")

    let currentID = try XCTUnwrap(store.currentID)
    failNextSave = true
    XCTAssertFalse(store.delete(currentID))
    XCTAssertEqual(store.currentID, currentID)
    XCTAssertEqual(store.current?.text, "Current board")
    XCTAssertTrue(store.dumps.contains { $0.persistentModelID == currentID })

    let verificationContext = ModelContext(store.container)
    let persisted = try verificationContext.fetch(FetchDescriptor<Dump>())
    XCTAssertTrue(persisted.contains { $0.persistentModelID == id })
  }

  func testAutosaveFailureRollsBackAndCanRetry() throws {
    var failNextSave = false
    let store = DumpStore(
      inMemoryOnly: true,
      loadInitialContent: false,
      persistContext: { context in
        if failNextSave {
          failNextSave = false
          throw ForcedAutosaveSaveFailure()
        }
        try context.save()
      }
    )
    let id = try XCTUnwrap(store.currentID)

    failNextSave = true
    XCTAssertFalse(store.flush(cards: [CardState.firstCard(text: "Failed write")]))
    XCTAssertEqual(store.dumps.first { $0.persistentModelID == id }?.text, "")

    XCTAssertTrue(store.flush(cards: [CardState.firstCard(text: "Retry succeeds")]))
    XCTAssertEqual(store.dumps.first { $0.persistentModelID == id }?.text, "Retry succeeds")
  }

  func testProtectedFallbackCanBeDuplicatedWithoutChangingSource() throws {
    let store = makeStore()
    let source = try XCTUnwrap(store.current)
    let sourceID = source.persistentModelID
    let futureData = Data(#"{"formatVersion":999,"cards":[]}"#.utf8)
    source.cardsData = futureData
    source.customTitle = "Future board"
    try store.container.mainContext.save()

    let board = BoardViewModel(store: store)
    XCTAssertNotNil(store.currentBoardProtection)
    board.setText(try XCTUnwrap(board.cards.first?.id), "Recovered visible edit")
    XCTAssertTrue(board.duplicateProtectedBoardForEditing())

    XCTAssertEqual(source.cardsData, futureData)
    XCTAssertNotEqual(store.currentID, sourceID)
    XCTAssertEqual(store.current?.customTitle, "Future board — Recovered Copy")
    XCTAssertEqual(store.current?.text, "Recovered visible edit")
    XCTAssertNil(store.currentBoardProtection)
  }

  func testUnknownOnlyBoardSurvivesNavigation() throws {
    let store = makeStore()
    let source = try XCTUnwrap(store.current)
    let sourceID = source.persistentModelID
    source.cardsData = Data(
      #"[{"id":"00000000-0000-0000-0000-000000000099","kind":"futureWidget","futurePayload":{"value":42}}]"#.utf8
    )
    try store.container.mainContext.save()

    let board = BoardViewModel(store: store)
    XCTAssertNotNil(store.currentBoardProtection)
    board.flushSave()
    store.newDump()
    let destinationID = try XCTUnwrap(store.currentID)
    board.loadFromStore()
    board.flushSave()
    store.select(sourceID)
    board.loadFromStore()
    board.flushSave()
    store.select(destinationID)

    XCTAssertTrue(store.dumps.contains { $0.persistentModelID == sourceID })
  }

  func testTrulyEmptyPlaceholderBoardIsStillPruned() throws {
    let store = makeStore()
    store.flush(cards: [CardState.firstCard(text: "Keeper")])
    let keeperID = try XCTUnwrap(store.currentID)
    store.newDump()
    let blankID = try XCTUnwrap(store.currentID)

    store.select(keeperID)

    XCTAssertFalse(store.dumps.contains { $0.persistentModelID == blankID })
    XCTAssertEqual(store.dumps.count, 1)
  }

  private func makeStore() -> DumpStore {
    DumpStore(inMemoryOnly: true, loadInitialContent: false)
  }

  private func assertSurvivesNavigation(_ card: CardState) throws {
    let store = makeStore()
    let drawingID = try XCTUnwrap(store.currentID)
    store.flush(cards: [card])
    XCTAssertFalse(try XCTUnwrap(store.current).isBlank)

    store.newDump()
    store.flush(cards: [CardState.firstCard(text: "Destination")])
    let destinationID = try XCTUnwrap(store.currentID)
    XCTAssertEqual(store.dumps.count, 2)

    store.select(drawingID)
    store.select(destinationID)

    XCTAssertTrue(store.dumps.contains { $0.persistentModelID == drawingID })
    XCTAssertEqual(store.dumps.count, 2)
  }

  private func assertFuturePayloadPreserved(in data: Data,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
    do {
      let unknown = try unknownElement(in: data)
      XCTAssertEqual(unknown["kind"] as? String, "futureWidget", file: file, line: line)
      let futurePayload = try XCTUnwrap(unknown["futurePayload"] as? [String: Any], file: file, line: line)
      XCTAssertEqual(futurePayload["mode"] as? String, "spatial", file: file, line: line)
      XCTAssertEqual(futurePayload["values"] as? [Int], [1, 2, 3], file: file, line: line)
    } catch {
      XCTFail("Could not read preserved future element: \(error)", file: file, line: line)
    }
  }

  private func unknownElement(in data: Data) throws -> [String: Any] {
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(root["formatVersion"] as? Int, BoardPayload.currentFormatVersion)
    let cards = try XCTUnwrap(root["cards"] as? [[String: Any]])
    return try XCTUnwrap(cards.first { $0["kind"] as? String == "futureWidget" })
  }
}

private struct ForcedRenameSaveFailure: LocalizedError {
  var errorDescription: String? { "forced rename save failure" }
}

private struct ForcedDeleteSaveFailure: LocalizedError {
  var errorDescription: String? { "forced delete save failure" }
}

private struct ForcedAutosaveSaveFailure: LocalizedError {
  var errorDescription: String? { "forced autosave save failure" }
}
