import CMacBridge
import Foundation
import Testing

@Test func ataTemperatureRequiresValidPageAndTemperatureAttribute() {
  var bytes = [UInt8](repeating: 0, count: 512)
  bytes[0] = 1; bytes[2] = 194; bytes[7] = 42
  bytes[511] = 0 &- bytes.dropLast().reduce(UInt8(0), &+)
  var value = 0.0
  #expect(cmm_ata_temperature(bytes, bytes.count, &value) == 0)
  #expect(value == 42)
  bytes[7] = 43
  #expect(cmm_ata_temperature(bytes, bytes.count, &value) != 0)
  bytes[2] = 190
  bytes[511] = 0 &- bytes.dropLast().reduce(UInt8(0), &+)
  #expect(cmm_ata_temperature(bytes, bytes.count, &value) != 0)
  #expect(cmm_ata_temperature(bytes, 100, &value) != 0)
}
