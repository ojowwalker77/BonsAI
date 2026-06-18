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

  /// Analyze a draft and return the ambiguous spans. `visibleText` is the NSTextView
  /// string used for ranges; `plainText` is the self-contained serialization that still
  /// contains raw connector tokens such as `@github:<url>` and `@context7:<library>`.
  /// Returns `[]` for trivial drafts or when the model is unavailable.
  func analyze(visibleText: String, plainText: String, boardContext: String? = nil) async -> [LintFlag] {
    let trimmed = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
    // Skip drafts too short to be ambiguous, and too long for the on-device context.
    guard trimmed.count >= 12, trimmed.count <= 4000 else { return [] }
    guard isAvailable else { return [] }

    let context = ConnectorLintContext(plainText: plainText)

    #if canImport(FoundationModels)
    guard #available(macOS 26, *) else { return [] }
    do {
      // A fresh, stateless session per pass: each analysis is independent, and a
      // growing transcript would only waste the small context window.
      let session = LanguageModelSession(instructions: Self.instructions)
      let response = try await session.respond(to: Self.userPrompt(visibleText: visibleText, context: context, boardContext: boardContext),
                                               generating: LintResult.self)
      return response.content.issues
        .compactMap { $0.toFlag(in: visibleText) }
        .filter { !Self.rangeTouchesImagePlaceholder($0.range, in: visibleText) }
        .filter { context.shouldKeep($0) }
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
  You are a precise semantic-ambiguity linter built into Composer, a scratchpad where a \
  user drafts prompts to copy into another AI tool later. You read the whole draft plus a \
  connector summary. Flag ONLY phrases that are genuinely ambiguous or underspecified — \
  places where a competent assistant would have to guess and could reasonably do two \
  different things.

  Be extremely conservative. Most text is fine. When in doubt, do NOT flag. Never flag \
  grammar, spelling, tone, politeness, or style. Never flag a phrase merely for being short. \
  Never flag a resolved connector chip or a phrase whose referent is supplied by the \
  connector summary. Aim for zero false positives: a wrong flag is worse than a missed one.

  This draft is ONE card on a larger board. When other cards are supplied as context they are \
  READ-ONLY: never quote or flag a phrase from them. Use them only to judge whether the current \
  card is genuinely ambiguous — if a sibling card defines a term or resolves a reference the \
  current card uses, do NOT flag it.

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

  Connector rules:
  - Context7 connector context resolves references to docs, documentation, APIs, libraries, \
    versions, examples, and the selected library/topic.
  - GitHub connector context resolves references to the selected issue, PR, pull request, \
    ticket, repo discussion, acceptance criteria, and linked URL.
  - Finder connector context resolves references to the selected local file/folder/path and \
    its contents/listing.
  - Browser connector context resolves references to the selected tab, page, URL, website, \
    title, host, and page metadata.
  - Tokens that start with "@", the object-replacement character, and `[image: ...]` \
    placeholders are resolved attachments/connectors; never flag them directly.

  For each flagged phrase return:
  - phrase: copied verbatim from the visible draft only, exactly as written, so it can be located.
  - kind: the single best-fitting kind.
  - question: one short clarifying question, max 8 words, ending with "?".
  - suggestions: 0 to 3 concrete rewrites of the phrase, each a drop-in replacement that \
  resolves the ambiguity.

  If nothing is genuinely ambiguous, return an empty list of issues.
  """

  private static func rangeTouchesImagePlaceholder(_ range: NSRange, in text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: #"\[image:\s*[^\]]+\]"#) else { return false }
    let full = NSRange(location: 0, length: (text as NSString).length)
    return regex.matches(in: text, range: full).contains { NSIntersectionRange($0.range, range).length > 0 }
  }

  private static func userPrompt(visibleText: String, context: ConnectorLintContext, boardContext: String?) -> String {
    var prompt = """
    Analyze this visible draft card and return only the truly ambiguous spans.

    Resolved connector context:
    \(context.summary)
    """
    if let boardContext, !boardContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      prompt += "\n\nOther cards on this board (READ-ONLY context — do NOT quote phrases from here):\n\(boardContext)"
    }
    prompt += "\n\nVisible draft to quote phrases from:\n\(visibleText)"
    return prompt
  }
}

// MARK: - Connector context supplied to the linter

private struct ConnectorLintContext {
  let summary: String
  let hasContext7: Bool
  let hasGitHub: Bool
  let hasFinder: Bool
  let hasBrowser: Bool

  private var resolvedConnectorCount: Int {
    [hasContext7, hasGitHub, hasFinder, hasBrowser].filter { $0 }.count
  }

  init(plainText: String) {
    let tokens = AppToken.scan(plainText)
    var lines: [String] = []
    var context7 = false, github = false, finder = false, browser = false

    for entry in tokens {
      switch entry.selection {
      case let .context7(libraryID, query):
        context7 = true
        lines.append("- Context7 docs selected: library `\(libraryID)`" + (query.map { ", topic `\($0)`" } ?? "") + ".")
      case let .github(kind, url):
        github = true
        lines.append("- GitHub \(kind == .pr ? "pull request" : "issue") selected: \(AppToken.shortGitHub(url)), URL \(url).")
      case let .finder(reference):
        finder = true
        lines.append("- Finder reference selected: \(reference.path).")
      case let .browser(reference):
        browser = true
        lines.append("- Browser tab selected: \(reference.title.isEmpty ? reference.url : reference.title), URL \(reference.url).")
      case .none:
        lines.append("- Unresolved connector token present: \(entry.appID).")
      }
    }

    self.summary = lines.isEmpty ? "- No resolved connectors." : lines.joined(separator: "\n")
    self.hasContext7 = context7
    self.hasGitHub = github
    self.hasFinder = finder
    self.hasBrowser = browser
  }

  func shouldKeep(_ flag: LintFlag) -> Bool {
    let phrase = flag.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty, !phrase.hasPrefix("@"), !phrase.contains("\u{fffc}") else { return false }

    let lower = phrase.lowercased()
    if flag.kind == .unresolvedReference || flag.kind == .missingContext {
      if hasContext7, containsAny(lower, ["context7", "docs", "documentation", "api", "apis", "library", "libraries", "version", "versions", "examples"]) { return false }
      if hasGitHub, containsAny(lower, ["github", "issue", "issues", "pr", "prs", "pull request", "pull requests", "ticket", "acceptance criteria"]) { return false }
      if hasFinder, containsAny(lower, ["finder", "file", "files", "folder", "folders", "path", "local", "contents", "listing"]) { return false }
      if hasBrowser, containsAny(lower, ["browser", "tab", "page", "url", "site", "website", "link", "host", "title"]) { return false }

      let pronouns: Set<String> = ["it", "this", "that", "these", "those", "this one", "that one", "the above", "above"]
      if resolvedConnectorCount == 1, pronouns.contains(lower) { return false }
    }

    return true
  }

  private func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
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
