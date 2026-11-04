import Foundation

/// Development builds have independent preferences, history and widget data.
enum BuildIdentity {
  #if MACPURGE_DEVELOPMENT
    static let name = "MacPurge Dev"
    static let sharedGroup = "66K3EFBVB6.com.burakerenoglu.macpurge.dev.shared"
    static let widgetKind = "MacPurge.Dev.Disk"
  #else
    static let name = "MacPurge"
    static let sharedGroup = "66K3EFBVB6.com.burakerenoglu.macpurge.shared"
    static let widgetKind = "MacPurge.Disk"
  #endif

  static var supportDirectory: URL {
    URL.applicationSupportDirectory.appending(path: name)
  }
}
