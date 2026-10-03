import Darwin
import Foundation
import MonitorCore
import Testing

@Suite struct InstallationTests {
  @Test func defaultApplicationsPermissionsAreSupportedWithoutTrustingCodeThere() {
    #expect(InstallationPathPolicy.applicationsDirectory(uid: 0, gid: 80, mode: 0o040775))
    #expect(InstallationPathPolicy.applicationsDirectory(uid: 0, gid: 0, mode: 0o040755))
    #expect(!InstallationPathPolicy.applicationsDirectory(uid: 501, gid: 80, mode: 0o040775))
    #expect(!InstallationPathPolicy.applicationsDirectory(uid: 0, gid: 20, mode: 0o040775))
    #expect(!InstallationPathPolicy.applicationsDirectory(uid: 0, gid: 80, mode: 0o040777))
    #expect(!InstallationPathPolicy.applicationsDirectory(uid: 0, gid: 80, mode: 0o120775))
    #expect(!InstallationLayout.maintenance.hasPrefix("/Applications/"))
  }
  func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  @Test func managedLauncherCanBeInstalledReplacedAndRemoved() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Protected App.app").path
    let launcher = root.appendingPathComponent("Visible App.app").path
    let staging = root.appendingPathComponent(".link.new").path
    try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
    try ApplicationLauncherLink.install(bundle: bundle, launcher: launcher, staging: staging, owner: getuid())
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: launcher) == bundle)
    try ApplicationLauncherLink.install(bundle: bundle, launcher: launcher, staging: staging, owner: getuid())
    #expect(!FileManager.default.fileExists(atPath: staging))
    try ApplicationLauncherLink.remove(bundle: bundle, launcher: launcher, owner: getuid())
    #expect(!FileManager.default.fileExists(atPath: launcher))
    #expect(FileManager.default.fileExists(atPath: bundle))
  }
  @Test func existingDirectoryAndUnrelatedLinkAreNeverFollowedOrRemoved() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Protected App.app").path
    let launcher = root.appendingPathComponent("Visible App.app").path
    let staging = root.appendingPathComponent(".link.new").path
    try FileManager.default.createDirectory(atPath: launcher, withIntermediateDirectories: true)
    let sentinel = launcher + "/keep.txt"
    try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
    #expect(throws: APIError.self) {
      try ApplicationLauncherLink.install(bundle: bundle, launcher: launcher, staging: staging, owner: getuid())
    }
    #expect(FileManager.default.fileExists(atPath: sentinel))
    try FileManager.default.moveItem(atPath: launcher, toPath: launcher + ".unrelated")
    try FileManager.default.createSymbolicLink(atPath: launcher, withDestinationPath: launcher + ".unrelated")
    #expect(throws: APIError.self) {
      try ApplicationLauncherLink.remove(bundle: bundle, launcher: launcher, owner: getuid())
    }
    #expect(FileManager.default.fileExists(atPath: launcher + "/keep.txt"))
  }
  @Test func interruptedStagingLinkCanBeRecovered() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Protected App.app").path
    let launcher = root.appendingPathComponent("Visible App.app").path
    let staging = root.appendingPathComponent(".link.new").path
    try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: staging, withDestinationPath: bundle)
    try ApplicationLauncherLink.install(bundle: bundle, launcher: launcher, staging: staging, owner: getuid())
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: launcher) == bundle)
    #expect(!FileManager.default.fileExists(atPath: staging))
  }
}
