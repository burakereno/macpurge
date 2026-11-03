import Foundation

struct WidgetSnapshot: Codable {
  let date: Date
  let free: Int64?
  let candidates: Int64
  static let group = "66K3EFBVB6.com.burakerenoglu.macpurge.shared"
  static var location: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appending(
      path: "last-scan.json")
  }
  static func load() -> Self? {
    guard let location, let data = try? Data(contentsOf: location) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}
