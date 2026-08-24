import AppKit
import SwiftUI
import XCTest

@testable import ComposerApp

private final class EscapeHandlingFieldDelegate: NSObject, NSTextFieldDelegate {
  var cancelled = false

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    cancelled = true
    return true
  }
}

/// FloatingPanel.keyDown routes window-level Backspace to `.composerDeleteSelection` unless the
/// firstResponder is an `NSTextView`. Both kinds of text input in the app satisfy that guard the
/// same way: AppKit fields (the ⌘K palette's `FocusedSearchField`) and SwiftUI `TextField`s (the
/// board-picker rename) both edit through an `NSTextView` field editor. These tests pin that
/// invariant so a macOS/SwiftUI change can't silently turn Backspace-in-a-text-field into
/// "delete the selected cards".
@MainActor
final class FloatingPanelKeyRoutingTests: XCTestCase {
  private func makePanel() -> FloatingPanel {
    _ = NSApplication.shared
    return FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300))
  }

  private func backspaceKeyDown(in panel: NSWindow) -> NSEvent {
    let del = "\u{7f}"
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil,
      characters: del, charactersIgnoringModifiers: del, isARepeat: false, keyCode: 51)!
  }

  private func escapeKeyDown(in panel: NSWindow) -> NSEvent {
    let escape = "\u{1b}"
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil,
      characters: escape, charactersIgnoringModifiers: escape, isARepeat: false, keyCode: 53)!
  }

  private func letterKeyDown(_ letter: String, in panel: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil,
      characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: 35)!
  }

  private func selectedTool(during body: () -> Void) -> CanvasTool? {
    var selected: CanvasTool?
    let observer = NotificationCenter.default.addObserver(
      forName: .composerSelectTool, object: nil, queue: nil
    ) { note in
      selected = note.userInfo?["tool"] as? CanvasTool
    }
    body()
    NotificationCenter.default.removeObserver(observer)
    return selected
  }

  private func deleteSelectionFired(during body: () -> Void) -> Bool {
    var fired = false
    let observer = NotificationCenter.default.addObserver(
      forName: .composerDeleteSelection, object: nil, queue: nil) { _ in fired = true }
    body()
    NotificationCenter.default.removeObserver(observer)
    return fired
  }

  private func escapeFired(during body: () -> Void) -> Bool {
    escapeCount(during: body) > 0
  }

  private func escapeCount(during body: () -> Void) -> Int {
    var count = 0
    let observer = NotificationCenter.default.addObserver(
      forName: .composerEscapeBoard, object: nil, queue: nil) { _ in count += 1 }
    body()
    NotificationCenter.default.removeObserver(observer)
    return count
  }

  func testBackspaceOnBareCanvasDeletesSelection() {
    let panel = makePanel()
    XCTAssertTrue(panel.firstResponder === panel)

    let fired = deleteSelectionFired { panel.sendEvent(backspaceKeyDown(in: panel)) }

    XCTAssertTrue(fired, "with no text input editing, Backspace must delete the selected cards")
  }

  func testBarePSelectsVectorPenOutsideTextEditing() {
    let panel = makePanel()
    XCTAssertEqual(
      selectedTool { panel.sendEvent(letterKeyDown("p", in: panel)) },
      .vectorPen)
  }

  func testBarePRemainsTextInputWhileAFieldIsEditing() {
    let panel = makePanel()
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    panel.contentView?.addSubview(field)
    XCTAssertTrue(panel.makeFirstResponder(field))
    XCTAssertTrue(
      panel.firstResponder is NSTextView,
      "an editing NSTextField must install the field editor — bare-P routing depends on it")
    XCTAssertNil(selectedTool { panel.sendEvent(letterKeyDown("p", in: panel)) })
  }

  func testResigningKeyDoesNotReopenViewportTransformsDuringAnActiveDraft() {
    let panel = makePanel()
    let previousMode = CanvasKeyState.shared.viewportDragMode
    defer { CanvasKeyState.shared.viewportDragMode = previousMode }
    CanvasKeyState.shared.viewportDragMode = .drawing

    var releasedSpace = false
    let observer = NotificationCenter.default.addObserver(
      forName: .composerSpaceKeyChanged, object: nil, queue: nil
    ) { note in
      releasedSpace = note.userInfo?["down"] as? Bool == false
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    panel.resignKey()

    XCTAssertTrue(releasedSpace)
    XCTAssertEqual(CanvasKeyState.shared.viewportDragMode, .drawing)
  }

  func testBackspaceWhileAppKitFieldIsEditingDoesNotDeleteCards() {
    let panel = makePanel()
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    panel.contentView?.addSubview(field)
    XCTAssertTrue(panel.makeFirstResponder(field))
    XCTAssertTrue(
      panel.firstResponder is NSTextView,
      "an editing NSTextField must install the field editor — keyDown's guard depends on it")

    let fired = deleteSelectionFired { panel.sendEvent(backspaceKeyDown(in: panel)) }

    XCTAssertFalse(fired, "Backspace in the palette's search field must not delete cards")
  }

  /// The board-rename `TextField` focuses itself via `@FocusState` one runloop tick after it
  /// appears, so this test has to order the panel in and pump the runloop. Skips (rather than
  /// fails) when focus never engages — headless CI has no window server to focus with.
  func testBackspaceWhileSwiftUITextFieldIsEditingDoesNotDeleteCards() throws {
    struct RenameProbe: View {
      @State var draftName = "Board name"
      @FocusState var nameFocused: Bool
      var body: some View {
        TextField("Board name", text: $draftName)
          .textFieldStyle(.plain)
          .focused($nameFocused)
          .onAppear { DispatchQueue.main.async { nameFocused = true } }
          .padding()
      }
    }

    let panel = makePanel()
    panel.contentView = NSHostingView(rootView: RenameProbe())
    panel.makeKeyAndOrderFront(nil)
    defer { panel.orderOut(nil) }

    let deadline = Date().addingTimeInterval(2)
    while panel.firstResponder === panel, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard panel.firstResponder !== panel else {
      throw XCTSkip("SwiftUI focus never engaged — no window server in this environment")
    }
    XCTAssertTrue(
      panel.firstResponder is NSTextView,
      "a focused SwiftUI TextField must edit through an NSTextView field editor — keyDown's guard depends on it")

    let fired = deleteSelectionFired { panel.sendEvent(backspaceKeyDown(in: panel)) }

    XCTAssertFalse(fired, "Backspace in the board-rename field must not delete cards")
  }

  func testEscapeOnBareCanvasRoutesToTheCanvasCoordinator() {
    let panel = makePanel()
    XCTAssertTrue(escapeFired { panel.sendEvent(escapeKeyDown(in: panel)) })
  }

  func testAppKitCancelOperationRoutesToTheCanvasCoordinator() {
    let panel = makePanel()
    XCTAssertTrue(escapeFired { panel.cancelOperation(nil) })
  }

  func testEscapeKeyDownAndCancelOperationPostOnlyOneCanvasCommandPerTurn() {
    let panel = makePanel()
    let count = escapeCount {
      panel.sendEvent(escapeKeyDown(in: panel))
      panel.cancelOperation(nil)
    }

    XCTAssertEqual(count, 1)
  }

  func testAppKitCancelOperationGivesActiveTextEditorFirstRefusal() {
    let panel = makePanel()
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    let delegate = EscapeHandlingFieldDelegate()
    field.delegate = delegate
    panel.contentView?.addSubview(field)
    XCTAssertTrue(panel.makeFirstResponder(field))
    XCTAssertTrue(panel.firstResponder is NSTextView)

    let routed = escapeFired { panel.cancelOperation(nil) }

    XCTAssertTrue(delegate.cancelled, "the active field editor must receive Escape first")
    XCTAssertFalse(routed, "a handled text-editor Escape must not dismiss the workspace")
  }

  func testAppKitCancelOperationFallsBackWhenTextEditorHasNoEscapeHandler() {
    let panel = makePanel()
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    panel.contentView?.addSubview(field)
    XCTAssertTrue(panel.makeFirstResponder(field))
    XCTAssertTrue(panel.firstResponder is NSTextView)

    let routed = escapeFired { panel.cancelOperation(nil) }

    XCTAssertTrue(routed, "an idle text editor must let Escape reach the workspace coordinator")
  }

  func testEscapeCoordinatorClosesAgentOrSettingsBeforeAnActiveEditor() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(hasAgent: true, hasActiveEditor: true)),
      .auxiliaryPanel
    )
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(hasSettings: true, hasActiveEditor: true)),
      .auxiliaryPanel
    )
  }

  func testEscapeCoordinatorCancelsBoardRenameBeforeWindowDismissal() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(
        hasBoardRename: true,
        hasBoardPicker: true,
        hasSelection: true
      )),
      .boardRename
    )
  }

  func testEscapeCoordinatorClosesBoardPickerBeforeOtherCanvasSurfaces() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(
        hasBoardPicker: true,
        hasCommandPalette: true,
        hasActiveEditor: true,
        hasSelection: true
      )),
      .boardPicker
    )
  }

  func testEscapeCoordinatorClosesDeleteConfirmationBeforeBoardRename() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(
        hasBoardDeletionConfirmation: true,
        hasBoardRename: true
      )),
      .boardDeletionConfirmation
    )
  }

  func testEscapeCoordinatorClosesTintPickerBeforeLowerPriorityActions() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(
        hasTintPicker: true,
        hasActiveTool: true,
        hasSelection: true
      )),
      .tintPicker
    )
  }

  func testEscapeCoordinatorKeepsTextEditingAboveDrawingAndWindowDismissal() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(
        hasActiveEditor: true,
        hasDrawingDraft: true,
        hasActiveTool: true,
        hasSelection: true
      )),
      .activeEditor
    )
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState()),
      .windowDismissal
    )
  }

  func testEscapeCoordinatorCancelsDrawingBeforeClosingAnInlineVectorEditor() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(
        hasActiveEditor: true,
        hasActiveVectorEditor: true,
        hasDrawingDraft: true,
        hasActiveTool: true
      )),
      .drawingDraft
    )
  }

  func testEscapeCancelsInProgressVectorDraftBeforeLeavingTheTool() {
    XCTAssertEqual(
      ComposerEscapeCoordinator.target(for: ComposerEscapeState(
        hasDrawingDraft: true,
        hasActiveTool: true)),
      .drawingDraft)
  }
}
