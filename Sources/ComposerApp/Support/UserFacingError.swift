import Foundation
import Combine

/// Turns failures from system APIs into text a person can act on.
///
/// The important rule is that we never replace a concrete diagnostic with "failed".
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
    return "%@ could not complete (%@); the underlying service did not provide a diagnostic.".localizedUI(action, code)
  }

  private static func networkMessage(for error: URLError, while action: String) -> String {
    switch error.code {
    case .notConnectedToInternet:
      return "%@ could not reach the internet. Check your connection and try again.".localizedUI(action)
    case .timedOut:
      return "%@ timed out before the service responded. Check your connection and try again.".localizedUI(action)
    case .cannotFindHost:
      return "%@ could not find the service host. Check your DNS or network connection.".localizedUI(action)
    case .cannotConnectToHost:
      return "%@ could not connect to the service. The service may be down or blocked by your network.".localizedUI(action)
    case .networkConnectionLost:
      return "%@ lost its network connection before it finished. Try again.".localizedUI(action)
    case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted:
      return "%@ could not verify the service's secure connection (%d).".localizedUI(action, error.code.rawValue)
    default:
      return "%@ failed with network error %d: %@".localizedUI(action, error.code.rawValue, normalized(error.localizedDescription))
    }
  }

  private static func decodingMessage(for error: DecodingError, while action: String) -> String {
    func location(_ context: DecodingError.Context) -> String {
      let path = context.codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
      return path.isEmpty ? "the response root".localizedUI : "`\(path)`"
    }

    switch error {
    case let .dataCorrupted(context):
      return "%@ received invalid data at %@: %@".localizedUI(action, location(context), context.debugDescription)
    case let .keyNotFound(key, context):
      return "%@ received data missing `%@` at %@.".localizedUI(action, key.stringValue, location(context))
    case let .typeMismatch(type, context):
      return "%@ received %@ in the wrong format (expected %@): %@".localizedUI(action, location(context), String(describing: type), context.debugDescription)
    case let .valueNotFound(type, context):
      return "%@ received no value at %@ (expected %@): %@".localizedUI(action, location(context), String(describing: type), context.debugDescription)
    @unknown default:
      return "%@ received data Composer could not decode: %@".localizedUI(action, error.localizedDescription)
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
