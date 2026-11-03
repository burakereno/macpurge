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
    guard workspace.hasPrefix("/"),
      !workspace.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { return nil }
    return selected.filter {
      workspace == $0.path || workspace.hasPrefix($0.path == "/" ? "/" : $0.path + "/")
    }.max {
      $0.path.count < $1.path.count
    }
  }
  static let intermediates = "Build/Intermediates.noindex"

  // The plist identifies the workspace. A folder name or a project name alone is insufficient.
  static func workspace(of derived: URL) -> String? {
    guard let data = SmallMetadata.read(derived.appending(path: "info.plist")),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let path = plist["WorkspacePath"] as? String, path.hasPrefix("/"),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { return nil }
    let url = URL(fileURLWithPath: path)
    let marker: String
    switch url.pathExtension {
    case "xcworkspace": marker = "contents.xcworkspacedata"
    case "xcodeproj": marker = "project.pbxproj"
    default: return nil
    }
    let fd = open(
      url.appending(path: marker).path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG ? path : nil
  }

  @concurrent static func outputRoots(home: URL, selected: [URL]) async throws -> [ScanRoot] {
    guard !selected.isEmpty else { return [] }
    let base = home.appending(path: "Library/Developer/Xcode/DerivedData")
    let children: [DirectoryIndex.Entry]
    do { children = try DirectoryIndex.children(of: base) } catch is DirectoryIndex.Problem {
      return []
    }  // The ordinary DerivedData scan reports access failures.
    var roots: [ScanRoot] = []
    for child in children where child.directory {
      try Task.checkCancellation()
      let output = child.url.appending(path: intermediates)
      guard let workspace = workspace(of: child.url),
        !workspace.hasPrefix(base.path + "/"),
        owningRoot(workspace: workspace, selected: selected) != nil,
        !selected.contains(where: { $0.path == output.path || $0.path.hasPrefix(output.path + "/") }
        ),
        (try? TrashFiles.directory(output, enumerate: false) { _, _ in true }) == true
      else { continue }
      let project = URL(fileURLWithPath: workspace).deletingPathExtension().lastPathComponent
      roots.append(
        .init(
          group: .xcode, title: project + " · " + ReviewLanguage.text("Derleme ara çıktıları"),
          url: output, profile: .xcodeIntermediate, workspace: workspace))
    }
    return roots
  }

  @concurrent static func derive(
    home: URL, selected: [URL], measurement: RootSize?, outputBytes: [String: Int64] = [:]
  ) async throws
    -> [ProjectArtifact]
  {
    guard let measurement, measurement.measured, !selected.isEmpty else { return [] }
    let base = home.appending(path: "Library/Developer/Xcode/DerivedData")
    var output: [ProjectArtifact] = []
    for (folder, bytes) in measurement.largest.merging(outputBytes, uniquingKeysWith: +)
    where folder != "Kök dosyaları" {
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
