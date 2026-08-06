import Darwin
import Foundation

struct AgentProcessTermination {
  let status: Int32
  let reason: Process.TerminationReason
}

private enum AgentProcessGroupPhase {
  case leaderRunning
  case leaderExitedWithDescendants
  case exited
}

private final class AgentProcessGroupLifecycle: @unchecked Sendable {
  private let lock = NSLock()
  private var phase: AgentProcessGroupPhase = .leaderRunning

  var currentPhase: AgentProcessGroupPhase {
    lock.lock(); defer { lock.unlock() }
    return phase
  }

  /// Returns true when this transition released the complete process group.
  func leaderDidTerminate(descendantsRemain: Bool) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard phase != .exited else { return false }
    phase = descendantsRemain ? .leaderExitedWithDescendants : .exited
    return !descendantsRemain
  }

  /// Returns true only for the caller that first releases the complete process group.
  func groupDidExit() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard phase != .exited else { return false }
    phase = .exited
    return true
  }
}

/// A single launched agent process. Its termination handler is installed before launch and resolves
/// async waiters, so waiting never calls `Process.waitUntilExit()` or occupies the main actor.
final class ManagedAgentProcess: @unchecked Sendable {
  let id: UUID
  let processIdentifier: Int32

  private let process: Process
  private let terminationLatch: AgentProcessTerminationLatch
  private let processGroupLifecycle: AgentProcessGroupLifecycle
  private let didReleaseProcessGroup: (UUID) -> Void

  fileprivate init(
    id: UUID,
    process: Process,
    didTerminate: @escaping (UUID) -> Void
  ) throws {
    self.id = id
    self.process = process
    let latch = AgentProcessTerminationLatch()
    let lifecycle = AgentProcessGroupLifecycle()
    terminationLatch = latch
    processGroupLifecycle = lifecycle
    didReleaseProcessGroup = didTerminate

    process.terminationHandler = { process in
      let termination = AgentProcessTermination(
        status: process.terminationStatus,
        reason: process.terminationReason
      )
      let processGroup = process.processIdentifier
      let descendantsRemain = agentProcessGroupExists(processGroup)
      if lifecycle.leaderDidTerminate(descendantsRemain: descendantsRemain) {
        // Registry removal happens before waiter completion when the whole group is already gone.
        didTerminate(id)
      } else if descendantsRemain {
        Task.detached(priority: .utility) {
          await waitForAgentProcessGroupExit(processGroup)
          if lifecycle.groupDidExit() { didTerminate(id) }
        }
      }
      latch.resolve(termination)
    }
    try process.run()
    processIdentifier = process.processIdentifier
  }

  func termination() async -> AgentProcessTermination {
    await terminationLatch.wait()
  }

  fileprivate func stop(gracePeriod: TimeInterval) async -> AgentProcessTermination {
    let processGroup = processIdentifier
    requestTermination(processGroup)
    await waitForShutdownProgress(processGroup, timeout: max(0, gracePeriod))
    escalateTerminationIfNeeded(processGroup)

    // SIGKILL is asynchronous. Give descendant-only groups a short, bounded window to disappear
    // so app termination normally observes an empty registry before replying to AppKit.
    if processGroupLifecycle.currentPhase == .leaderExitedWithDescendants {
      await waitForShutdownProgress(processGroup, timeout: 0.25)
    }
    return await terminationLatch.wait()
  }

  private func requestTermination(_ processGroup: Int32) {
    switch processGroupLifecycle.currentPhase {
    case .exited:
      return
    case .leaderRunning:
      if agentProcessGroupExists(processGroup) {
        signalAgentProcessGroup(processGroup, signal: SIGTERM)
      } else if terminationLatch.resolvedValue == nil, process.isRunning {
        // The launcher may not have called setpgid yet. Process owns the still-current child here,
        // so terminate it directly instead of signaling a possibly stale numeric pid.
        process.terminate()
      }
    case .leaderExitedWithDescendants:
      if agentProcessGroupExists(processGroup) {
        // POSIX does not reuse a pid while a process group with that pgid still exists, so this
        // signal cannot drift to a new group while one of the owned descendants remains.
        signalAgentProcessGroup(processGroup, signal: SIGTERM)
      } else {
        releaseProcessGroup()
      }
    }
  }

  private func escalateTerminationIfNeeded(_ processGroup: Int32) {
    switch processGroupLifecycle.currentPhase {
    case .exited:
      return
    case .leaderRunning:
      if agentProcessGroupExists(processGroup) {
        signalAgentProcessGroup(processGroup, signal: SIGKILL)
      } else if terminationLatch.resolvedValue == nil, process.isRunning {
        _ = Darwin.kill(processIdentifier, SIGKILL)
      }
    case .leaderExitedWithDescendants:
      if agentProcessGroupExists(processGroup) {
        signalAgentProcessGroup(processGroup, signal: SIGKILL)
      } else {
        releaseProcessGroup()
      }
    }
  }

  private func waitForShutdownProgress(_ processGroup: Int32, timeout: TimeInterval) async {
    let deadline = DispatchTime.now() + timeout
    while DispatchTime.now() < deadline {
      switch processGroupLifecycle.currentPhase {
      case .exited:
        return
      case .leaderRunning:
        break
      case .leaderExitedWithDescendants:
        if !agentProcessGroupExists(processGroup) {
          releaseProcessGroup()
          return
        }
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func releaseProcessGroup() {
    if processGroupLifecycle.groupDidExit() { didReleaseProcessGroup(id) }
  }
}

/// Owns every launched agent process group until the leader and all descendants exit. This also
/// lets app shutdown stop an older group while a newer turn is already active.
final class AgentProcessSupervisor: @unchecked Sendable {
  static let defaultGracePeriod: TimeInterval = 1.0

  private let lock = NSLock()
  private let launcherURL: URL?
  private var launchingProcessIDs = Set<UUID>()
  private var processes: [UUID: ManagedAgentProcess] = [:]

  init(launcherURL: URL? = AgentProcessLauncherLocator.executableURL()) {
    self.launcherURL = launcherURL
  }

  func launch(_ process: Process) throws -> ManagedAgentProcess {
    let id = UUID()
    beginLaunching(id)
    let managed: ManagedAgentProcess
    do {
      try configureProcessGroupLauncher(for: process)
      managed = try ManagedAgentProcess(id: id, process: process) { [weak self] id in
        self?.processDidTerminate(id)
      }
    } catch {
      cancelLaunching(id)
      throw error
    }

    finishLaunching(managed)
    return managed
  }

  private func configureProcessGroupLauncher(for process: Process) throws {
    guard let executableURL = process.executableURL else {
      throw AgentProcessLaunchError.missingExecutable
    }
    guard let launcherURL else {
      throw AgentProcessLaunchError.missingLauncher
    }
    process.executableURL = launcherURL
    process.arguments = [executableURL.path] + (process.arguments ?? [])
  }

  private func beginLaunching(_ id: UUID) {
    lock.lock()
    launchingProcessIDs.insert(id)
    lock.unlock()
  }

  private func finishLaunching(_ process: ManagedAgentProcess) {
    lock.lock()
    // The termination callback removes this marker. If it already ran, never insert a dead process.
    if launchingProcessIDs.remove(process.id) != nil {
      processes[process.id] = process
    }
    lock.unlock()
  }

  private func cancelLaunching(_ id: UUID) {
    lock.lock()
    launchingProcessIDs.remove(id)
    lock.unlock()
  }

  @discardableResult
  func stop(
    _ process: ManagedAgentProcess,
    gracePeriod: TimeInterval = AgentProcessSupervisor.defaultGracePeriod
  ) async -> AgentProcessTermination {
    await process.stop(gracePeriod: gracePeriod)
  }

  func stopAll(gracePeriod: TimeInterval = AgentProcessSupervisor.defaultGracePeriod) async {
    let active = processSnapshot()

    await withTaskGroup(of: Void.self) { group in
      for process in active {
        group.addTask { _ = await process.stop(gracePeriod: gracePeriod) }
      }
    }
  }

  var activeProcessCount: Int {
    lock.lock(); defer { lock.unlock() }
    return processes.count
  }

  private func processSnapshot() -> [ManagedAgentProcess] {
    lock.lock(); defer { lock.unlock() }
    return Array(processes.values)
  }

  private func processDidTerminate(_ id: UUID) {
    lock.lock()
    launchingProcessIDs.remove(id)
    processes.removeValue(forKey: id)
    lock.unlock()
  }
}

private func agentProcessGroupExists(_ processGroup: Int32) -> Bool {
  guard processGroup > 0 else { return false }
  errno = 0
  return Darwin.kill(-processGroup, 0) == 0 || errno == EPERM
}

private func signalAgentProcessGroup(_ processGroup: Int32, signal: Int32) {
  guard processGroup > 0 else { return }
  _ = Darwin.kill(-processGroup, signal)
}

private func waitForAgentProcessGroupExit(_ processGroup: Int32) async {
  while agentProcessGroupExists(processGroup) {
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
}

private enum AgentProcessLaunchError: LocalizedError {
  case missingExecutable
  case missingLauncher

  var errorDescription: String? {
    switch self {
    case .missingExecutable:
      return "The coding-agent executable was not configured."
    case .missingLauncher:
      return "BonsAI's agent process-group launcher is missing from the app bundle."
    }
  }
}

private enum AgentProcessLauncherLocator {
  static let name = "BonsAIAgentLauncher"

  static func executableURL(fileManager: FileManager = .default) -> URL? {
    var candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"),
      Bundle.main.bundleURL.appendingPathComponent("Helpers/\(name)"),
    ]

    var directory = Bundle.main.bundleURL
    for _ in 0 ..< 5 {
      candidates.append(directory.appendingPathComponent(name))
      directory.deleteLastPathComponent()
    }

    #if DEBUG
    let buildRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
      .appendingPathComponent(".build", isDirectory: true)
    candidates.append(buildRoot.appendingPathComponent("debug/\(name)"))
    candidates.append(buildRoot.appendingPathComponent("release/\(name)"))
    #endif

    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
  }
}

private final class AgentProcessTerminationLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var value: AgentProcessTermination?
  private var waiters: [CheckedContinuation<AgentProcessTermination, Never>] = []

  func wait() async -> AgentProcessTermination {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let value {
        lock.unlock()
        continuation.resume(returning: value)
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  var resolvedValue: AgentProcessTermination? {
    lock.lock(); defer { lock.unlock() }
    return value
  }

  func resolve(_ result: AgentProcessTermination) {
    let continuations: [CheckedContinuation<AgentProcessTermination, Never>]
    lock.lock()
    guard value == nil else {
      lock.unlock()
      return
    }
    value = result
    continuations = waiters
    waiters.removeAll()
    lock.unlock()

    for continuation in continuations { continuation.resume(returning: result) }
  }
}

/// Small value type used by `CanvasAgent` to make every transcript/session/status write explicitly
/// conditional on the turn that produced it still being current.
struct AgentTurnGeneration {
  private(set) var current = 0

  mutating func begin() -> Int {
    current &+= 1
    return current
  }

  mutating func invalidate() {
    current &+= 1
  }

  func accepts(_ generation: Int) -> Bool {
    generation == current
  }
}
