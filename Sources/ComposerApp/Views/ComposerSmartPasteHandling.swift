import AppKit

/// Handles smart-paste resolution for a card editor (sync tokens + async Context7 lookup).
@MainActor
protocol ComposerSmartPasteHandling: AnyObject {
  func handleSmartPaste(_ pasted: String, in textView: ComposerTextView) -> Bool
}
