@testable import MacCollectors
import Testing

struct MemoryAccountingTests {
  @Test func appEstimateExcludesFileCacheAndPurgeablePages() {
    #expect(BasicSystemCollector.appMemoryBytes(
      active: 500, inactive: 300, speculative: 100, purgeable: 50, fileBacked: 250) == 600)
    #expect(BasicSystemCollector.appMemoryBytes(
      active: 100, inactive: 20, speculative: 10, purgeable: 50, fileBacked: 100) == 0)
  }
  @Test func collectedAppWiredPercentageMatchesItsComponents() {
    let sample = BasicSystemCollector().sample()
    #expect(sample.appMemoryBytes != nil)
    if let app = sample.appMemoryBytes, let wired = sample.wiredBytes,
      let total = sample.physicalMemoryBytes, let percent = sample.appWiredPercent.value {
      #expect(total > 0)
      #expect(abs(percent - min(100, 100 * (Double(app) + Double(wired)) / Double(total))) < 0.0001)
    } else {
      Issue.record("Memory counters unavailable on the local Mac")
    }
  }
}
