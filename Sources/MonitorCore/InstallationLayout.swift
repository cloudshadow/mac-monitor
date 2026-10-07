import Darwin
import Foundation

public enum InstallationLayout {
  public static let root = "/Library/Application Support/MacMonitor"
  public static let data = root + "/data"
  public static let configuration = root + "/installation.json"
  public static let app = root + "/Mac Monitor.app"
  public static let launcher = "/Applications/Mac Monitor.app"
  public static let maintenance = app + "/Contents/MacOS/MonitorMaintenance"
}

/// The public Applications directory is an entry point, never a trusted executable parent.
public enum InstallationPathPolicy {
  public static func applicationsDirectory(uid: uid_t, gid: gid_t, mode: mode_t) -> Bool {
    uid == 0 && mode & S_IFMT == S_IFDIR && mode & 0o002 == 0
      && (mode & 0o020 == 0 || gid == 80)
  }
}

/// Uses rename(2) so an unexpected destination directory is never followed or nested into.
public enum ApplicationLauncherLink {
  private static func check(_ path: String, bundle: String, owner: uid_t) throws {
    var info = stat()
    if lstat(path, &info) != 0 {
      guard errno == ENOENT else { throw APIError(503, "launcherUnavailable") }
      return
    }
    guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == owner,
      try FileManager.default.destinationOfSymbolicLink(atPath: path) == bundle
    else { throw APIError(503, "unmanagedLauncher") }
  }
  public static func install(
    bundle: String, launcher: String, staging: String, owner: uid_t = 0
  ) throws {
    try check(launcher, bundle: bundle, owner: owner)
    try check(staging, bundle: bundle, owner: owner)
    // The caller supplies a staging location inside its protected installation root.
    unlink(staging)
    guard symlink(bundle, staging) == 0 else { throw APIError(503, "launcherUnavailable") }
    defer { unlink(staging) }
    guard rename(staging, launcher) == 0 else { throw APIError(503, "launcherUnavailable") }
  }
  public static func remove(bundle: String, launcher: String, owner: uid_t = 0) throws {
    try check(launcher, bundle: bundle, owner: owner)
    if unlink(launcher) != 0, errno != ENOENT { throw APIError(503, "launcherUnavailable") }
  }
}
