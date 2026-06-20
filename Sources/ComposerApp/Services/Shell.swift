import Foundation

/// Runs a CLI off the main thread with the PATH a GUI app needs (a Finder-launched app
/// inherits a minimal PATH, so `gh`, `claude`, etc. wouldn't otherwise resolve).
enum Shell {
  struct Result { let stdout: String; let stderr: String; let status: Int32 }

  /// Run `/usr/bin/env <args…>` and capture output. Throws only if the process can't launch.
  static func run(_ args: [String]) async throws -> Result {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let outPipe = Pipe(), errPipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = args
      process.environment = augmentedEnvironment()
      process.standardOutput = outPipe
      process.standardError = errPipe
      try process.run()
      // Drain both pipes concurrently. Reading stdout to EOF and only then reading stderr can
      // deadlock if a child fills stderr before it closes stdout (common with verbose CLI errors).
      async let outData = outPipe.fileHandleForReading.readToEnd()
      async let errData = errPipe.fileHandleForReading.readToEnd()
      process.waitUntilExit()
      let (stdoutData, stderrData) = try await (outData, errData)
      return Result(
        stdout: String(data: stdoutData ?? Data(), encoding: .utf8) ?? "",
        stderr: String(data: stderrData ?? Data(), encoding: .utf8) ?? "",
        status: process.terminationStatus)
    }.value
  }

  /// A GUI app launched from Finder has a minimal PATH; add the usual CLI locations.
  static func augmentedEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let extras = [
      "/opt/homebrew/bin", "/usr/local/bin",
      "\(home)/.local/bin", "\(home)/.bun/bin",
      "\(home)/.npm-global/bin", "\(home)/.cargo/bin",
      "\(home)/.deno/bin", "/usr/bin", "/bin",
    ]
    let existing = env["PATH"].map { [$0] } ?? []
    env["PATH"] = (extras + existing).joined(separator: ":")
    return env
  }
}
