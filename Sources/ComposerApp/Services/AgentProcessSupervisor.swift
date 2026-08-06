import Darwin
import Foundation

struct AgentProcessTermination {
  let status: Int32
  let reason: Process.TerminationReason
}

/// A single launched agent process. Its termination handler is installed before launch and resolves
/// async waiters, so waiting never calls `Process.waitUntilExit()` or occupies the main actor.
final class ManagedAgentProcess: @unchecked Sendable {
  let id: UUID
  let processIdentifier: Int32

  private let process: Process
  private let terminationLatch: AgentProcessTerminationLatch

  fileprivate init(
    id: UUID,
    process: Process,
    didTerminate: @escaping (UUID) -> Void
  ) throws {
    self.id = id
    self.process = process
    let latch = AgentProcessTerminationLatch()
    terminationLatch = latch

    process.terminationHandler = { process in
      let termination = AgentProcessTermination(
        status: process.terminationStatus,
        reason: process.terminationReason
      )
      didTerminate(id)
      latch.resolve(termination)
    }
    try process.run()
    processIdentifier = process.processIdentifier
  }

  func termination() async -> AgentProcessTermination {
    await terminationLatch.wait()
  }

  fileprivate func stop(gracePeriod: TimeInterval) async -> AgentProcessTermination {
    if let termination = terminationLatch.resolvedValue { return termination }

    let pid = processIdentifier
    if pid > 0 { Darwin.kill(pid, SIGTERM) }
    if let termination = await terminationLatch.wait(timeout: max(0, gracePeriod)) {
      return termination
    }

    if pid > 0 { Darwin.kill(pid, SIGKILL) }
    return await terminationLatch.wait()
  }
}

/// Owns every launched agent until its termination handler fires. This also lets app shutdown stop
/// an older process that is still inside its grace period while a newer turn is already active.
final class AgentProcessSupervisor: @unchecked Sendable {
  static let defaultGracePeriod: TimeInterval = 1.0

  private let lock = NSLock()
  private var processes: [UUID: ManagedAgentProcess] = [:]

  func launch(_ process: Process) throws -> ManagedAgentProcess {
    let id = UUID()
    let managed: ManagedAgentProcess
    do {
      managed = try ManagedAgentProcess(id: id, process: process) { [weak self] id in
        self?.remove(id)
      }
    } catch {
      remove(id)
      throw error
    }

    lock.lock()
    processes[id] = managed
    lock.unlock()

    // A very short-lived process can terminate between `run()` and registry insertion.
    if managedTerminationAlreadyResolved(managed) { remove(id) }
    return managed
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

  private func managedTerminationAlreadyResolved(_ process: ManagedAgentProcess) -> Bool {
    process.terminationLatchIsResolved
  }

  private func processSnapshot() -> [ManagedAgentProcess] {
    lock.lock(); defer { lock.unlock() }
    return Array(processes.values)
  }

  private func remove(_ id: UUID) {
    lock.lock()
    processes.removeValue(forKey: id)
    lock.unlock()
  }
}

private extension ManagedAgentProcess {
  var terminationLatchIsResolved: Bool { terminationLatch.resolvedValue != nil }
}

private final class AgentProcessTerminationLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var value: AgentProcessTermination?
  private var waiters: [UUID: CheckedContinuation<AgentProcessTermination?, Never>] = [:]

  var resolvedValue: AgentProcessTermination? {
    lock.lock(); defer { lock.unlock() }
    return value
  }

  func wait() async -> AgentProcessTermination {
    if let value = resolvedValue { return value }
    return await withCheckedContinuation { continuation in
      enqueue(continuation, timeout: nil)
    }!
  }

  func wait(timeout: TimeInterval) async -> AgentProcessTermination? {
    if let value = resolvedValue { return value }
    return await withCheckedContinuation { continuation in
      enqueue(continuation, timeout: timeout)
    }
  }

  func resolve(_ result: AgentProcessTermination) {
    let continuations: [CheckedContinuation<AgentProcessTermination?, Never>]
    lock.lock()
    guard value == nil else {
      lock.unlock()
      return
    }
    value = result
    continuations = Array(waiters.values)
    waiters.removeAll()
    lock.unlock()

    for continuation in continuations { continuation.resume(returning: result) }
  }

  private func enqueue(
    _ continuation: CheckedContinuation<AgentProcessTermination?, Never>,
    timeout: TimeInterval?
  ) {
    let id = UUID()
    lock.lock()
    if let value {
      lock.unlock()
      continuation.resume(returning: value)
      return
    }
    waiters[id] = continuation
    lock.unlock()

    guard let timeout else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.timeOut(id)
    }
  }

  private func timeOut(_ id: UUID) {
    let continuation: CheckedContinuation<AgentProcessTermination?, Never>?
    lock.lock()
    continuation = waiters.removeValue(forKey: id)
    lock.unlock()
    continuation?.resume(returning: nil)
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
