import Foundation

/// Per-connector API tokens (Vercel, Linear, …). Stored as a 0600 JSON file in Application Support
/// rather than the Keychain — deliberately:
///
/// The dev build is ad-hoc signed and its code signature changes on every rebuild, so a Keychain
/// item's ACL never matches the "new" app and macOS prompts on every single access. A 0600 file is
/// prompt-free and matches how the tools themselves persist tokens (vercel `auth.json`, gh
/// `hosts.yml`, npm `.npmrc`). The API surface is intentionally storage-agnostic so this can move to
/// the Keychain unchanged once Composer ships with a stable signing identity.
enum ConnectorSecretStore {
  private static let lock = NSLock()
  private static var cache: [String: String]?

  private static let fileURL: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("Composer", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      UserFacingError.report(error, while: "Creating secure connector-token storage")
    }
    return dir.appendingPathComponent("connector-secrets.json")
  }()

  /// Non-empty token for a connector id (e.g. `@vercel`), or nil.
  static func token(for connectorID: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    let value = load()[connectorID]?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (value?.isEmpty ?? true) ? nil : value
  }

  static func hasToken(for connectorID: String) -> Bool { token(for: connectorID) != nil }

  /// Set (or, with nil/blank, clear) the token for a connector id.
  @discardableResult
  static func setToken(_ value: String?, for connectorID: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    var dict = load()
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty { dict[connectorID] = trimmed } else { dict.removeValue(forKey: connectorID) }
    guard persist(dict) else { return false }
    cache = dict
    return true
  }

  // MARK: - Backing file (callers hold `lock`)

  private static func load() -> [String: String] {
    if let cache { return cache }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      cache = [:]
      return [:]
    }
    let dict: [String: String]
    do {
      let data = try Data(contentsOf: fileURL)
      dict = try JSONDecoder().decode([String: String].self, from: data)
    } catch {
      UserFacingError.report(error, while: "Reading saved connector tokens")
      dict = [:]
    }
    cache = dict
    return dict
  }

  private static func persist(_ dict: [String: String]) -> Bool {
    do {
      let data = try JSONEncoder().encode(dict)
      try data.write(to: fileURL, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      return true
    } catch {
      UserFacingError.report(error, while: "Saving the connector token")
      return false
    }
  }
}
