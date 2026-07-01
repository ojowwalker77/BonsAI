import XCTest
@testable import ComposerApp

final class AgentSkillsInstallerTests: XCTestCase {
  private var tmpFile: URL!

  override func setUp() {
    super.setUp()
    tmpFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentSkillsInstallerTests-\(UUID().uuidString).md")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: tmpFile)
    super.tearDown()
  }

  func testMergeIntoMissingFileCreatesItWithJustTheSection() throws {
    try AgentSkillsInstaller.mergeMarkedSection("the skill body", into: tmpFile)

    let contents = try String(contentsOf: tmpFile, encoding: .utf8)
    XCTAssertTrue(contents.contains("the skill body"))
    XCTAssertTrue(contents.contains("BEGIN BONSAI BOARD SKILL"))
    XCTAssertTrue(contents.contains("END BONSAI BOARD SKILL"))
  }

  func testMergePreservesUnrelatedContentOutsideTheMarkers() throws {
    try "# My own AGENTS.md notes\nDo not touch this.\n".write(
      to: tmpFile, atomically: true, encoding: .utf8)

    try AgentSkillsInstaller.mergeMarkedSection("the skill body", into: tmpFile)

    let contents = try String(contentsOf: tmpFile, encoding: .utf8)
    XCTAssertTrue(contents.contains("Do not touch this."))
    XCTAssertTrue(contents.contains("the skill body"))
  }

  func testReinstallReplacesThePreviousSectionWithoutDuplicatingIt() throws {
    try AgentSkillsInstaller.mergeMarkedSection("version one", into: tmpFile)
    try AgentSkillsInstaller.mergeMarkedSection("version two", into: tmpFile)

    let contents = try String(contentsOf: tmpFile, encoding: .utf8)
    XCTAssertFalse(contents.contains("version one"))
    XCTAssertTrue(contents.contains("version two"))
    XCTAssertEqual(contents.components(separatedBy: "BEGIN BONSAI BOARD SKILL").count - 1, 1)
  }

  func testMergeDoesNotTrapWhenMarkersAreReversedInTheFile() throws {
    // A hand-mangled file with the end marker physically before the begin marker would make an
    // in-order replace range reversed and trap. The merge must degrade to appending a fresh section.
    let begin = "<!-- BEGIN BONSAI BOARD SKILL (auto-managed by BonsAI; edits outside the markers are preserved) -->"
    let end = "<!-- END BONSAI BOARD SKILL -->"
    try "\(end)\nstray\n\(begin)\n".write(to: tmpFile, atomically: true, encoding: .utf8)

    XCTAssertNoThrow(try AgentSkillsInstaller.mergeMarkedSection("recovered body", into: tmpFile))
    let contents = try String(contentsOf: tmpFile, encoding: .utf8)
    XCTAssertTrue(contents.contains("recovered body"))
  }

  func testDanglingBeginMarkerDoesNotLetReinstallDeleteUserNotes() throws {
    let begin = "<!-- BEGIN BONSAI BOARD SKILL (auto-managed by BonsAI; edits outside the markers are preserved) -->"
    try "\(begin)\nUSER NOTES\n".write(to: tmpFile, atomically: true, encoding: .utf8)

    try AgentSkillsInstaller.mergeMarkedSection("first install", into: tmpFile)
    try AgentSkillsInstaller.mergeMarkedSection("second install", into: tmpFile)

    let contents = try String(contentsOf: tmpFile, encoding: .utf8)
    XCTAssertTrue(contents.contains("USER NOTES"))
    XCTAssertTrue(contents.contains("first install"))
    XCTAssertTrue(contents.contains("second install"))
  }

  func testUnrelatedSharedAgentsFileDoesNotCountAsInstalled() throws {
    try "# My Codex notes\nNo BonsAI section yet.\n".write(to: tmpFile, atomically: true, encoding: .utf8)

    XCTAssertFalse(AgentSkillsInstaller.hasInstalledManagedSection(at: tmpFile))

    try AgentSkillsInstaller.mergeMarkedSection("the skill body", into: tmpFile)
    XCTAssertTrue(AgentSkillsInstaller.hasInstalledManagedSection(at: tmpFile))
  }

  /// `Bundle.appResources` only resolves the staged `.app` layout (by design — see its doc
  /// comment), not the xctest runner's working directory, so this checks the source files that
  /// `Package.swift` declares as `.process("Resources")` directly rather than through the bundle.
  func testAllAgentSkillSourceFilesExistAndAreNonEmpty() throws {
    let resourcesDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/ComposerAppTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources/ComposerApp/Resources/AgentSkills")

    let expected = [
      "claude-code-SKILL.md", "codex-AGENTS.md", "cursor-bonsai-board.mdc",
    ]
    for name in expected {
      let url = resourcesDir.appendingPathComponent(name)
      let contents = try String(contentsOf: url, encoding: .utf8)
      XCTAssertFalse(contents.isEmpty, "\(name) is empty")
    }
  }
}
