import Foundation
@testable import MonitorCore
import MacCollectors
import Testing

@Test func tenSecondSamplingDoesNotResetOrOversample() {
  let now = Locked(UInt64(0))
  let counts = Locked([Scheduler.Channel: Int]())
  let resets = Locked(0)
  let scheduler = Scheduler(clock: { now.withLock { $0 } }, collect: { channel, interval in
    #expect(interval == 10000)
    counts.withLock { $0[channel, default: 0] += 1 }
  }, discontinuity: { resets.withLock { $0 += 1 } }, wallClock: {
    Date(timeIntervalSince1970: Double(now.withLock { $0 }) / 1e9)
  })
  for second in 0...9 { now.withLock { $0 = UInt64(second) * 1_000_000_000 }; scheduler.tick() }
  for channel in Scheduler.Channel.allCases { #expect(counts.withLock { $0[channel] } == 1) }
  for second in [10, 20, 30] { now.withLock { $0 = UInt64(second) * 1_000_000_000 }; scheduler.tick() }
  for channel in Scheduler.Channel.allCases { #expect(counts.withLock { $0[channel] } == 4) }
  #expect(resets.withLock { $0 } == 0)
  now.withLock { $0 = 100_000_000_000 }; scheduler.tick()
  #expect(resets.withLock { $0 } == 1)
}

@Test func constrainedSamplingNeverIncreasesFrequency() {
  let intervals = PowerPolicy.intervals(lowPower: true, thermal: 0)
  #expect(intervals.system == 20000 && intervals.apps == 20000)
  #expect(intervals.temperature == 20000 && intervals.gpu == 20000)
}

@Test func referenceSensorsSeparateDieProximityStorageAndVRM() {
  #expect(SensorCatalog.definition("TCMz")?.category == "cpu")
  #expect(SensorCatalog.definition("TRDX")?.category == "graphics")
  #expect(SensorCatalog.definition("TVm0")?.category == "memory")
  #expect(SensorCatalog.definition("TVM0")?.category == "vrm")
  #expect(SensorCatalog.definition("Ts0K")?.category == "system")
  #expect(SensorCatalog.definition("Ts1P")?.category == "storage")
  #expect(SensorCatalog.definition("TCHP")?.category == "system")
  #expect(SensorCatalog.definitions.count <= 128)
  #expect(Set(SensorCatalog.definitions.map(\.key)).count == SensorCatalog.definitions.count)
  #expect(SensorCatalog.definitions.allSatisfy { $0.key.utf8.count == 4 })
}
