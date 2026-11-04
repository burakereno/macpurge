import Foundation

enum ActivityRetention: Int, CaseIterable, Sendable {
  case thirtyDays = 30, ninetyDays = 90, forever = 0
  static let preference = "activityRetentionDays"

  static func saved(in defaults: UserDefaults = .standard) -> Self {
    guard defaults.object(forKey: preference) != nil else { return .ninetyDays }
    return Self(rawValue: defaults.integer(forKey: preference)) ?? .ninetyDays
  }

  func cutoff(at now: Date) -> Date? {
    self == .forever ? nil : now.addingTimeInterval(-Double(rawValue) * 24 * 3600)
  }
}
