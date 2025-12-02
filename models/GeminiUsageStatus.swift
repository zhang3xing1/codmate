import Foundation

struct GeminiUsageStatus: Equatable {
  struct Bucket: Equatable {
    let modelId: String?
    let tokenType: String?
    let remainingFraction: Double?
    let remainingAmount: String?
    let resetTime: Date?
  }

  let updatedAt: Date
  let projectId: String?
  let buckets: [Bucket]

  func asProviderSnapshot() -> UsageProviderSnapshot {
    let metrics: [UsageMetricSnapshot] = buckets.map { bucket in
      let remaining = bucket.remainingFraction?.clamped01()
      let percentText: String? = {
        guard let remaining else { return nil }
        return NumberFormatter.compactPercentFormatter.string(from: NSNumber(value: remaining))
          ?? String(format: "%.0f%%", remaining * 100)
      }()

      let labelParts = [bucket.modelId, bucket.tokenType].compactMap { $0 }.filter { !$0.isEmpty }
      let label = labelParts.first ?? "Usage"

      let usageText: String? = {
        if let amount = bucket.remainingAmount, !amount.isEmpty {
          return "Remaining \(amount)"
        }
        return nil
      }()

      return UsageMetricSnapshot(
        kind: .quota,
        label: label,
        usageText: usageText,
        percentText: percentText,
        progress: remaining,
        resetDate: bucket.resetTime,
        fallbackWindowMinutes: nil
      )
    }

    let availability: UsageProviderSnapshot.Availability = metrics.isEmpty ? .empty : .ready

    return UsageProviderSnapshot(
      provider: .gemini,
      title: UsageProviderKind.gemini.displayName,
      availability: availability,
      metrics: metrics,
      updatedAt: updatedAt,
      statusMessage: availability == .empty ? "No Gemini usage data." : nil,
      origin: .builtin
    )
  }
}

private extension Double {
  func clamped01() -> Double { max(0, min(self, 1)) }
}
