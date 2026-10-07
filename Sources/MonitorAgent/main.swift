import Darwin
import Foundation
import MonitorCore
import MonitorServer

var options: [String: String] = [:]
let args = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < args.count {
  guard ["--data-root", "--web-root", "--port"].contains(args[index]), index + 1 < args.count else {
    FileHandle.standardError.write(
      Data("usage: MonitorAgent [--data-root PATH] [--web-root PATH] [--port PORT]\n".utf8))
    exit(64)
  }
  options[args[index]] = args[index + 1]
  index += 2
}
let root = options["--data-root"] ?? InstallationLayout.data
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let web =
  options["--web-root"]
  ?? executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
    "Resources/web"
  ).path
let semaphore = DispatchSemaphore(value: 0)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
// Swift 6 top-level code is MainActor-isolated. Explicit Sendable callbacks must
// run on the signal queue without inheriting that actor's executor assertion.
let wake: @Sendable () -> Void = { [semaphore] in semaphore.signal() }
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
term.setEventHandler(handler: wake)
interrupt.setEventHandler(handler: wake)
term.resume()
interrupt.resume()
let runtime: AgentRuntime
do {
  runtime = try AgentRuntime(root: root, webRoot: web, requestExit: wake)
  let port: Int?
  if let value = options["--port"] {
    guard let parsed = Int(value), (0...65535).contains(parsed) else { throw APIError(400, "invalidPort") }
    port = parsed
  } else { port = nil }
  try runtime.start(port: port)
} catch {
  FileHandle.standardError.write(Data("MonitorAgent could not start: \(error)\n".utf8))
  exit((error as? APIError)?.code == "startupCircuitOpen" ? 0 : 78)
}
FileHandle.standardError.write(Data("MonitorAgent ready at \(runtime.address)\n".utf8))
semaphore.wait()
let finished = DispatchSemaphore(value: 0)
// A main-actor Task cannot run while this top-level thread waits for completion.
Task.detached { [runtime, finished] in
  await runtime.shutdown()
  finished.signal()
}
if finished.wait(timeout: .now() + 5) != .success {
  FileHandle.standardError.write(Data("MonitorAgent shutdown deadline reached; exiting.\n".utf8))
}
// Explicit successful exit prevents KeepAlive/SuccessfulExit=false from restarting a deliberate stop.
exit(0)
