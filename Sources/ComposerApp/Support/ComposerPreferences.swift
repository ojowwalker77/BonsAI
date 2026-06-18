import AppKit
import Foundation

/// User-tunable appearance controls shared by SwiftUI surfaces and AppKit text views.
enum ComposerPreferences {
  static let editorFontSizeKey = "composer.editor.fontPointSize"
  static let panelTransparencyKey = "composer.panel.backgroundTransparency"

  static let minEditorFontSize: CGFloat = 11
  static let maxEditorFontSize: CGFloat = 28
  static let fontSizeStep: CGFloat = 1

  static let defaultPanelTransparency = 0.18
  static let maxPanelTransparency = 0.72

  private static var defaultEditorFontSize: CGFloat {
    NSFont.preferredFont(forTextStyle: .body).pointSize + 2
  }

  static var editorFontSize: CGFloat {
    let stored = UserDefaults.standard.object(forKey: editorFontSizeKey) as? NSNumber
    return clamp(CGFloat(stored?.doubleValue ?? Double(defaultEditorFontSize)), minEditorFontSize, maxEditorFontSize)
  }

  static var editorFont: NSFont {
    NSFont.systemFont(ofSize: editorFontSize)
  }

  @discardableResult
  static func adjustEditorFontSize(by delta: CGFloat) -> CGFloat {
    let next = clamp(editorFontSize + delta, minEditorFontSize, maxEditorFontSize)
    UserDefaults.standard.set(Double(next), forKey: editorFontSizeKey)
    NotificationCenter.default.post(name: .composerFontSizeChanged, object: nil, userInfo: ["size": next])
    return next
  }

  @discardableResult
  static func resetEditorFontSize() -> CGFloat {
    UserDefaults.standard.removeObject(forKey: editorFontSizeKey)
    let size = editorFontSize
    NotificationCenter.default.post(name: .composerFontSizeChanged, object: nil, userInfo: ["size": size])
    return size
  }

  static func handleEditorFontKeyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    guard flags == [.command] || flags == [.command, .shift] else { return false }

    let raw = event.charactersIgnoringModifiers?.lowercased()
    let modified = event.characters?.lowercased()
    if raw == "=" || modified == "+" {
      adjustEditorFontSize(by: fontSizeStep)
      return true
    }
    if raw == "-" || modified == "_" {
      adjustEditorFontSize(by: -fontSizeStep)
      return true
    }
    return false
  }

  static func clampedPanelTransparency(_ value: Double) -> Double {
    min(max(value, 0), maxPanelTransparency)
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}
