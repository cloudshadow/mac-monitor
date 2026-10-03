import CMacBridge
import Foundation

/// IOKit notification thread works without an AppKit login session. It never blocks sleep.
/// Its observer lifetime is the service lifetime; monotonic gap detection remains a fallback.
public final class SystemPowerWatcher: @unchecked Sendable {
  private let change: @Sendable (Bool) -> Void
  public init(change: @escaping @Sendable (Bool) -> Void) { self.change = change }
  public func start() {
    Thread.detachNewThread { [self] in
      cmm_watch_power(Unmanaged.passUnretained(self).toOpaque()) { context, sleeping in
        guard let context else { return }
        Unmanaged<SystemPowerWatcher>.fromOpaque(context).takeUnretainedValue().change(
          sleeping != 0)
      }
    }
  }
}
