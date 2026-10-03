import Clibsodium

public enum CryptoProbe {
    public static func version() throws -> String {
        guard sodium_init() >= 0 else { throw ProbeError.cryptoUnavailable }
        return String(cString: sodium_version_string())
    }
}
