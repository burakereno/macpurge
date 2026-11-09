import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

enum DownloadsInventory {
  static func installerKey(_ name: String) -> String {
    let base = (name as NSString).deletingPathExtension.lowercased()
    let version = base.replacingOccurrences(of: "[-_ ]v?[0-9]+(?:\\.[0-9]+)*", with: " ", options: .regularExpression)
    let noise = Set(["installer", "install", "setup", "mac", "macos", "osx", "darwin", "arm64", "aarch64", "x64", "x86", "64", "universal", "intel", "apple", "silicon"])
    let key = version.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !noise.contains(String($0)) }.joined()
    return ["vscode": "visualstudiocode", "chrome": "googlechrome"][key] ?? key
  }

  static func originalName(_ name: String) -> String? {
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    guard let range = stem.range(of: " \\([0-9]+\\)$", options: .regularExpression) else { return nil }
    return String(stem[..<range.lowerBound]) + (ext.isEmpty ? "" : "." + ext)
  }

  static func discover(home: URL, applications: [ApplicationIdentity], volumes: ScanVolumes,
                       includeProtected: Bool,
                       comparisonBudget: Int64 = 4 * 1024 * 1024 * 1024) throws -> [ScanRoot] {
    let folder = home.appending(path: "Downloads")
    guard includeProtected else {
      return [.init(group: .downloads, title: "Downloads", url: folder, profile: .personal,
                    source: .status("Korumalı konum taraması kapalı"))]
    }
    let entries = try DeveloperDataInventory.children(folder, volumes: volumes).filter { !$0.directory && !$0.url.lastPathComponent.hasPrefix(".") }
    guard !entries.isEmpty else { return [] }
    let names = Dictionary(entries.map { ($0.url.lastPathComponent, $0.url) }, uniquingKeysWith: { first, _ in first })
    var roots: [ScanRoot] = [], budget = comparisonBudget
    for entry in entries {
      try Task.checkCancellation()
      let url = entry.url
      var evidence: InventoryEvidence?
      if let original = originalName(url.lastPathComponent), let other = names[original] {
        let first = try? FileComparison.read(url) { _, info in info.st_size }
        let second = try? FileComparison.read(other) { _, info in info.st_size }
        if let size = first, size > 0, size == second, size <= budget / 2,
          size * 2 + min(size, 65536) * 2 <= budget {
          budget -= size * 2 + min(size, 65536) * 2
          do {
            if try FileComparison.proof(url, prefix: true, expectedBytes: size).digest == FileComparison.proof(other, prefix: true, expectedBytes: size).digest,
              try FileComparison.equal(url, other, expectedBytes: size) {
              evidence = .init(owner: "Downloads", kind: .installer, finding: .duplicateDownload, rule: "downloads.identical")
              evidence?.note = other.lastPathComponent
            }
          } catch is CancellationError { throw CancellationError() } catch { /* Changed files remain ordinary measurements. */ }
        }
      }
      if evidence == nil, ["dmg", "pkg", "mpkg", "xip", "zip"].contains(url.pathExtension.lowercased()) {
        let key = installerKey(url.lastPathComponent)
        let matches = applications.filter { app in
          // Append an extension so the same normalizer preserves dots in an app name.
          installerKey(app.name + ".app") == key
            || installerKey(URL(fileURLWithPath: app.path).lastPathComponent) == key
        }
        if url.pathExtension.lowercased() == "zip", matches.count != 1 { continue }
        evidence = .init(owner: matches.count == 1 ? matches[0].name : "Downloads", kind: .installer,
          finding: matches.count == 1 ? .installerMatch : .recognized, rule: "downloads.installer")
      }
      guard let evidence else { continue }
      var root = ScanRoot(group: .downloads, title: url.lastPathComponent, url: url, profile: .personal, source: .file)
      root.evidence = evidence
      roots.append(root)
    }
    var remainder = ScanRoot(group: .downloads, title: "Downloads", url: folder, profile: .personal)
    remainder.evidence = .init(owner: "Downloads", kind: .other, rule: "downloads.remainder")
    roots.append(remainder)
    return InventoryPartition.merging([], details: roots)
  }
}
