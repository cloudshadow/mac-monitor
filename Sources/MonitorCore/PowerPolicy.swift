import Foundation

public enum PowerPolicy {
  public static func intervals(lowPower: Bool, thermal: Int) -> SamplingIntervals {
    lowPower || thermal >= 2 ? .constrained : SamplingIntervals()
  }
}
