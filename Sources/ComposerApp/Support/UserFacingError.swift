import Foundation
import Combine

/// Turns failures from tools, HTTP calls, and system APIs into text a person can act on.
///
/// The important rule is that we never replace a concrete diagnostic with "failed". Some CLIs
/// (notably current Claude Code) write errors to stdout, so command failures must always inspect
/// both streams before choosing what to show.
enum UserFacingError {
  /// Report an error that happens below a SwiftUI action boundary (autosave, attachment storage,
  /// local server startup). `ComposerCanvas` observes this store and presents the exact message.
  static func report(_ error: Error, while action: String) {
    report(message(for: error, while: action))
  }

  static func report(_ message: String) {
    Task { @MainActor in
      UserFacingErrorStore.shared.publish(message)
    }
  }

  static func message(for error: Error, while action: String) -> String {
    if let urlError = error as? URLError {
      return networkMessage(for: urlError, while: action)
    }
    if let decodingError = error as? DecodingError {
      return decodingMessage(for: decodingError, while: action)
    }

    let nsError = error as NSError
    let diagnostic = normalized(nsError.localizedDescription)
    if !diagnostic.isEmpty, !isGeneric(diagnostic) { return diagnostic }

    let code = "\(nsError.domain) \(nsError.code)"
    return "\(action) could not complete (\(code)); the underlying service did not provide a diagnostic."
  }

  static func commandFailure(command: String, result: Shell.Result) -> String {
    commandFailure(command: command, status: result.status, stdout: result.stdout, stderr: result.stderr)
  }

  static func commandFailure(command: String, status: Int32, stdout: String, stderr: String) -> String {
    let diagnostic = commandOutput(stdout: stdout, stderr: stderr)
    let lower = diagnostic.lowercased()

    if command.localizedCaseInsensitiveCompare("Claude") == .orderedSame {
      if lower.contains("401") && (lower.contains("auth") || lower.contains("credential")) {
        return "Claude authentication was rejected by the API (HTTP 401: \(diagnostic)). Run `claude auth login`, then retry."
      }
      if lower.contains("auth") || lower.contains("credential") || lower.contains("login") {
        return "Claude authentication failed: \(diagnostic). Run `claude auth login`, then retry."
      }
    }

    guard !diagnostic.isEmpty else {
      return "\(command) exited with code \(status) but returned no diagnostic."
    }
    return "\(command) exited with code \(status): \(diagnostic)"
  }

  /// A single, compact diagnostic suitable for the app's error surfaces. Preserve stdout too:
  /// a command is allowed to write its only error there.
  static func commandOutput(stdout: String, stderr: String, limit: Int = 900) -> String {
    var seen = Set<String>()
    let parts = [stdout, stderr].compactMap { output -> String? in
      let text = normalized(output)
      guard !text.isEmpty, seen.insert(text).inserted else { return nil }
      return text
    }
    let combined = parts.joined(separator: " · ")
    guard combined.count > limit else { return combined }
    return String(combined.prefix(limit)) + "…"
  }

  private static func networkMessage(for error: URLError, while action: String) -> String {
    switch error.code {
    case .notConnectedToInternet:
      return "\(action) could not reach the internet. Check your connection and try again."
    case .timedOut:
      return "\(action) timed out before the service responded. Check your connection and try again."
    case .cannotFindHost:
      return "\(action) could not find the service host. Check your DNS or network connection."
    case .cannotConnectToHost:
      return "\(action) could not connect to the service. The service may be down or blocked by your network."
    case .networkConnectionLost:
      return "\(action) lost its network connection before it finished. Try again."
    case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted:
      return "\(action) could not verify the service's secure connection (\(error.code.rawValue))."
    default:
      return "\(action) failed with network error \(error.code.rawValue): \(normalized(error.localizedDescription))"
    }
  }

  private static func decodingMessage(for error: DecodingError, while action: String) -> String {
    func location(_ context: DecodingError.Context) -> String {
      let path = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
      return path.isEmpty ? "the response root" : "`\(path)`"
    }

    switch error {
    case let .dataCorrupted(context):
      return "\(action) received invalid data at \(location(context)): \(context.debugDescription)"
    case let .keyNotFound(key, context):
      return "\(action) received data missing `\(key.stringValue)` at \(location(context))."
    case let .typeMismatch(type, context):
      return "\(action) received \(location(context)) in the wrong format (expected \(type)): \(context.debugDescription)"
    case let .valueNotFound(type, context):
      return "\(action) received no value at \(location(context)) (expected \(type)): \(context.debugDescription)"
    @unknown default:
      return "\(action) received data Composer could not decode: \(error.localizedDescription)"
    }
  }

  private static func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isGeneric(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower == "the operation couldn’t be completed." ||
      lower == "the operation couldn't be completed." ||
      lower == "unknown error" ||
      lower == "error"
  }
}

@MainActor
final class UserFacingErrorStore: ObservableObject {
  struct Notice: Identifiable, Equatable {
    let id = UUID()
    let message: String
  }

  static let shared = UserFacingErrorStore()

  @Published private(set) var latest: Notice?

  func publish(_ message: String) {
    latest = Notice(message: message)
  }

  func takeLatest() -> Notice? {
    defer { latest = nil }
    return latest
  }
}

extension Shell.Result {
  var diagnostic: String {
    UserFacingError.commandOutput(stdout: stdout, stderr: stderr)
  }
}
