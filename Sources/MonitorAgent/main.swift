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
let root = options["--data-root"] ?? "/Library/Application Support/CloudMacMonitor/data"
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let web =
  options["--web-root"]
  ?? executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
    "Resources/web"
  ).path
let semaphore = DispatchSemaphore(value: 0)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let runtime: AgentRuntime
do {
  runtime = try AgentRuntime(root: root, webRoot: web)
  try runtime.start(port: Int(options["--port"] ?? "8765") ?? 8765)
} catch {
  FileHandle.standardError.write(Data("MonitorAgent could not start: \(error)\n".utf8))
  exit((error as? APIError)?.code == "startupCircuitOpen" ? 0 : 78)
}
FileHandle.standardError.write(Data("MonitorAgent ready at \(runtime.address)\n".utf8))
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
term.setEventHandler { semaphore.signal() }
interrupt.setEventHandler { semaphore.signal() }
term.resume()
interrupt.resume()
semaphore.wait()
let finished = DispatchSemaphore(value: 0)
Task {
  await runtime.shutdown()
  finished.signal()
}
_ = finished.wait(timeout: .now() + 5)
