import CryptoKit
import Foundation

/// Durable, user-accessible copies of board payloads that this build cannot safely decode.
enum BoardRecoveryStore {
  static let defaultDirectory = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  )[0].appendingPathComponent("Composer/Board Recovery", isDirectory: true)

  static func url(for data: Data, in directory: URL) -> URL {
    let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("board-\(fingerprint).json")
  }

  @discardableResult
  static func preserve(_ data: Data, in directory: URL) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let destination = url(for: data, in: directory)
    if fileManager.fileExists(atPath: destination.path) {
      guard try Data(contentsOf: destination) == data else {
        throw BoardRecoveryError.existingCopyDoesNotMatch
      }
    } else {
      let temporary = directory.appendingPathComponent(".recovery-\(UUID().uuidString).tmp")
      guard fileManager.createFile(
        atPath: temporary.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
      ) else {
        throw BoardRecoveryError.couldNotCreateTemporaryCopy
      }
      defer { try? fileManager.removeItem(at: temporary) }
      do {
        try fileManager.moveItem(at: temporary, to: destination)
      } catch {
        // A concurrent identical recovery wins harmlessly. Anything else must stay visible.
        guard fileManager.fileExists(atPath: destination.path),
              try Data(contentsOf: destination) == data else {
          throw error
        }
      }
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    return destination
  }

  static func load(copyOf data: Data, in directory: URL) -> Data? {
    try? Data(contentsOf: url(for: data, in: directory))
  }
}

private enum BoardRecoveryError: LocalizedError {
  case couldNotCreateTemporaryCopy
  case existingCopyDoesNotMatch

  var errorDescription: String? {
    switch self {
    case .couldNotCreateTemporaryCopy:
      "BonsAI could not create a private temporary recovery file."
    case .existingCopyDoesNotMatch:
      "The existing content-addressed recovery file does not match the saved board data."
    }
  }
}
