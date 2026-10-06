import Darwin
import Foundation
import MonitorCore

public struct NetworkInterface: Sendable {
  public let name: String, address: String
  public init(name: String, address: String) { self.name = name; self.address = address }
}
public enum LanNetwork {
  public static let defaultInterfaceName = "en0"
  public static func defaultInterface(in interfaces: [NetworkInterface]) -> NetworkInterface? {
    interfaces.first { $0.name == defaultInterfaceName }
  }
  public static func interfaces() -> [NetworkInterface] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }
    var result: [NetworkInterface] = []
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let node = current {
      defer { current = node.pointee.ifa_next }
      let value = node.pointee
      let name = String(cString: value.ifa_name)
      guard name.hasPrefix("en"), value.ifa_flags & UInt32(IFF_UP) != 0,
        value.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let address = value.ifa_addr,
        address.pointee.sa_family == AF_INET
      else { continue }
      var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      let ip = text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
      guard !ip.hasPrefix("169.254.") else { continue }
      result.append(NetworkInterface(name: name, address: ip))
    }
    return result.sorted { $0.name < $1.name }
  }
}
public final class TLSIdentity {
  public let certificate: String, privateKey: String, caCertificate: String
  private let directory: String
  public init(directory: String, address: String) throws {
    guard LanNetwork.interfaces().contains(where: { $0.address == address }) else {
      throw APIError(400, "invalidInterface")
    }
    self.directory = directory
    certificate = directory + "/server.pem"
    privateKey = directory + "/server.key"
    caCertificate = directory + "/ca.pem"
    var info = stat()
    if lstat(directory, &info) != 0 {
      guard mkdir(directory, 0o700) == 0, lstat(directory, &info) == 0 else {
        throw APIError(503, "tlsUnavailable")
      }
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
    else { throw APIError(503, "unsafeDataPath") }
    let caKey = directory + "/ca.key"
    for path in [caKey, caCertificate, privateKey, certificate] {
      if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw APIError(503, "unsafeDataPath") }
      }
    }
    if !FileManager.default.fileExists(atPath: caKey)
      && !FileManager.default.fileExists(atPath: caCertificate)
    {
      let config = directory + "/ca-config"
      try Data(
        "[req]\ndistinguished_name=dn\nx509_extensions=ca\n[dn]\nCN=Mac Monitor Local CA\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n"
          .utf8
      ).write(to: URL(fileURLWithPath: config))
      chmod(config, 0o600)
      try run([
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", caKey, "-out", caCertificate,
        "-days", "3650", "-subj", "/CN=Mac Monitor Local CA", "-config", config,
      ])
      unlink(config)
    }
    guard FileManager.default.fileExists(atPath: caKey),
      FileManager.default.fileExists(atPath: caCertificate)
    else { throw APIError(503, "tlsRecoveryRequired") }
    let previous = try? String(contentsOfFile: directory + "/address", encoding: .utf8)
    let expired = (try? run(["x509", "-checkend", "2592000", "-noout", "-in", certificate])) == nil
    if previous != address || expired {
      let temporary = directory + "/new"
      let config = directory + "/extensions"
      try Data(
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=IP:\(address)\n"
          .utf8
      ).write(to: URL(fileURLWithPath: config))
      chmod(config, 0o600)
      try run([
        "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", temporary + ".key", "-out",
        temporary + ".csr", "-subj", "/CN=Mac Monitor",
      ])
      try run([
        "x509", "-req", "-in", temporary + ".csr", "-CA", caCertificate, "-CAkey", caKey,
        "-set_serial", "0x" + Crypto.random(16), "-out", temporary + ".pem", "-days", "365",
        "-extfile", config,
      ])
      chmod(temporary + ".key", 0o600)
      chmod(temporary + ".pem", 0o600)
      guard rename(temporary + ".key", privateKey) == 0,
        rename(temporary + ".pem", certificate) == 0
      else { throw APIError(503, "tlsUnavailable") }
      try Data(address.utf8).write(to: URL(fileURLWithPath: directory + "/address"))
      chmod(directory + "/address", 0o600)
      unlink(temporary + ".csr")
      unlink(config)
    }
    for path in [caKey, caCertificate, privateKey, certificate] { chmod(path, 0o600) }
  }
  @discardableResult private func run(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let oldMask = umask(0o077)
    defer { umask(oldMask) }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw APIError(503, "tlsUnavailable") }
    return "ok"
  }
}
