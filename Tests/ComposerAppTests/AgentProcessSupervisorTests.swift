import Darwin
import Foundation
import XCTest
@testable import ComposerApp

final class AgentProcessSupervisorTests: XCTestCase {
  @MainActor
  func testClosedStdoutCanWaitForExitWithoutBlockingMainActor() async throws {
    let supervisor = AgentProcessSupervisor()
    let stdout = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exec 1>&-; sleep 3"]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let managed = try supervisor.launch(process)
    let pid = managed.processIdentifier
    defer { Darwin.kill(-pid, SIGKILL) }

    let stdoutClosed = Task.detached {
      try stdout.fileHandleForReading.readToEnd()
    }
    _ = try await stdoutClosed.value
    XCTAssertEqual(Darwin.kill(pid, 0), 0, "the child should still be alive after closing stdout")

    var waiterStarted = false
    var waiterCompleted = false
    let waiter = Task { @MainActor in
      waiterStarted = true
      let termination = await managed.termination()
      waiterCompleted = true
      return termination
    }
    for _ in 0 ..< 100 where !waiterStarted { await Task.yield() }

    XCTAssertTrue(waiterStarted)
    XCTAssertFalse(waiterCompleted, "an async termination wait must suspend the main actor")
    XCTAssertEqual(Darwin.kill(pid, 0), 0, "the linger interval should still be active at the probe")
    _ = await supervisor.stop(managed, gracePeriod: 0.08)
    let termination = await waiter.value
    XCTAssertEqual(termination.reason, .uncaughtSignal)
    XCTAssertEqual(supervisor.activeProcessCount, 0)
  }

  func testIgnoredSIGTERMEscalatesToSIGKILLAndReapsProcess() async throws {
    let supervisor = AgentProcessSupervisor()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; exec 1>&-; while :; do :; done"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let managed = try supervisor.launch(process)
    let pid = managed.processIdentifier
    defer { Darwin.kill(pid, SIGKILL) }
    try await Task.sleep(nanoseconds: 50_000_000) // let the shell install its TERM trap

    let started = ContinuousClock.now
    let termination = await supervisor.stop(managed, gracePeriod: 0.08)
    let elapsed = started.duration(to: .now)

    XCTAssertEqual(termination.reason, .uncaughtSignal)
    XCTAssertEqual(termination.status, SIGKILL)
    XCTAssertLessThan(elapsed, .seconds(1))
    errno = 0
    XCTAssertEqual(Darwin.kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    XCTAssertEqual(supervisor.activeProcessCount, 0)
  }

  func testImmediatelyExitingProcessesAreRemovedFromRegistry() async throws {
    let supervisor = AgentProcessSupervisor()
    var managedProcesses: [ManagedAgentProcess] = []

    for _ in 0 ..< 64 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      managedProcesses.append(try supervisor.launch(process))
    }

    for process in managedProcesses {
      _ = await process.termination()
    }
    for _ in 0 ..< 100 where supervisor.activeProcessCount != 0 {
      try await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(supervisor.activeProcessCount, 0)
  }

  func testStopTerminatesTheEntireAgentProcessGroup() async throws {
    let supervisor = AgentProcessSupervisor()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BonsAI-Agent-Process-Group-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let childPIDURL = directory.appendingPathComponent("child.pid")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "trap '' TERM; (trap '' TERM; while :; do :; done) & child=$!; echo $child > \"$1\"; wait $child",
      "bonsai-agent-test",
      childPIDURL.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let managed = try supervisor.launch(process)
    defer { Darwin.kill(-managed.processIdentifier, SIGKILL) }
    let childPID = try await waitForPID(in: childPIDURL)

    XCTAssertEqual(Darwin.getpgid(managed.processIdentifier), managed.processIdentifier)
    XCTAssertEqual(Darwin.getpgid(childPID), managed.processIdentifier)

    let termination = await supervisor.stop(managed, gracePeriod: 0.08)
    XCTAssertEqual(termination.reason, .uncaughtSignal)
    XCTAssertEqual(termination.status, SIGKILL)
    try await waitForProcessToDisappear(childPID)
    try await waitForRegistryToDrain(supervisor)
    XCTAssertEqual(supervisor.activeProcessCount, 0)
  }

  func testStopAllRetainsAndTerminatesDescendantsAfterLeaderExits() async throws {
    let supervisor = AgentProcessSupervisor()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BonsAI-Orphaned-Agent-Group-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let childPIDURL = directory.appendingPathComponent("child.pid")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "(trap '' HUP TERM; while :; do :; done) & child=$!; echo $child > \"$1\"; exit 0",
      "bonsai-agent-orphan-test",
      childPIDURL.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let managed = try supervisor.launch(process)
    defer { Darwin.kill(-managed.processIdentifier, SIGKILL) }
    let childPID = try await waitForPID(in: childPIDURL)
    let termination = await managed.termination()

    XCTAssertEqual(termination.status, 0)
    XCTAssertEqual(Darwin.getpgid(childPID), managed.processIdentifier)
    XCTAssertEqual(supervisor.activeProcessCount, 1)

    await supervisor.stopAll(gracePeriod: 0.08)
    try await waitForProcessToDisappear(childPID)
    try await waitForRegistryToDrain(supervisor)
    XCTAssertEqual(supervisor.activeProcessCount, 0)
  }

  func testStoppedAndSupersededTurnGenerationsRejectLateWrites() {
    var generation = AgentTurnGeneration()
    let first = generation.begin()
    XCTAssertTrue(generation.accepts(first))

    generation.invalidate()
    XCTAssertFalse(generation.accepts(first))

    let second = generation.begin()
    XCTAssertFalse(generation.accepts(first))
    XCTAssertTrue(generation.accepts(second))
  }

  private func waitForPID(in url: URL) async throws -> Int32 {
    for _ in 0 ..< 200 {
      if let contents = try? String(contentsOf: url, encoding: .utf8),
         let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return pid
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    return try XCTUnwrap(nil as Int32?, "the child process did not publish its pid")
  }

  private func waitForProcessToDisappear(_ pid: Int32) async throws {
    for _ in 0 ..< 200 {
      errno = 0
      if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("the descendant process was still alive after group shutdown")
  }

  private func waitForRegistryToDrain(_ supervisor: AgentProcessSupervisor) async throws {
    for _ in 0 ..< 200 where supervisor.activeProcessCount != 0 {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
