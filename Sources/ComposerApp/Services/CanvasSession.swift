import Darwin
import Foundation
import Security

/// The per-app-launch capability and the public connection metadata local clients need.
///
/// The capability is deliberately separate from the base URL so it can never leak through URL
/// logging, browser history, or query strings. `CanvasSessionDescriptorStore` is the only persistent
/// representation, and replaces it on every launch with owner-only permissions.
struct CanvasSessionDescriptor: Codable, Equatable {
  static let capabilityEnvironmentVariable = "BONSAI_CANVAS_CAPABILITY"

  let apiVersion: String
  let baseURL: String
  let capability: String

  var authorizationHeader: String { "Bearer \(capability)" }

  static func generate(apiVersion: String, port: UInt16) throws -> Self {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
      guard let address = buffer.baseAddress else { return errSecParam }
      return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
    }
    guard status == errSecSuccess else {
      throw CanvasSessionError.randomGenerationFailed(status)
    }
    let capability = bytes.map { String(format: "%02x", $0) }.joined()
    return Self(
      apiVersion: apiVersion,
      baseURL: "http://127.0.0.1:\(port)",
      capability: capability
    )
  }
}

enum CanvasSessionDescriptorStore {
  static let defaultDirectory = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  )[0].appendingPathComponent("Composer/Canvas", isDirectory: true)

  static let defaultURL = defaultDirectory.appendingPathComponent("session.json")

  /// Atomically replaces the descriptor with a mode-0600 file inside a mode-0700 directory.
  /// The temporary file is private before any secret bytes are written.
  @discardableResult
  static func publish(
    _ descriptor: CanvasSessionDescriptor,
    at destination: URL = defaultURL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let data = try JSONEncoder.canvasSession.encode(descriptor)
    let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString).tmp")
    guard fileManager.createFile(
      atPath: temporary.path,
      contents: data,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw CanvasSessionError.couldNotCreateTemporaryDescriptor
    }
    defer {
      if fileManager.fileExists(atPath: temporary.path) {
        try? fileManager.removeItem(at: temporary)
      }
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

    guard rename(temporary.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    return destination
  }

  static func load(
    from source: URL = defaultURL,
    fileManager: FileManager = .default
  ) throws -> CanvasSessionDescriptor {
    let data = try Data(contentsOf: source)
    return try JSONDecoder().decode(CanvasSessionDescriptor.self, from: data)
  }

  /// Removes a previous process's stale discovery record before this launch attempts to bind.
  static func invalidate(
    at destination: URL = defaultURL,
    fileManager: FileManager = .default
  ) throws {
    guard fileManager.fileExists(atPath: destination.path) else { return }
    try fileManager.removeItem(at: destination)
  }
}

private extension JSONEncoder {
  static let canvasSession: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
}

private enum CanvasSessionError: LocalizedError {
  case randomGenerationFailed(OSStatus)
  case couldNotCreateTemporaryDescriptor

  var errorDescription: String? {
    switch self {
    case .randomGenerationFailed(let status):
      "macOS could not generate a secure canvas capability (Security status \(status))."
    case .couldNotCreateTemporaryDescriptor:
      "BonsAI could not create the private canvas-session descriptor."
    }
  }
}
