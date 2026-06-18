import AppKit

// MARK: - Refine intents

/// The ways the whole-draft refine can reshape a brain dump. Each maps to a concrete
/// instruction handed to the engine. `tighten` is the default (the ⌘R fast path).
enum RefineIntent: String, CaseIterable, Identifiable {
  case tighten
  case concise
  case spec
  case checklist

  var id: String { rawValue }

  /// Default intent for the keyboard fast path.
  static let `default`: RefineIntent = .tighten

  var label: String {
    switch self {
    case .tighten: "Tighten"
    case .concise: "Concise"
    case .spec: "Spec"
    case .checklist: "Checklist"
    }
  }

  var detail: String {
    switch self {
    case .tighten: "Sharpen into a clear, unambiguous prompt"
    case .concise: "Cut to the essentials"
    case .spec: "Restructure as goal · requirements · constraints"
    case .checklist: "Turn into ordered, actionable steps"
    }
  }

  var symbol: String {
    switch self {
    case .tighten: "wand.and.stars"
    case .concise: "scissors"
    case .spec: "list.bullet.rectangle"
    case .checklist: "checklist"
    }
  }

  /// What this intent does to the draft, appended to the shared contract.
  private var directive: String {
    switch self {
    case .tighten:
      return "Rewrite the whole draft so it is clearer, more concrete, and unambiguous — resolve vague references, tighten loose sentences, and keep it lean. Preserve every concrete detail."
    case .concise:
      return "Cut the whole draft to its essentials: remove redundancy and filler, keep only what the coding agent actually needs. Preserve every concrete detail."
    case .spec:
      return "Restructure the whole draft as a precise, skimmable spec with short labelled sections — Goal, Requirements, Constraints (add Acceptance only if the draft implies it). Use terse bullet points."
    case .checklist:
      return "Restructure the whole draft as an ordered, actionable checklist of concrete steps the coding agent should take, most important first. One step per line."
    }
  }

  /// The full instruction: a shared contract (preserve voice + @tokens, no chatter) plus
  /// this intent's directive.
  var instruction: String {
    """
    You are refining a draft prompt that will be handed to a coding agent. \
    \(directive) Preserve the author's intent and voice. \
    Keep every @mention token (for example @context7, @github, @finder, and any with trailing ids) \
    EXACTLY as written — never rephrase them, fold them into prose, or drop them. \
    Do not add commentary, preamble, quotes, or markdown fences. Return ONLY the rewritten draft.
    """
  }
}

// MARK: - Board compile

/// The board-level "Compile to draft" action: merges every card into one ordered,
/// paste-ready prompt. Shares the per-draft contract (preserve voice + @tokens, no chatter).
enum BoardCompile {
  static let instruction = """
  You are given several note cards a developer brain-dumped onto a board. They are listed in \
  reading order (top-to-bottom, left-to-right) and together form ONE prompt for a coding agent. \
  Merge them into a single clean, ordered, paste-ready prompt: keep every concrete detail, \
  resolve cross-card references, remove duplication and filler, and add light structure (short \
  labelled sections or ordered steps) only where it genuinely helps. \
  Keep every @mention token (for example @context7, @github, @finder, @browser, and any with \
  trailing ids) EXACTLY as written — never rephrase them, fold them into prose, or drop them. \
  Preserve the author's intent and voice. Do not add commentary, preamble, quotes, or markdown \
  fences. Return ONLY the merged prompt.
  """
}

// MARK: - Refine UI state

/// Drives the whole-draft refine affordances: the intent menu and the post-refine
/// Keep/Revert bar. Mirrors the other contextual-overlay state objects so the editor
/// coordinator can dismiss it on Escape.
@MainActor
final class RefineState: ObservableObject {
  /// Intent picker is showing (anchored above the Refine pill).
  @Published var isMenuOpen = false
  /// Non-nil after a refine applies → the Keep/Revert bar is showing for this intent.
  @Published var pending: RefineIntent?

  /// The exact pre-refine document, kept so Revert restores chips losslessly.
  var original: NSAttributedString?
  /// Wired by the canvas so Escape can revert a pending refine.
  var revert: (() -> Void)?
}
