import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One ambiguity finding located in a specific card. The UI re-locates `phrase` in the live text
/// when distributing results because a card may have changed while the on-device pass was running.
struct BoardLintFinding: Equatable, Sendable {
  let cardID: UUID
  let phrase: String
  let kind: LintKind
  let question: String
  let suggestions: [String]
  let relatedCardIDs: [UUID]
}

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

  /// Analyze every card in one pass so the model can detect cross-card contradictions and missing
  /// context. The card order supplied by the board is the stable 1-based index used in the prompt.
  /// A deliberately conservative size cap avoids asking the on-device model to reason over a prompt
  /// it cannot fit; callers can simply retry after narrowing the board.
  func analyzeBoard(cards: [(id: UUID, visibleText: String, plainText: String)]) async -> [BoardLintFinding] {
    let combinedVisibleCharacterCount = cards.reduce(into: 0) { $0 += $1.visibleText.count }
    guard combinedVisibleCharacterCount >= 12, combinedVisibleCharacterCount <= 8_000 else { return [] }
    guard isAvailable else { return [] }

    let contexts = cards.map { ConnectorLintContext(plainText: $0.plainText) }

    #if canImport(FoundationModels)
    guard #available(macOS 26, *) else { return [] }
    do {
      // Stateless on purpose: board passes must not retain prior prompt text or build an ever-growing
      // model transcript as the user edits.
      let session = LanguageModelSession(instructions: Self.boardInstructions)
      let response = try await session.respond(to: Self.boardPrompt(cards: cards, contexts: contexts),
                                               generating: BoardLintResult.self)
      return response.content.issues.compactMap { issue in
        let sourceIndex = issue.cardIndex - 1
        guard cards.indices.contains(sourceIndex) else { return nil }
        let source = cards[sourceIndex]
        let range = (source.visibleText as NSString).range(of: issue.phrase)
        guard !issue.phrase.isEmpty, range.location != NSNotFound, range.length > 0,
              !Self.rangeTouchesImagePlaceholder(range, in: source.visibleText)
        else { return nil }

        let kind = issue.kind.domain
        let rawQuestion = issue.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuestion.isEmpty else { return nil }
        let question = rawQuestion.hasSuffix("?") ? rawQuestion : rawQuestion + "?"
        guard question.split(whereSeparator: { $0.isWhitespace }).count <= 8 else { return nil }

        let flag = LintFlag(
          phrase: issue.phrase,
          kind: kind,
          question: question,
          suggestions: [],
          range: range,
          rectInView: nil)
        guard contexts[sourceIndex].shouldKeep(flag) else { return nil }

        let suggestions = issue.suggestions
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty && $0 != issue.phrase }

        var relatedCardIDs: [UUID] = []
        if kind == .conflicting || kind == .missingContext {
          for relatedIndex in issue.relatedCardIndices {
            let index = relatedIndex - 1
            guard cards.indices.contains(index) else { continue }
            let relatedID = cards[index].id
            guard relatedID != source.id, !relatedCardIDs.contains(relatedID) else { continue }
            relatedCardIDs.append(relatedID)
          }
        }

        return BoardLintFinding(
          cardID: source.id,
          phrase: issue.phrase,
          kind: kind,
          question: question,
          suggestions: Array(suggestions.prefix(3)),
          relatedCardIDs: relatedCardIDs)
      }
    } catch {
      // Refusals and context-window failures are intentionally invisible, matching analyze().
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

  /// The board pass inherits the precision rules above, but its output must identify both the card
  /// containing the phrase and any cards that supply the contradiction or missing context.
  static let boardInstructions = instructions + """

  You are now linting a WHOLE board, not one read-only card plus sibling context. You may flag a
  phrase in any numbered card, but only when it is genuinely ambiguous. For every issue, return
  the 1-based cardIndex of the card containing the verbatim phrase. For `conflicting` and
  `missingContext`, also return relatedCardIndices for the other numbered cards needed to explain
  the finding. Do not list the source card itself as related. For every other kind, return an empty
  relatedCardIndices list. A phrase is not ambiguous merely because another card exists.
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

  private static func boardPrompt(cards: [(id: UUID, visibleText: String, plainText: String)],
                                  contexts: [ConnectorLintContext]) -> String {
    var prompt = "Analyze every numbered card below in one board-level pass. Return only genuinely ambiguous phrases."
    for (index, card) in cards.enumerated() {
      prompt += """


      Card \(index + 1)
      Resolved connector context:
      \(contexts[index].summary)
      Visible draft to quote phrases from:
      \(card.visibleText)
      """
    }
    return prompt
  }
}

// MARK: - Connector context supplied to the linter

private struct ConnectorLintContext {
  let summary: String
  let hasContext7: Bool
  let hasGitHub: Bool
  let hasFinder: Bool
  let hasICloud: Bool
  let hasBrowser: Bool
  let hasLinear: Bool
  let hasNotion: Bool
  let hasNotes: Bool
  let hasSentry: Bool
  let hasFigma: Bool
  let hasXcode: Bool

  private var resolvedConnectorCount: Int {
    [hasContext7, hasGitHub, hasFinder, hasICloud, hasBrowser, hasLinear, hasNotion, hasNotes, hasSentry, hasFigma, hasXcode].filter { $0 }.count
  }

  init(plainText: String) {
    let tokens = AppToken.scan(plainText)
    var lines: [String] = []
    var context7 = false, github = false, finder = false, icloud = false, browser = false, linear = false, notion = false, notes = false, sentry = false, figma = false, xcode = false

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
      case let .icloud(reference):
        icloud = true
        lines.append("- iCloud Drive reference selected: \(reference.path).")
      case let .browser(reference):
        browser = true
        lines.append("- Browser tab selected: \(reference.title.isEmpty ? reference.url : reference.title), URL \(reference.url).")
      case let .linear(reference):
        linear = true
        lines.append("- Linear issue selected: \(reference.identifier) (id \(reference.id)).")
      case let .notion(reference):
        notion = true
        lines.append("- Notion page selected: \(reference.title.isEmpty ? reference.id : reference.title).")
      case let .notes(reference):
        notes = true
        lines.append("- Apple Notes note selected: \(reference.title.isEmpty ? reference.id : reference.title).")
      case let .sentry(reference):
        sentry = true
        lines.append("- Sentry issue selected: \(reference.shortID) (org \(reference.org)).")
      case let .figma(reference):
        figma = true
        let label = reference.name.isEmpty ? reference.fileKey : reference.name
        lines.append("- Figma frame selected: \(label) (key \(reference.fileKey)).")
      case let .xcode(reference):
        xcode = true
        lines.append("- Xcode result selected: \(reference.resultPath).")
      case .none:
        lines.append("- Unresolved connector token present: \(entry.appID).")
      }
    }

    self.summary = lines.isEmpty ? "- No resolved connectors." : lines.joined(separator: "\n")
    self.hasContext7 = context7
    self.hasGitHub = github
    self.hasFinder = finder
    self.hasICloud = icloud
    self.hasBrowser = browser
    self.hasLinear = linear
    self.hasNotion = notion
    self.hasNotes = notes
    self.hasSentry = sentry
    self.hasFigma = figma
    self.hasXcode = xcode
  }

  func shouldKeep(_ flag: LintFlag) -> Bool {
    let phrase = flag.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty, !phrase.contains("@"), !phrase.contains("\u{fffc}") else { return false }

    let lower = phrase.lowercased()
    if flag.kind == .unresolvedReference || flag.kind == .missingContext {
      if hasContext7, containsAny(lower, ["context7", "docs", "documentation", "api", "apis", "library", "libraries", "version", "versions", "examples"]) { return false }
      if hasGitHub, containsAny(lower, ["github", "issue", "issues", "pr", "prs", "pull request", "pull requests", "ticket", "acceptance criteria"]) { return false }
      if hasFinder, containsAny(lower, ["finder", "file", "files", "folder", "folders", "path", "local", "contents", "listing"]) { return false }
      if hasICloud, containsAny(lower, ["icloud", "icloud drive", "cloud", "file", "files", "folder", "document", "synced"]) { return false }
      if hasBrowser, containsAny(lower, ["browser", "tab", "page", "url", "site", "website", "link", "host", "title"]) { return false }
      if hasLinear, containsAny(lower, ["linear", "issue", "issues", "ticket", "tickets", "acceptance criteria", "spec", "story", "task"]) { return false }
      if hasNotion, containsAny(lower, ["notion", "page", "doc", "docs", "spec", "rfc", "document", "wiki", "notes"]) { return false }
      if hasNotes, containsAny(lower, ["note", "notes", "apple notes", "memo", "jot", "reminder"]) { return false }
      if hasSentry, containsAny(lower, ["sentry", "error", "errors", "exception", "stack trace", "stacktrace", "crash", "bug"]) { return false }
      if hasFigma, containsAny(lower, ["figma", "frame", "design", "mockup", "screen", "ui", "component", "layout", "wireframe"]) { return false }
      if hasXcode, containsAny(lower, ["xcode", "build", "compile", "compiler", "test", "tests", "failure", "failing"]) { return false }

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

/// Guided board-level output: indexes keep the model away from fragile UUIDs while the service maps
/// results back to real cards and verifies every quoted phrase against that card's current text.
@available(macOS 26, *)
@Generable
private struct BoardLintResult {
  @Guide(description: "Every genuinely ambiguous phrase on this board. Empty if all cards are clear.")
  let issues: [BoardLintIssue]
}

@available(macOS 26, *)
@Generable
private struct BoardLintIssue {
  @Guide(description: "The 1-based number of the card containing phrase.")
  let cardIndex: Int

  @Guide(description: "The ambiguous phrase copied word-for-word from the named card.")
  let phrase: String

  @Guide(description: "What kind of ambiguity this is.")
  let kind: LintIssueKind

  @Guide(description: "One short clarifying question for the author. Max 8 words, ending with '?'.")
  let question: String

  @Guide(description: "Up to 3 rewrites of phrase, each a drop-in replacement that resolves the ambiguity.")
  let suggestions: [String]

  @Guide(description: "Other 1-based card numbers needed for conflicting or missingContext; empty for all other kinds.")
  let relatedCardIndices: [Int]
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
