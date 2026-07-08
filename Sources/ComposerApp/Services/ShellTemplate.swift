import Foundation

/// Resolves a board's copy-time shell syntax. A board is "one thing", so this operates on the whole
/// board's joined text — a variable defined in one card is visible to every other card.
///
/// Three constructs, expanded by `SelfContainedRenderer` only when the user has opted in (Settings ▸
/// Connectors ▸ "Resolve shell at copy time") and confirmed the run:
///
/// - **Command** — `$(command)` runs `command` and is replaced by its stdout (bash command
///   substitution; works anywhere, including inside a variable's value).
/// - **Definition** — `name=(value)` defines a board-scoped variable. The parentheses bound the
///   value, so a definition can sit mid-sentence; `value` may be a chip, a `$(…)` command, another
///   `$ref`, or plain text. Definitions are *consumed* at copy time — they're plumbing.
/// - **Reference** — `$name` or `${name}` expands to a defined variable's value. Only names actually
///   defined on the board match, so `$5` or `$HOME` in prose are left untouched.
///
/// Only the literal source persists in the card text; expansion is recomputed on every copy. A
/// command that fails is left literal and reported, so a copy never silently mangles what you wrote.
enum ShellTemplate {
  /// One styled span (for the editor + rendered card). Resolution does not go through this.
  struct Expression: Equatable {
    let range: NSRange
    let kind: Kind
  }

  enum Kind: Equatable {
    case command(String)            // $(cmd) — green code
    case definition(name: String)   // the `name` of `name=(…)` — violet
    case reference(name: String)    // $name / ${name}, defined on the board — violet
  }

  /// A parsed `name=(value)` occurrence: `full` spans `name` through the closing paren.
  private struct Definition {
    let full: NSRange
    let name: NSRange
    let value: String
  }

  // `$(...)` — no nested parens (a documented limitation; commands rarely need a literal `)`).
  private static let commandRegex = try! NSRegularExpression(pattern: #"\$\(([^()]*)\)"#)
  // The opening of a `name=(` (the value runs to the balanced close paren, found by hand).
  private static let definitionStartRegex = try! NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*\("#)
  private static let bracedRefRegex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
  private static let bareRefRegex = try! NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#)

  // MARK: Queries (styling, confirmation)

  /// Names defined by `name=(value)` anywhere in `plain`.
  static func definedNames(in plain: String) -> Set<String> {
    let ns = plain as NSString
    return Set(definitions(in: plain).map { ns.substring(with: $0.name) })
  }

  /// Every `$(…)` command in source order — drives the pre-copy confirmation and the count.
  static func commands(in plain: String) -> [String] {
    let ns = plain as NSString
    return commandRegex.matches(in: plain, range: NSRange(location: 0, length: ns.length)).map {
      ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }
  }

  /// Styled spans for `plain`, in source order, non-overlapping. `definedNames` (board-scoped)
  /// decides which `$name` count as references; commands and definition names are self-evident.
  static func expressions(in plain: String, definedNames: Set<String>) -> [Expression] {
    let ns = plain as NSString
    let full = NSRange(location: 0, length: ns.length)
    var found: [Expression] = []

    for match in commandRegex.matches(in: plain, range: full) {
      let command = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
      found.append(Expression(range: match.range, kind: .command(command)))
    }
    // Highlight only the name, so a chip / `$(…)` / `$ref` inside the value styles on its own.
    for definition in definitions(in: plain) {
      found.append(Expression(range: definition.name, kind: .definition(name: ns.substring(with: definition.name))))
    }
    for regex in [bracedRefRegex, bareRefRegex] {
      for match in regex.matches(in: plain, range: full) {
        let name = ns.substring(with: match.range(at: 1))
        if definedNames.contains(name) { found.append(Expression(range: match.range, kind: .reference(name: name))) }
      }
    }
    return dropOverlaps(found.sorted { $0.range.location < $1.range.location })
  }

  // MARK: Expansion (the actual copy-time resolution)

  /// Expand the whole board: run commands, bind variables, substitute references, and drop the
  /// definitions. `run` executes one command; returns nil if the shell can't launch.
  ///
  /// `runCommands` gates *command execution* only — variable substitution is pure text and always
  /// happens (so `file=(@index.ts)` + `$file` resolves with no shell run). When it's false, `$(…)`
  /// is left literal (the caller explains why), but definitions and references still resolve.
  static func expand(
    _ plain: String,
    runCommands: Bool = true,
    run: (String) async -> Shell.Result?
  ) async -> (text: String, failures: [String]) {
    let ns = plain as NSString
    let full = NSRange(location: 0, length: ns.length)

    let defs = definitions(in: plain)
    var bindings: [String: String] = [:]
    var failures: [String] = []
    // Per-copy cache so an identical command (written twice, or via a variable) runs once.
    var cache: [String: String?] = [:]

    // Resolve each definition's value in source order (so a value can reference an earlier one).
    for definition in defs {
      let name = ns.substring(with: definition.name)
      bindings[name] = await substitute(definition.value, bindings: bindings, runCommands: runCommands, run: run, cache: &cache, failures: &failures)
    }

    var replacements: [(range: NSRange, text: String)] = []

    // Consume each definition (plus one adjacent space/newline so it doesn't leave a hole).
    for definition in defs {
      var range = definition.full
      let end = range.location + range.length
      if end < ns.length {
        let next = ns.character(at: end)
        if next == 0x20 || next == 0x09 || next == 0x0A { range.length += 1 }
      }
      replacements.append((range, ""))
    }

    func insideDefinition(_ range: NSRange) -> Bool {
      defs.contains { NSLocationInRange(range.location, $0.full) }
    }

    // Commands in free text (those inside definition values already ran above).
    for match in commandRegex.matches(in: plain, range: full) where !insideDefinition(match.range) {
      let command = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
      if let out = await output(of: command, runCommands: runCommands, run: run, cache: &cache, failures: &failures) {
        replacements.append((match.range, out))
      }
    }
    // References in free text → bound value.
    for regex in [bracedRefRegex, bareRefRegex] {
      for match in regex.matches(in: plain, range: full) where !insideDefinition(match.range) {
        let name = ns.substring(with: match.range(at: 1))
        if let value = bindings[name] { replacements.append((match.range, value)) }
      }
    }

    // Splice back to front, dropping overlaps (a `$ref` nested inside a `$(…)` defers to the command).
    let result = NSMutableString(string: plain)
    for replacement in dropOverlaps(replacements).sorted(by: { $0.range.location > $1.range.location }) {
      result.replaceCharacters(in: replacement.range, with: replacement.text)
    }

    // Consumed definitions can leave a gap: collapse runs of blank lines / spaces, then trim edges.
    let text = (result as String)
      .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (text, failures)
  }

  // MARK: Internals

  /// Parse `name=(value)` occurrences, matching the value's parentheses by hand so it can contain a
  /// `$(…)` command. Skips a candidate that sits inside a `$(…)` command.
  private static func definitions(in plain: String) -> [Definition] {
    let ns = plain as NSString
    let full = NSRange(location: 0, length: ns.length)
    let commandRanges = commandRegex.matches(in: plain, range: full).map(\.range)
    var out: [Definition] = []

    for match in definitionStartRegex.matches(in: plain, range: full) {
      if commandRanges.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
      let open = match.range.location + match.range.length - 1   // index of the '('
      var depth = 1
      var index = open + 1
      while index < ns.length {
        let char = ns.character(at: index)
        if char == 0x28 { depth += 1 }                           // (
        else if char == 0x29 { depth -= 1; if depth == 0 { break } }  // )
        index += 1
      }
      guard depth == 0 else { continue }                         // unbalanced → not a definition
      let valueRange = NSRange(location: open + 1, length: index - open - 1)
      out.append(Definition(
        full: NSRange(location: match.range.location, length: index - match.range.location + 1),
        name: match.range(at: 1),
        value: ns.substring(with: valueRange)))
    }
    return out
  }

  /// Resolve a single definition's value: run its `$(…)` and expand references to already-bound vars.
  private static func substitute(
    _ value: String,
    bindings: [String: String],
    runCommands: Bool,
    run: (String) async -> Shell.Result?,
    cache: inout [String: String?],
    failures: inout [String]
  ) async -> String {
    let ns = value as NSString
    let full = NSRange(location: 0, length: ns.length)
    var replacements: [(range: NSRange, text: String)] = []

    for match in commandRegex.matches(in: value, range: full) {
      let command = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
      if let out = await output(of: command, runCommands: runCommands, run: run, cache: &cache, failures: &failures) {
        replacements.append((match.range, out))
      }
    }
    for regex in [bracedRefRegex, bareRefRegex] {
      for match in regex.matches(in: value, range: full) {
        let name = ns.substring(with: match.range(at: 1))
        if let bound = bindings[name] { replacements.append((match.range, bound)) }
      }
    }

    let result = NSMutableString(string: value)
    for replacement in dropOverlaps(replacements).sorted(by: { $0.range.location > $1.range.location }) {
      result.replaceCharacters(in: replacement.range, with: replacement.text)
    }
    return (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func output(
    of command: String,
    runCommands: Bool,
    run: (String) async -> Shell.Result?,
    cache: inout [String: String?],
    failures: inout [String]
  ) async -> String? {
    if let cached = cache[command] { return cached }   // already ran (success or failure) — reuse, no re-run
    guard runCommands, !command.isEmpty else { return nil }   // disabled → leave the `$(…)` literal, don't cache
    guard let result = await run(command) else {
      failures.append("`%@`: could not launch the shell.".localizedUI(command))
      cache.updateValue(nil, forKey: command)
      return nil
    }
    guard result.status == 0 else {
      let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let diagnostic = stderr.isEmpty ? stdout : stderr
      failures.append("`%@` exited %d: %@".localizedUI(command, Int(result.status), diagnostic.isEmpty ? "no output".localizedUI : diagnostic))
      cache.updateValue(nil, forKey: command)
      return nil
    }
    let out = result.stdout.trimmingCharacters(in: .newlines)
    cache[command] = out
    return out
  }

  /// Keep the earliest of any overlapping ranges (an outer `$(…)` wins over a `$ref` nested in it).
  private static func dropOverlaps(_ expressions: [Expression]) -> [Expression] {
    var out: [Expression] = []
    var end = -1
    for expression in expressions where expression.range.location >= end {
      out.append(expression)
      end = expression.range.location + expression.range.length
    }
    return out
  }

  private static func dropOverlaps(_ items: [(range: NSRange, text: String)]) -> [(range: NSRange, text: String)] {
    let sorted = items.sorted { $0.range.location < $1.range.location }
    var out: [(range: NSRange, text: String)] = []
    var end = -1
    for item in sorted where item.range.location >= end {
      out.append(item)
      end = item.range.location + item.range.length
    }
    return out
  }
}
