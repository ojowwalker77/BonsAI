import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The invisible semantic linter, backed by Apple's on-device Foundation Model.
///
/// Runs **fully on-device**: free per call, private (drafts never leave the Mac),
/// offline. That's why it can run unprompted on every typing pause — a cloud round
/// trip per pause would be neither affordable nor private. The task here is pure
/// extraction/classification ("which phrase is ambiguous"), which is squarely in a
/// ~3B on-device model's wheelhouse, not the reasoning/knowledge it's weak at.
///
/// Silently no-ops when Apple Intelligence is unavailable (Intel Mac, AI disabled,
/// model still downloading) — the feature just turns itself off, nothing breaks.
@MainActor
final class SemanticLintService {
  static let shared = SemanticLintService()
  private init() {}

  /// Retains a warmed session so the model assets are loaded before the first real
  /// analysis. Untyped because the type is gated behind macOS 26.
  private var warm: AnyObject?

  /// True only when the on-device model is ready to answer right now.
  var isAvailable: Bool {
    guard #available(macOS 26, *) else { return false }
    #if canImport(FoundationModels)
    if case .available = SystemLanguageModel.default.availability { return true }
    return false
    #else
    return false
    #endif
  }

  /// Warm the model so the first pause doesn't pay cold-start latency. Cheap no-op
  /// when unavailable.
  func prewarm() {
    guard isAvailable else { return }
    #if canImport(FoundationModels)
    guard #available(macOS 26, *) else { return }
    let session = LanguageModelSession(instructions: Self.instructions)
    session.prewarm()
    warm = session
    #endif
  }

  /// Analyze a draft and return the ambiguous spans. Returns `[]` for trivial drafts
  /// or when the model is unavailable — callers don't special-case anything.
  func analyze(_ text: String) async -> [LintFlag] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Skip drafts too short to be ambiguous, and too long for the on-device context.
    guard trimmed.count >= 12, trimmed.count <= 4000 else { return [] }
    guard isAvailable else { return [] }

    #if canImport(FoundationModels)
    guard #available(macOS 26, *) else { return [] }
    do {
      // A fresh, stateless session per pass: each analysis is independent, and a
      // growing transcript would only waste the small context window.
      let session = LanguageModelSession(instructions: Self.instructions)
      let response = try await session.respond(to: Self.userPrompt(for: text),
                                               generating: LintResult.self)
      return response.content.issues.compactMap { $0.toFlag(in: text) }
    } catch {
      // Guardrail refusals, context overflow, etc. — stay silent, never surface an error.
      return []
    }
    #else
    return []
    #endif
  }

  // MARK: - Prompt (the product's brain)

  /// Bias hard toward precision. An *unprompted* squiggle nobody asked for is far more
  /// annoying than a missed one, so the model is told: when in doubt, don't flag.
  static let instructions = """
  You are a precise semantic-ambiguity linter built into a tool where a developer drafts \
  prompts to hand to an AI coding agent. You read the draft and flag ONLY phrases that are \
  genuinely ambiguous or underspecified — places where a competent engineer would have to \
  guess and could reasonably build two different things.

  Be conservative. Most text is fine. When in doubt, do NOT flag. Never flag grammar, \
  spelling, tone, politeness, or style. Never flag a phrase merely for being short. Do not \
  rewrite or summarize the whole draft. Aim for zero false positives: a wrong flag is worse \
  than a missed one.

  Flag a phrase only if it fits one of these kinds:
  - unresolvedReference: a pronoun or noun phrase ("it", "this", "the function", "the client") \
  whose target is unclear or has multiple candidates.
  - unspecifiedDimension: a comparative or change ("larger", "faster", "better", "more") with \
  no stated axis, amount, or target — e.g. "larger" could mean taller or wider.
  - vague: an unmeasurable directive ("clean it up", "make it nice", "handle it properly") with \
  no concrete success criterion.
  - conflicting: an instruction that contradicts another part of the draft.
  - missingContext: a reference to knowledge the coding agent cannot see ("like we discussed", \
  "the usual way", "same as before").

  Tokens that start with "@" (such as @github, @context7) and the object-replacement character \
  are already-resolved references — never flag them.

  For each flagged phrase return:
  - phrase: copied verbatim from the draft, exactly as written, so it can be located.
  - kind: the single best-fitting kind.
  - question: one short clarifying question, max 8 words, ending with "?".
  - suggestions: 0 to 3 concrete rewrites of the phrase, each a drop-in replacement that \
  resolves the ambiguity.

  If nothing is genuinely ambiguous, return an empty list of issues.
  """

  static func userPrompt(for text: String) -> String {
    "Analyze this draft prompt and return its ambiguous spans:\n\n\(text)"
  }
}

// MARK: - On-device structured output (guided generation)

#if canImport(FoundationModels)

/// The model is *constrained* to fill this shape — no JSON parsing, no malformed output.
@available(macOS 26, *)
@Generable
private struct LintResult {
  @Guide(description: "Every genuinely ambiguous phrase in the draft. Empty if it's already clear.")
  let issues: [LintIssue]
}

@available(macOS 26, *)
@Generable
private struct LintIssue {
  @Guide(description: "The ambiguous phrase, copied word-for-word from the draft so it can be located.")
  let phrase: String

  @Guide(description: "What kind of ambiguity this is.")
  let kind: LintIssueKind

  @Guide(description: "One short clarifying question for the author. Max 8 words, ending with '?'.")
  let question: String

  @Guide(description: "Up to 3 rewrites of the phrase, each a drop-in replacement that removes the ambiguity.")
  let suggestions: [String]
}

@available(macOS 26, *)
@Generable
private enum LintIssueKind {
  case unresolvedReference
  case unspecifiedDimension
  case vague
  case conflicting
  case missingContext
}

// MARK: - Map the model's output back into a locatable domain flag

@available(macOS 26, *)
private extension LintIssue {
  /// Small models are unreliable at character offsets, so we never ask for them — we
  /// ask for the verbatim phrase and locate it ourselves. Drop anything we can't find
  /// (a paraphrase rather than a true quote) rather than mis-highlighting.
  func toFlag(in text: String) -> LintFlag? {
    let ns = text as NSString
    let range = ns.range(of: phrase)
    guard range.location != NSNotFound, range.length > 0 else { return nil }

    let cleaned = suggestions
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0 != phrase }
    return LintFlag(phrase: phrase,
                    kind: kind.domain,
                    question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                    suggestions: Array(cleaned.prefix(3)),
                    range: range,
                    rectInView: nil)
  }
}

@available(macOS 26, *)
private extension LintIssueKind {
  var domain: LintKind {
    switch self {
    case .unresolvedReference: .unresolvedReference
    case .unspecifiedDimension: .unspecifiedDimension
    case .vague: .vague
    case .conflicting: .conflicting
    case .missingContext: .missingContext
    }
  }
}

#endif
