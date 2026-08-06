import Foundation
import XCTest
@testable import ComposerApp

final class ConnectorSecretStoreTests: XCTestCase {
  func testKeychainSetReadAndDeleteRoundTrip() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    XCTAssertTrue(fixture.vault.setToken("  secret-value  ", for: "@linear"))
    XCTAssertEqual(fixture.vault.token(for: "@linear"), "secret-value")
    XCTAssertEqual(fixture.backing.tokens["@linear"], "secret-value")

    XCTAssertTrue(fixture.vault.setToken(nil, for: "@linear"))
    XCTAssertNil(fixture.vault.token(for: "@linear"))
    XCTAssertNil(fixture.backing.tokens["@linear"])
  }

  func testMigrationPreservesExistingKeychainValueAndDeletesVerifiedLegacyFile() throws {
    let fixture = try makeFixture(legacy: [
      "@linear": "legacy-linear",
      "@figma": "  legacy-figma  ",
    ])
    defer { fixture.cleanup() }
    fixture.backing.tokens["@linear"] = "keychain-wins"

    XCTAssertEqual(fixture.vault.token(for: "@linear"), "keychain-wins")
    XCTAssertEqual(fixture.vault.token(for: "@figma"), "legacy-figma")
    XCTAssertEqual(fixture.backing.tokens["@linear"], "keychain-wins")
    XCTAssertEqual(fixture.backing.tokens["@figma"], "legacy-figma")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyURL.path))
  }

  func testPartialMigrationKeepsLegacyFileAndRetriesOnNextLaunch() throws {
    let legacy = ["@linear": "linear-secret", "@figma": "figma-secret"]
    let fixture = try makeFixture(legacy: legacy)
    defer { fixture.cleanup() }
    fixture.backing.failingWrites.insert("@figma")

    XCTAssertEqual(fixture.vault.token(for: "@figma"), "figma-secret")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyURL.path))
    XCTAssertEqual(try readLegacy(fixture.legacyURL), legacy)

    fixture.backing.failingWrites.remove("@figma")
    let retryVault = ConnectorSecretVault(
      backing: fixture.backing,
      legacyFileURL: fixture.legacyURL,
      report: { fixture.messages.append($0) }
    )
    XCTAssertEqual(retryVault.token(for: "@figma"), "figma-secret")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyURL.path))
  }

  func testMigrationDoesNotDeleteLegacyFileUntilWriteVerificationPasses() throws {
    let fixture = try makeFixture(legacy: ["@sentry": "sentry-secret"])
    defer { fixture.cleanup() }
    fixture.backing.unverifiedWrites.insert("@sentry")

    XCTAssertEqual(fixture.vault.token(for: "@sentry"), "sentry-secret")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacyURL.path))
    XCTAssertEqual(try readLegacy(fixture.legacyURL)["@sentry"], "sentry-secret")
    XCTAssertNil(fixture.backing.tokens["@sentry"])
  }

  func testFailureMessagesNeverContainCredentialValues() throws {
    let secret = "never-echo-this-token"
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.backing.failureMessage = secret
    fixture.backing.failingWrites.insert("@notion")
    fixture.backing.failingReads.insert("@notion")

    XCTAssertFalse(fixture.vault.setToken(secret, for: "@notion"))
    XCTAssertNil(fixture.vault.token(for: "@notion"))
    XCTAssertFalse(fixture.messages.isEmpty)
    XCTAssertTrue(fixture.messages.allSatisfy { !$0.contains(secret) })
  }

  func testVerifiedKeychainWriteWinsWhenLegacyCleanupFails() throws {
    let fileManager = FailingRemovalFileManager()
    let fixture = try makeFixture(
      legacy: ["@linear": "legacy-secret"],
      fileManager: fileManager
    )
    defer { fixture.cleanup() }

    XCTAssertTrue(fixture.vault.setToken("new-secret", for: "@linear"))
    XCTAssertEqual(fixture.backing.tokens["@linear"], "new-secret")
    XCTAssertEqual(fixture.vault.token(for: "@linear"), "new-secret")
    XCTAssertEqual(try readLegacy(fixture.legacyURL)["@linear"], "legacy-secret")
    XCTAssertFalse(fixture.messages.isEmpty)
  }

  func testFailedLegacyCleanupKeepsTheTokenAvailable() throws {
    let fileManager = FailingRemovalFileManager()
    let fixture = try makeFixture(
      legacy: ["@linear": "legacy-secret"],
      fileManager: fileManager
    )
    defer { fixture.cleanup() }

    XCTAssertFalse(fixture.vault.setToken(nil, for: "@linear"))
    XCTAssertNil(fixture.backing.tokens["@linear"])
    XCTAssertEqual(fixture.vault.token(for: "@linear"), "legacy-secret")
    XCTAssertEqual(try readLegacy(fixture.legacyURL)["@linear"], "legacy-secret")
  }

  func testFailedKeychainDeletePreservesTheCredential() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.backing.tokens["@linear"] = "keychain-secret"
    fixture.backing.failingDeletes.insert("@linear")

    XCTAssertFalse(fixture.vault.setToken(nil, for: "@linear"))
    XCTAssertEqual(fixture.backing.tokens["@linear"], "keychain-secret")
    XCTAssertEqual(fixture.vault.token(for: "@linear"), "keychain-secret")
  }

  func testUnverifiedKeychainDeleteRestoresTheCredential() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.backing.tokens["@linear"] = "keychain-secret"
    fixture.backing.unverifiedDeletes.insert("@linear")

    XCTAssertFalse(fixture.vault.setToken(nil, for: "@linear"))
    XCTAssertEqual(fixture.backing.tokens["@linear"], "keychain-secret")
    XCTAssertEqual(fixture.vault.token(for: "@linear"), "keychain-secret")
  }

  func testKeychainReadFailureLeavesTheOnlyLegacyCredentialUntouched() throws {
    let fixture = try makeFixture(legacy: ["@linear": "legacy-secret"])
    defer { fixture.cleanup() }
    fixture.backing.failingReads.insert("@linear")

    XCTAssertFalse(fixture.vault.setToken(nil, for: "@linear"))
    XCTAssertEqual(try readLegacy(fixture.legacyURL)["@linear"], "legacy-secret")

    fixture.backing.failingReads.remove("@linear")
    XCTAssertEqual(fixture.vault.token(for: "@linear"), "legacy-secret")
  }

  func testUnreadableLegacyStoragePreventsDeletingTheUsableKeychainCredential() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.backing.tokens["@linear"] = "keychain-secret"
    try Data("not-json".utf8).write(to: fixture.legacyURL)

    XCTAssertFalse(fixture.vault.setToken(nil, for: "@linear"))
    XCTAssertEqual(fixture.backing.tokens["@linear"], "keychain-secret")
  }

  func testLegacyRewriteIsAtomicAndMode0600() throws {
    let fixture = try makeFixture(legacy: [
      "@figma": "figma-secret",
      "@linear": "linear-secret",
    ])
    defer { fixture.cleanup() }
    fixture.backing.failingWrites.insert("@figma")

    XCTAssertEqual(fixture.vault.token(for: "@figma"), "figma-secret")
    XCTAssertTrue(fixture.vault.setToken("new-linear-secret", for: "@linear"))
    XCTAssertEqual(try readLegacy(fixture.legacyURL), ["@figma": "figma-secret"])

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.legacyURL.path)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
  }

  func testFailedWriteVerificationRestoresPreviousKeychainValue() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.backing.tokens["@linear"] = "previous-secret"
    fixture.backing.unverifiedNextWrites.insert("@linear")

    XCTAssertFalse(fixture.vault.setToken("replacement-secret", for: "@linear"))
    XCTAssertEqual(fixture.backing.tokens["@linear"], "previous-secret")
    XCTAssertEqual(fixture.vault.token(for: "@linear"), "previous-secret")
  }

  private func makeFixture(
    legacy: [String: String]? = nil,
    fileManager: FileManager = .default
  ) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BonsAI-Connector-Secrets-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacyURL = directory.appendingPathComponent("connector-secrets.json")
    if let legacy {
      try JSONEncoder().encode(legacy).write(to: legacyURL, options: .atomic)
    }

    let backing = FakeConnectorSecretBacking()
    let messages = MessageRecorder()
    let vault = ConnectorSecretVault(
      backing: backing,
      legacyFileURL: legacyURL,
      fileManager: fileManager,
      report: { messages.values.append($0) }
    )
    return Fixture(
      directory: directory,
      legacyURL: legacyURL,
      backing: backing,
      messages: messages,
      vault: vault
    )
  }

  private func readLegacy(_ url: URL) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
  }
}

private final class FailingRemovalFileManager: FileManager {
  override func removeItem(at URL: URL) throws {
    throw CocoaError(.fileWriteNoPermission)
  }
}

private struct Fixture {
  let directory: URL
  let legacyURL: URL
  let backing: FakeConnectorSecretBacking
  let messages: MessageRecorder
  let vault: ConnectorSecretVault

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class MessageRecorder {
  var values: [String] = []

  func append(_ message: String) {
    values.append(message)
  }

  var isEmpty: Bool { values.isEmpty }
  func allSatisfy(_ predicate: (String) -> Bool) -> Bool { values.allSatisfy(predicate) }
}

private final class FakeConnectorSecretBacking: ConnectorSecretBacking {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  var tokens: [String: String] = [:]
  var failingReads = Set<String>()
  var failingWrites = Set<String>()
  var failingDeletes = Set<String>()
  var unverifiedDeletes = Set<String>()
  var unverifiedWrites = Set<String>()
  var unverifiedNextWrites = Set<String>()
  var failureMessage = "injected Keychain failure"

  func read(account: String) throws -> String? {
    if failingReads.contains(account) { throw Failure(message: failureMessage) }
    return tokens[account]
  }

  func write(_ value: String, account: String) throws {
    if failingWrites.contains(account) { throw Failure(message: failureMessage) }
    if unverifiedNextWrites.remove(account) != nil {
      tokens[account] = "verification-mismatch"
      return
    }
    tokens[account] = unverifiedWrites.contains(account) ? "verification-mismatch" : value
  }

  func delete(account: String) throws {
    if failingDeletes.contains(account) { throw Failure(message: failureMessage) }
    if unverifiedDeletes.contains(account) { return }
    tokens.removeValue(forKey: account)
  }
}
