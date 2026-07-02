import AppKit
import SwiftUI
import XCTest

@testable import ComposerApp

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

  private func deleteSelectionFired(during body: () -> Void) -> Bool {
    var fired = false
    let observer = NotificationCenter.default.addObserver(
      forName: .composerDeleteSelection, object: nil, queue: nil) { _ in fired = true }
    body()
    NotificationCenter.default.removeObserver(observer)
    return fired
  }

  func testBackspaceOnBareCanvasDeletesSelection() {
    let panel = makePanel()
    XCTAssertTrue(panel.firstResponder === panel)

    let fired = deleteSelectionFired { panel.sendEvent(backspaceKeyDown(in: panel)) }

    XCTAssertTrue(fired, "with no text input editing, Backspace must delete the selected cards")
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
}
