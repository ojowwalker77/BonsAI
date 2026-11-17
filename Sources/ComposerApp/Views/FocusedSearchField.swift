import AppKit
import SwiftUI

/// An `NSTextField` that grabs first responder when it appears (SwiftUI `@FocusState`
/// is unreliable in a non-activating panel) and routes arrow/return/escape to callbacks.
struct FocusedSearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  /// Defaults to the editor font; chrome surfaces (⌘K palette) pass a system font instead — the
  /// custom app fonts (Nohemi/Satoshi) declare tighter vertical metrics than their glyph bounds,
  /// so NSTextField baselines them too high and clips the ascenders.
  var font: NSFont = Theme.Typography.body
  var onMoveUp: () -> Void
  var onMoveDown: () -> Void
  var onCommit: () -> Void
  var onCancel: () -> Void

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.delegate = context.coordinator
    field.placeholderString = placeholder
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = font
    field.textColor = Theme.nsBodyText
    field.cell?.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.lineBreakMode = .byTruncatingTail
    DispatchQueue.main.async { [weak field] in
      guard let field, let window = field.window else { return }
      window.makeFirstResponder(field)
    }
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    field.font = font
    field.textColor = Theme.nsBodyText
    if field.placeholderString != placeholder { field.placeholderString = placeholder }
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: FocusedSearchField
    init(_ parent: FocusedSearchField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.moveUp(_:)): parent.onMoveUp(); return true
      case #selector(NSResponder.moveDown(_:)): parent.onMoveDown(); return true
      case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
        parent.onCommit(); return true
      case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
      default: return false
      }
    }
  }
}
