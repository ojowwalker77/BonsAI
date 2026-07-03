import Foundation
import Darwin

struct GraphExpression {
  private let root: Node

  init?(latex: String) {
    let body = Self.stripAssignment(from: latex)
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let tokens = Lexer(body).tokenize() else { return nil }
    var parser = Parser(tokens: tokens)
    guard let parsed = parser.parse(), parser.usedVariables.count <= 1 else { return nil }
    root = parsed
  }

  func evaluate(_ x: Double) -> Double {
    root.evaluate(x)
  }

  private static func stripAssignment(from latex: String) -> String {
    let pattern = #"^\s*[A-Za-z]+(?:\s*\(\s*[A-Za-z]+\s*\))?\s*=\s*"#
    guard let range = latex.range(of: pattern, options: .regularExpression) else { return latex }
    return String(latex[range.upperBound...])
  }
}

private enum Token: Equatable {
  case number(Double)
  case identifier(String)
  case command(String)
  case plus
  case minus
  case star
  case slash
  case caret
  case leftParen
  case rightParen
  case leftBrace
  case rightBrace
}

private struct Lexer {
  let source: String

  init(_ source: String) {
    self.source = source
  }

  func tokenize() -> [Token]? {
    var tokens: [Token] = []
    var index = source.startIndex

    while index < source.endIndex {
      let character = source[index]
      if character.isWhitespace {
        source.formIndex(after: &index)
        continue
      }

      if character == "\\" {
        source.formIndex(after: &index)
        let start = index
        while index < source.endIndex, source[index].isLetter {
          source.formIndex(after: &index)
        }
        guard start < index else { return nil }
        let name = String(source[start..<index]).lowercased()
        switch name {
        case "left", "right":
          continue
        case "cdot":
          tokens.append(.star)
        default:
          tokens.append(.command(name))
        }
        continue
      }

      if character.isNumber || character == "." {
        let start = index
        var dotCount = character == "." ? 1 : 0
        source.formIndex(after: &index)
        while index < source.endIndex {
          let next = source[index]
          if next == "." {
            dotCount += 1
            guard dotCount <= 1 else { return nil }
            source.formIndex(after: &index)
          } else if next.isNumber {
            source.formIndex(after: &index)
          } else {
            break
          }
        }
        guard let value = Double(source[start..<index]) else { return nil }
        tokens.append(.number(value))
        continue
      }

      if character.isLetter {
        let start = index
        source.formIndex(after: &index)
        while index < source.endIndex, source[index].isLetter {
          source.formIndex(after: &index)
        }
        tokens.append(.identifier(String(source[start..<index]).lowercased()))
        continue
      }

      switch character {
      case "+":
        tokens.append(.plus)
      case "-":
        tokens.append(.minus)
      case "*":
        tokens.append(.star)
      case "/":
        tokens.append(.slash)
      case "^":
        tokens.append(.caret)
      case "(":
        tokens.append(.leftParen)
      case ")":
        tokens.append(.rightParen)
      case "{":
        tokens.append(.leftBrace)
      case "}":
        tokens.append(.rightBrace)
      default:
        return nil
      }
      source.formIndex(after: &index)
    }

    return tokens
  }
}

private indirect enum Node {
  case number(Double)
  case variable
  case unaryMinus(Node)
  case add(Node, Node)
  case subtract(Node, Node)
  case multiply(Node, Node)
  case divide(Node, Node)
  case power(Node, Node)
  case function(Function, Node)

  func evaluate(_ x: Double) -> Double {
    switch self {
    case .number(let value):
      return value
    case .variable:
      return x
    case .unaryMinus(let value):
      return -value.evaluate(x)
    case .add(let lhs, let rhs):
      return lhs.evaluate(x) + rhs.evaluate(x)
    case .subtract(let lhs, let rhs):
      return lhs.evaluate(x) - rhs.evaluate(x)
    case .multiply(let lhs, let rhs):
      return lhs.evaluate(x) * rhs.evaluate(x)
    case .divide(let lhs, let rhs):
      return lhs.evaluate(x) / rhs.evaluate(x)
    case .power(let lhs, let rhs):
      return pow(lhs.evaluate(x), rhs.evaluate(x))
    case .function(let function, let value):
      return function.evaluate(value.evaluate(x))
    }
  }
}

private enum Function: String {
  case sin
  case cos
  case tan
  case exp
  case ln
  case log
  case sqrt

  func evaluate(_ value: Double) -> Double {
    switch self {
    case .sin:
      return Darwin.sin(value)
    case .cos:
      return Darwin.cos(value)
    case .tan:
      return Darwin.tan(value)
    case .exp:
      return Darwin.exp(value)
    case .ln:
      return Darwin.log(value)
    case .log:
      return Darwin.log10(value)
    case .sqrt:
      return Darwin.sqrt(value)
    }
  }
}

private struct Parser {
  let tokens: [Token]
  var index = 0
  var usedVariables: Set<String> = []

  mutating func parse() -> Node? {
    guard let node = parseExpression(), index == tokens.count else { return nil }
    return node
  }

  private mutating func parseExpression() -> Node? {
    guard var node = parseTerm() else { return nil }
    while let token = peek() {
      switch token {
      case .plus:
        advance()
        guard let rhs = parseTerm() else { return nil }
        node = .add(node, rhs)
      case .minus:
        advance()
        guard let rhs = parseTerm() else { return nil }
        node = .subtract(node, rhs)
      default:
        return node
      }
    }
    return node
  }

  private mutating func parseTerm() -> Node? {
    guard var node = parseUnary() else { return nil }
    while let token = peek() {
      switch token {
      case .star:
        advance()
        guard let rhs = parseUnary() else { return nil }
        node = .multiply(node, rhs)
      case .slash:
        advance()
        guard let rhs = parseUnary() else { return nil }
        node = .divide(node, rhs)
      default:
        guard startsImplicitFactor(token), let rhs = parseUnary() else { return node }
        node = .multiply(node, rhs)
      }
    }
    return node
  }

  private mutating func parseUnary() -> Node? {
    guard let token = peek() else { return nil }
    switch token {
    case .plus:
      advance()
      return parseUnary()
    case .minus:
      advance()
      guard let value = parseUnary() else { return nil }
      return .unaryMinus(value)
    default:
      return parsePower()
    }
  }

  private mutating func parsePower() -> Node? {
    guard let base = parsePrimary() else { return nil }
    guard consume(.caret) else { return base }
    guard let exponent = parseUnary() else { return nil }
    return .power(base, exponent)
  }

  private mutating func parsePrimary() -> Node? {
    guard let token = peek() else { return nil }
    switch token {
    case .number(let value):
      advance()
      return .number(value)
    case .identifier(let name):
      advance()
      return parseNamedValue(name)
    case .command(let name):
      advance()
      return parseCommand(name)
    case .leftParen:
      advance()
      return parseGrouped(until: .rightParen)
    case .leftBrace:
      advance()
      return parseGrouped(until: .rightBrace)
    default:
      return nil
    }
  }

  private mutating func parseNamedValue(_ name: String) -> Node? {
    if ["x", "n", "t"].contains(name) {
      usedVariables.insert(name)
      return .variable
    }
    if name == "e" { return .number(M_E) }
    if name == "pi" { return .number(Double.pi) }
    guard let function = Function(rawValue: name),
          let argument = parseFunctionArgument() else { return nil }
    return .function(function, argument)
  }

  private mutating func parseCommand(_ name: String) -> Node? {
    if name == "pi" { return .number(Double.pi) }
    if name == "frac" {
      guard consume(.leftBrace),
            let numerator = parseGrouped(until: .rightBrace),
            consume(.leftBrace),
            let denominator = parseGrouped(until: .rightBrace) else { return nil }
      return .divide(numerator, denominator)
    }
    guard let function = Function(rawValue: name),
          let argument = parseFunctionArgument() else { return nil }
    return .function(function, argument)
  }

  private mutating func parseFunctionArgument() -> Node? {
    guard let token = peek() else { return nil }
    switch token {
    case .leftParen:
      advance()
      return parseGrouped(until: .rightParen)
    case .leftBrace:
      advance()
      return parseGrouped(until: .rightBrace)
    default:
      return parsePrimary()
    }
  }

  private mutating func parseGrouped(until terminator: Token) -> Node? {
    guard let node = parseExpression(), consume(terminator) else { return nil }
    return node
  }

  private func startsImplicitFactor(_ token: Token) -> Bool {
    switch token {
    case .number, .identifier, .command, .leftParen, .leftBrace:
      return true
    default:
      return false
    }
  }

  private func peek() -> Token? {
    index < tokens.count ? tokens[index] : nil
  }

  private mutating func advance() {
    index += 1
  }

  private mutating func consume(_ token: Token) -> Bool {
    guard peek() == token else { return false }
    advance()
    return true
  }
}
