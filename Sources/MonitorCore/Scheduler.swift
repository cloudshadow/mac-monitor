import Foundation

public struct SamplingIntervals: Codable, Sendable, Equatable {
  public var system = 10_000, apps = 10_000, temperature = 10_000, gpu = 10_000
  public init() {}
  public static var constrained: Self {
    var v = Self()
    v.system = 20_000
    v.apps = 20_000
    v.temperature = 20_000
    v.gpu = 20_000
    return v
  }
}

/// All callbacks execute on one queue. A busy callback cannot accumulate more callbacks.
public final class Scheduler: @unchecked Sendable {
  public enum Channel: CaseIterable, Sendable { case system, apps, temperature, gpu }
  private let queue = DispatchQueue(label: "org.cloudmacmonitor.collect", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var deadlines: [Channel: UInt64] = [:]
  private var lastContinuous: UInt64?, lastWall: Date?
  private var intervals = SamplingIntervals()
  private var paused = false
  private let wallClock: @Sendable () -> Date
  private let clock: @Sendable () -> UInt64
  private let collect: @Sendable (Channel, Int) -> Void
  private let discontinuity: @Sendable () -> Void
  public init(
    clock: @escaping @Sendable () -> UInt64, collect: @escaping @Sendable (Channel, Int) -> Void,
    discontinuity: @escaping @Sendable () -> Void, wallClock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.wallClock = wallClock
    self.clock = clock
    self.collect = collect
    self.discontinuity = discontinuity
  }
  public func start() {
    queue.sync {
      guard timer == nil else { return }
      let t = DispatchSource.makeTimerSource(queue: queue)
      t.schedule(deadline: .now(), repeating: .milliseconds(10_000), leeway: .milliseconds(500))
      t.setEventHandler { [weak self] in self?.tick() }
      timer = t
      t.resume()
    }
  }
  public func configure(_ value: SamplingIntervals) {
    queue.async { [self] in
      guard intervals != value else { return }
      intervals = value
      deadlines.removeAll()
    }
  }
  public func suspend() {
    queue.async { [self] in
      paused = true
      deadlines.removeAll()
      lastContinuous = nil
      discontinuity()
    }
  }
  public func resume() {
    queue.async { [self] in
      paused = false
      deadlines.removeAll()
      lastContinuous = nil
      discontinuity()
    }
  }
  public func stop() {
    queue.sync {
      timer?.cancel()
      timer = nil
    }
  }
  func tick() {
    guard !paused else { return }
    let now = clock()
    let wall = wallClock()
    if let old = lastContinuous, let oldWall = lastWall {
      let seconds = now >= old ? Double(now - old) / 1_000_000_000 : Double.infinity
      if seconds > 30 || abs(wall.timeIntervalSince(oldWall) - seconds) > 2 {
        deadlines.removeAll()
        discontinuity()
      }
    }
    lastContinuous = now
    lastWall = wall
    for channel in Channel.allCases {
      let interval: Int
      switch channel {
      case .system: interval = intervals.system
      case .apps: interval = intervals.apps
      case .temperature: interval = intervals.temperature
      case .gpu: interval = intervals.gpu
      }
      let deadline = deadlines[channel] ?? 0
      if now >= deadline || deadline - now <= 200_000_000 {
        collect(channel, interval)
        let step = UInt64(interval) * 1_000_000
        let old = deadlines[channel] ?? now
        deadlines[channel] = old + ((Swift.max(now, old) - old) / step + 1) * step
      }
    }
  }
}
