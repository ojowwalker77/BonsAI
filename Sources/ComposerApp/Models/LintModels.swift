import SwiftUI
import AppKit

// MARK: - Ambiguity kinds

/// The categories the on-device linter can flag. Deliberately small and concrete —
/// each maps to a distinct icon + tint so the feedback is actionable, not a generic
/// "this is bad". Always-available (no macOS 26 gating) so the UI never needs guards.
enum LintKind: String, Equatable, CaseIterable, Sendable {
  /// "it", "this", "the function" — a referent with multiple or unclear candidates.
  case unresolvedReference
  /// "larger", "faster" — a change with no stated axis, amount, or target.
  case unspecifiedDimension
  /// "clean it up", "make it nice" — an unmeasurable directive.
  case vague
  /// An instruction that contradicts another part of the draft.
  case conflicting
  /// "like we discussed" — refers to knowledge the agent can't see.
  case missingContext

  var label: String {
    switch self {
    case .unresolvedReference: "Ambiguous reference"
    case .unspecifiedDimension: "Unspecified dimension"
    case .vague: "Vague — no success criterion"
    case .conflicting: "Possible contradiction"
    case .missingContext: "Missing context"
    }
  }

  var symbol: String {
    switch self {
    case .unresolvedReference: "questionmark.circle.fill"
    case .unspecifiedDimension: "arrow.up.left.and.arrow.down.right.circle.fill"
    case .vague: "scribble.variable"
    case .conflicting: "exclamationmark.triangle.fill"
    case .missingContext: "eye.slash.fill"
    }
  }

  /// Underlines stay amber/yellow (a *risk*, not an *error*); only a real
  /// contradiction earns red. This keeps the sentinel from feeling like it's scolding.
  var nsTint: NSColor {
    switch self {
    case .unresolvedReference: .systemOrange
    case .unspecifiedDimension: .systemOrange
    case .vague: .systemYellow
    case .conflicting: .systemRed
    case .missingContext: .systemPurple
    }
  }

  var tint: Color { Color(nsColor: nsTint) }
}

// MARK: - A single flagged span

/// One ambiguous span the linter surfaced. `range` is in UTF-16 units against the
/// text view's `string`; `rectInView` is filled in by the coordinator (panel space)
/// so the popover can anchor without re-reaching into AppKit geometry.
struct LintFlag: Identifiable, Equatable {
  let id = UUID()
  let phrase: String
  let kind: LintKind
  let question: String
  let suggestions: [String]
  var range: NSRange
  var rectInView: CGRect?
}

// MARK: - Published state (the MentionState analog)

/// Drives the invisible-linter overlay. The coordinator owns the truth; this is the
/// bridge the SwiftUI canvas observes.
@MainActor
final class LintState: ObservableObject {
  @Published var flags: [LintFlag] = []
  /// The flag currently hovered (its popover is showing), or nil.
  @Published var activeFlagID: UUID?

  /// Set by the coordinator so the popover can keep itself alive while the mouse is
  /// inside it (otherwise crossing the gap from underline → popover would dismiss it).
  var cancelHide: (() -> Void)?
  var requestHide: (() -> Void)?

  var activeFlag: LintFlag? { flags.first { $0.id == activeFlagID } }
}
