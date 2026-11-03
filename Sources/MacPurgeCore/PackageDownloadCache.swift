import Foundation

/// These default macOS cache locations have a recognizable on-disk download format.
package enum PackageDownloadCache: String, CaseIterable, Sendable {
  case pip = "Library/Caches/pip/http-v2"
  case legacyPip = "Library/Caches/pip/http"
  case brew = "Library/Caches/Homebrew/downloads"

  package var title: String {
    switch self {
    case .pip: "pip · HTTP indirmeleri"
    case .legacyPip: "pip · Eski HTTP indirmeleri"
    case .brew: "Homebrew · İndirmeler"
    }
  }

  package func accepts(_ name: String, directory: Bool, prefix: String) -> Bool {
    func isHash(_ value: Substring, length: Int) -> Bool {
      value.utf8.count == length
        && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    switch self {
    case .brew:
      guard !directory, prefix.isEmpty, let separator = name.range(of: "--"),
        isHash(name[..<separator.lowerBound], length: 64)
      else { return false }
      let file = name[separator.upperBound...]
      return !file.isEmpty && !file.hasSuffix(".incomplete") && !file.hasSuffix(".part")
        && !file.hasSuffix(".lock")
    case .pip, .legacyPip:
      if directory { return prefix.count < 5 && isHash(name[...], length: 1) }
      let digest = self == .pip && name.hasSuffix(".body") ? name.dropLast(5) : name[...]
      return prefix.count == 5 && digest.hasPrefix(prefix) && isHash(digest, length: 56)
    }
  }
}
