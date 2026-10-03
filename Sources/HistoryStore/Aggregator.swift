import Foundation
import MonitorCore

public struct MetricBucket: Codable, Sendable {
  public var segmentId: String, seriesId: String, recordingEpoch: String
  public var bucketStartUtc: Double, bucketEndUtc: Double
  public var resolutionSeconds: Int, sourceResolutionSeconds: Int
  public var weightedSum: Double, coveredDurationMs: Double, sampleCount: Int
  public var min: Double, max: Double, partial: Bool
  public var continuityId: String = ""
  public var source = "database", persisted = true, partialRange = false
  public var avg: Double { weightedSum / Swift.max(coveredDurationMs, 1) }
  public var json: JSONValue {
    var j = (try? JSONValue.from(self)) ?? .null
    if case .object(var object) = j {
      object["avg"] = .number(avg)
      object["coverage"] = .number(
        Swift.min(1, coveredDurationMs / Swift.max(1, (bucketEndUtc - bucketStartUtc) * 1000)))
      j = .object(object)
    }
    return j
  }
}

public enum HistoryAggregation {
  public static func coalesce(
    _ input: [MetricBucket], maxPoints: Int, from: Double, to: Double, deadlineNs: UInt64? = nil
  )
    throws -> [MetricBucket]
  {
    guard (1...600).contains(maxPoints) else { throw APIError(400, "invalidParameter") }
    let deadline = deadlineNs ?? DispatchTime.now().uptimeNanoseconds + 250_000_000
    guard DispatchTime.now().uptimeNanoseconds < deadline else {
      throw APIError(503, "queryBudgetExceeded")
    }
    let sorted = input.sorted {
      ($0.segmentId, $0.bucketStartUtc) < ($1.segmentId, $1.bucketStartUtc)
    }
    var runs: [[MetricBucket]] = []
    for var point in sorted {
      point.partialRange = point.bucketStartUtc < from || point.bucketEndUtc > to
      if let last = runs.last?.last, last.segmentId == point.segmentId,
        abs(last.bucketEndUtc - point.bucketStartUtc) < 0.001,
        last.persisted == point.persisted, last.source == point.source
      {
        point.continuityId = last.continuityId
        runs[runs.count - 1].append(point)
      } else {
        point.continuityId = "\(point.segmentId):\(point.bucketStartUtc)"
        runs.append([point])
      }
    }
    guard runs.count <= maxPoints else {
      throw APIError(
        400, "pointBudgetTooSmall",
        [
          "minimumRequiredPoints": .number(Double(Swift.min(runs.count, 601))),
          "minimumIsLowerBound": .bool(runs.count > 600),
        ])
    }
    guard !sorted.isEmpty else { return [] }
    let base = sorted.map(\.sourceResolutionSeconds).max() ?? 1
    var width = Swift.max(base, Int(ceil((to - from) / Double(maxPoints * base))) * base)
    for _ in 0..<32 {
      var output: [MetricBucket] = []
      for run in runs {
        var current: MetricBucket?
        for point in run {
          let sameGrid =
            current.map {
              floor($0.bucketStartUtc / Double(width))
                == floor(point.bucketStartUtc / Double(width))
            } ?? false
          if var value = current, sameGrid {
            value.sourceResolutionSeconds = Swift.max(
              value.sourceResolutionSeconds, point.sourceResolutionSeconds)
            value.bucketEndUtc = point.bucketEndUtc
            value.weightedSum += point.weightedSum
            value.coveredDurationMs += point.coveredDurationMs
            value.sampleCount += point.sampleCount
            value.min = Swift.min(value.min, point.min)
            value.max = Swift.max(value.max, point.max)
            value.partial = value.partial || point.partial
            value.partialRange = value.partialRange || point.partialRange
            current = value
          } else {
            if let current { output.append(current) }
            var value = point
            value.resolutionSeconds = width
            current = value
          }
        }
        if let current { output.append(current) }
      }
      if output.count <= maxPoints {
        return output.sorted {
          ($0.bucketStartUtc, $0.segmentId) < ($1.bucketStartUtc, $1.segmentId)
        }
      }
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw APIError(503, "queryBudgetExceeded")
      }
      width *= 2
    }
    throw APIError(503, "queryBudgetExceeded")
  }
}
