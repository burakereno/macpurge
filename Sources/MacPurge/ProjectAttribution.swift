import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct ProjectArtifact: Sendable, Identifiable {
  let url: URL
  let project: URL
  let bytes: Int64
  let modified: Date?
  var id: String { url.path }
}

enum ProjectAttribution {
  static func owningRoot(workspace: String, selected: [URL]) -> URL? {
    guard workspace.hasPrefix("/") else { return nil }
    let path = URL(fileURLWithPath: workspace).standardizedFileURL.path
    return selected.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max {
      $0.path.count < $1.path.count
    }
  }
  @concurrent static func derive(home: URL, selected: [URL], measurement: RootSize?) async throws
    -> [ProjectArtifact]
  {
    guard let measurement, measurement.measured, !selected.isEmpty else { return [] }
    let base = home.appending(path: "Library/Developer/Xcode/DerivedData")
    var output: [ProjectArtifact] = []
    for (folder, bytes) in measurement.largest where folder != "Kök dosyaları" {
      try Task.checkCancellation()
      let url = base.appending(path: folder)
      let metadata = url.appending(path: "info.plist")
      guard let data = SmallMetadata.read(metadata),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        let workspace = plist["WorkspacePath"] as? String,
        let owner = owningRoot(workspace: workspace, selected: selected),
        !url.path.hasPrefix(owner.path + "/")
      else { continue }
      let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      output.append(.init(url: url, project: owner, bytes: bytes, modified: mtime))
    }
    return output.sorted { $0.bytes > $1.bytes }
  }
}

enum SmallMetadata {
  static func read(_ url: URL, limit: Int = 512 * 1024) -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
      let data = try? handle.read(upToCount: limit + 1), data.count <= limit
    else { return nil }
    return data
  }
}
