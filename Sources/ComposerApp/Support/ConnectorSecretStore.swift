import Foundation
import Security

/// The storage boundary behind connector credentials. Production uses a generic-password Keychain
/// item; tests inject an in-memory implementation so migration and failure behavior stay deterministic.
protocol ConnectorSecretBacking {
  func read(account: String) throws -> String?
  func write(_ value: String, account: String) throws
  func delete(account: String) throws
}

struct KeychainConnectorSecretBacking: ConnectorSecretBacking {
  /// Stable across local Developer ID builds and shipped releases. Connector ids are Keychain accounts.
  static let defaultService = "dev.jow.BonsAI.connector-secrets"

  let service: String

  init(service: String = Self.defaultService) {
    self.service = service
  }

  func read(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = kCFBooleanTrue

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainFailure(status: errSecDecode)
    }
    return value
  }

  func write(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    let query = baseQuery(account: account)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw KeychainFailure(status: updateStatus) }

    var item = query
    item[kSecValueData as String] = data
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
  }

  func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainFailure(status: status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }
}

private struct KeychainFailure: LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    let diagnostic = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return "macOS Keychain error: \(diagnostic)"
  }
}

private enum ConnectorSecretVerificationError: Error {
  case writeDidNotRoundTrip
  case deleteDidNotRoundTrip
}

/// Synchronous by design: Settings and connector services already use a synchronous credential API.
/// The lock keeps migration, Keychain mutation, and legacy-file cleanup one atomic caller operation.
final class ConnectorSecretVault {
  private let backing: ConnectorSecretBacking
  private let legacyFileURL: URL
  private let fileManager: FileManager
  private let report: (String) -> Void
  private let lock = NSLock()
  private var migrationAttempted = false
  private var legacyFallbackAccounts = Set<String>()

  init(
    backing: ConnectorSecretBacking,
    legacyFileURL: URL,
    fileManager: FileManager = .default,
    report: @escaping (String) -> Void = UserFacingError.report
  ) {
    self.backing = backing
    self.legacyFileURL = legacyFileURL
    self.fileManager = fileManager
    self.report = report
  }

  func token(for connectorID: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    migrateLegacyIfNeeded()

    if legacyFallbackAccounts.contains(connectorID) {
      do {
        return normalized(try loadLegacyTokens()?[connectorID])
      } catch {
        reportLegacyStorageFailure(while: "Reading saved connector tokens".localizedUI)
        return nil
      }
    }

    do {
      if let value = normalized(try backing.read(account: connectorID)) { return value }
    } catch {
      reportKeychainFailure(while: "Reading saved connector tokens".localizedUI)
    }

    // A partial migration intentionally leaves the legacy file intact. Keychain wins per account;
    // this fallback prevents a failed insertion from losing a credential while the next launch retries.
    do {
      return normalized(try loadLegacyTokens()?[connectorID])
    } catch {
      reportLegacyStorageFailure(while: "Reading saved connector tokens".localizedUI)
      return nil
    }
  }

  func hasToken(for connectorID: String) -> Bool {
    token(for: connectorID) != nil
  }

  @discardableResult
  func setToken(_ value: String?, for connectorID: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    migrateLegacyIfNeeded()

    do {
      if let value = normalized(value) {
        try backing.write(value, account: connectorID)
        guard try backing.read(account: connectorID) == value else {
          throw ConnectorSecretVerificationError.writeDidNotRoundTrip
        }
      } else {
        try backing.delete(account: connectorID)
        guard normalized(try backing.read(account: connectorID)) == nil else {
          throw ConnectorSecretVerificationError.deleteDidNotRoundTrip
        }
      }

    } catch {
      // Deliberately do not interpolate the underlying error: an injected/system diagnostic must
      // never be able to echo the credential that was being stored.
      reportKeychainFailure(while: "Saving the connector token".localizedUI)
      return false
    }

    do {
      // Never leave this account's previous token in plaintext after a verified Keychain mutation.
      try removeLegacyToken(for: connectorID)
      legacyFallbackAccounts.remove(connectorID)
      return true
    } catch {
      reportLegacyStorageFailure(while: "Saving the connector token".localizedUI)
      return false
    }
  }

  private func migrateLegacyIfNeeded() {
    guard !migrationAttempted else { return }
    migrationAttempted = true

    let legacy: [String: String]
    do {
      guard let loaded = try loadLegacyTokens() else { return }
      legacy = loaded
    } catch {
      reportLegacyStorageFailure(while: "Migrating saved connector tokens".localizedUI)
      return
    }

    var migrationFailed = false
    for (connectorID, rawValue) in legacy {
      guard let legacyValue = normalized(rawValue) else { continue }
      do {
        if normalized(try backing.read(account: connectorID)) != nil {
          continue // An existing Keychain item always wins.
        }
        try backing.write(legacyValue, account: connectorID)
        guard try backing.read(account: connectorID) == legacyValue else {
          throw ConnectorSecretVerificationError.writeDidNotRoundTrip
        }
      } catch {
        migrationFailed = true
        legacyFallbackAccounts.insert(connectorID)
      }
    }

    // Delete only after every non-empty legacy entry either already existed or round-tripped.
    guard !migrationFailed else {
      reportMigrationVerificationFailure()
      return
    }
    do {
      try fileManager.removeItem(at: legacyFileURL)
    } catch {
      reportLegacyStorageFailure(while: "Migrating saved connector tokens".localizedUI)
    }
  }

  private func loadLegacyTokens() throws -> [String: String]? {
    guard fileManager.fileExists(atPath: legacyFileURL.path) else { return nil }
    let data = try Data(contentsOf: legacyFileURL)
    return try JSONDecoder().decode([String: String].self, from: data)
  }

  private func removeLegacyToken(for connectorID: String) throws {
    guard var legacy = try loadLegacyTokens() else { return }
    legacy.removeValue(forKey: connectorID)
    if legacy.isEmpty {
      try fileManager.removeItem(at: legacyFileURL)
      return
    }

    let data = try JSONEncoder().encode(legacy)
    try data.write(to: legacyFileURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyFileURL.path)
  }

  private func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  private func reportKeychainFailure(while action: String) {
    report("%@: macOS Keychain access failed. Check Keychain Access and try again.".localizedUI(action))
  }

  private func reportLegacyStorageFailure(while action: String) {
    report("%@: BonsAI couldn't update its legacy connector-token file. Check Application Support permissions and try again.".localizedUI(action))
  }

  private func reportMigrationVerificationFailure() {
    report("Connector-token migration could not be verified. The legacy file was kept so no token is lost; check Keychain Access and retry after reopening BonsAI.".localizedUI)
  }
}

/// Per-connector API tokens (Vercel, Linear, …), stored as generic-password items in Keychain.
/// The legacy mode-0600 JSON file is migrated once and removed only after every write is verified.
enum ConnectorSecretStore {
  private static let vault = ConnectorSecretVault(
    backing: KeychainConnectorSecretBacking(),
    legacyFileURL: legacyFileURL
  )

  private static let legacyFileURL: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let directory = base.appendingPathComponent("Composer", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      UserFacingError.report(error, while: "Creating secure connector-token storage".localizedUI)
    }
    return directory.appendingPathComponent("connector-secrets.json")
  }()

  static func token(for connectorID: String) -> String? {
    vault.token(for: connectorID)
  }

  static func hasToken(for connectorID: String) -> Bool {
    vault.hasToken(for: connectorID)
  }

  @discardableResult
  static func setToken(_ value: String?, for connectorID: String) -> Bool {
    vault.setToken(value, for: connectorID)
  }
}
