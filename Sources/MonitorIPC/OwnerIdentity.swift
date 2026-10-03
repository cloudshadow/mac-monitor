import Darwin
import Foundation
import MonitorCore

public enum OwnerIdentity {
  public static func verify(name: String, uid: uid_t, generatedUID: String) throws {
    guard uid != 0, name.utf8.count <= 128, let user = getpwnam(name), user.pointee.pw_uid == uid,
      generatedUID.count == 36
    else { throw APIError(503, "ownerIdentityMismatch") }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
    task.arguments = ["/Local/Default", "-read", "/Users/" + name, "GeneratedUID"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try task.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0, output.count <= 1024,
      String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).last?
        .uppercased() == generatedUID.uppercased()
    else { throw APIError(503, "ownerIdentityMismatch") }
  }
}
