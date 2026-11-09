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
  /// Preserve even a missing selection by its spelling. For existing ancestors compare
  /// filesystem identities, which also cover case aliases and alternate mount paths.
  struct ProtectedProjects {
    private let paths: [String]
    private var ancestors = Set<FileIdentity>()

    init(_ projects: [URL]) {
      paths = projects.map(\.path)
      for project in projects {
        var url = project.resolvingSymlinksInPath().standardizedFileURL
        while true {
          var info = stat()
          if stat(url.path, &info) == 0 { ancestors.insert(FileIdentity(info)) }
          let parent = url.deletingLastPathComponent()
          if url.path == "/" || parent.path == url.path { break }
          url = parent
        }
      }
    }

    func containsProject(under url: URL) -> Bool {
      if paths.contains(where: { $0 == url.path || $0.hasPrefix(url.path + "/") }) { return true }
      var info = stat()
      return !ancestors.isEmpty && lstat(url.path, &info) == 0
        && ancestors.contains(FileIdentity(info))
    }
  }

  static let intermediates = "Build/Intermediates.noindex"

  // The plist identifies the workspace. A folder name or a project name alone is insufficient.
  private static func workspacePath(of derived: URL) -> String? {
    guard let data = SmallMetadata.read(derived.appending(path: "info.plist")),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let path = plist["WorkspacePath"] as? String, path.hasPrefix("/"),
      path.components(separatedBy: "/").dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !ScanExclusions.current.contains(URL(fileURLWithPath: path))
    else { return nil }
    return path
  }

  private static func workspaceMarker(for url: URL) -> String? {
    switch url.pathExtension {
    case "xcworkspace": "contents.xcworkspacedata"
    case "xcodeproj": "project.pbxproj"
    default: nil
    }
  }

  private static func hasWorkspaceMarker(at url: URL) -> Bool {
    guard let marker = workspaceMarker(for: url) else { return false }
    let fd = open(
      url.appending(path: marker).path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var info = stat()
    return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
  }

  static func derivedFolder(for output: URL, home: URL) -> URL? {
    let folder = output.deletingLastPathComponent().deletingLastPathComponent()
    let base = home.appending(path: "Library/Developer/Xcode/DerivedData")
    guard folder.deletingLastPathComponent().path == base.path,
      folder.appending(path: intermediates).path == output.path
    else { return nil }
    return folder
  }

  static func outputWorkspace(
    in derived: URL, home: URL, projects: [URL]
  ) -> (path: String, profile: StorageProfile)? {
    guard let path = workspacePath(of: derived),
      !path.hasPrefix(home.appending(path: "Library/Developer/Xcode/DerivedData").path + "/")
    else { return nil }
    let local = path.hasPrefix(home.path + "/")
    guard local || owningRoot(workspace: path, selected: projects) != nil else { return nil }
    let url = URL(fileURLWithPath: path)
    if hasWorkspaceMarker(at: url) { return (path, .xcodeIntermediate) }
    // Treat only a missing local path as orphaned. Inaccessible projects and offline volumes are ambiguous.
    guard local, workspaceMarker(for: url) != nil else { return nil }
    let fd = open(path, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    if fd >= 0 { close(fd); return nil }
    return errno == ENOENT ? (path, .xcodeOrphanBuild) : nil
  }

  @concurrent static func outputRoots(home: URL, selected: [URL], onDevice: dev_t? = nil)
    async throws -> [ScanRoot]
  {
    let base = home.appending(path: "Library/Developer/Xcode/DerivedData")
    let children: [DirectoryIndex.Entry]
    do {
      children = try DirectoryIndex.children(of: base, onDevice: onDevice)
    } catch is DirectoryIndex.Problem {
      return []
    }  // The ordinary DerivedData scan reports access failures.
    var roots: [ScanRoot] = []
    let protection = ProtectedProjects(selected)
    for child in children where child.directory {
      try Task.checkCancellation()
      if let root = outputRoot(
        in: child.url, home: home, selected: selected, protection: protection)
      {
        roots.append(root)
      }
    }
    return roots
  }

  static func outputRoot(
    in derived: URL, home: URL, selected: [URL], protection: ProtectedProjects? = nil
  ) -> ScanRoot? {
    let output = derived.appending(path: intermediates)
    guard derivedFolder(for: output, home: home) != nil,
      let workspace = outputWorkspace(in: derived, home: home, projects: selected),
      !(protection ?? ProtectedProjects(selected)).containsProject(under: output),
      (try? TrashFiles.directory(output, enumerate: false) { _, _ in true }) == true
    else { return nil }
    let project = URL(fileURLWithPath: workspace.path).deletingPathExtension().lastPathComponent
    return .init(
      group: .xcode, title: project + " · Derleme ara çıktıları",
      url: output, profile: workspace.profile, workspace: workspace.path)
  }

  @concurrent static func compilerCacheRoots(in home: URL, onDevice device: dev_t?) async throws -> [ScanRoot] {
    let base = home.appending(path: "Library/Developer/Xcode/DerivedData")
    let children = try DirectoryIndex.childrenIfReadable(of: base, onDevice: device) ?? []
    let projects = children.filter {
      $0.directory && !DevelopmentCache.xcodeLeaves.contains($0.url.lastPathComponent)
    }.map(\.url)
    return try ([base] + projects).flatMap { parent in
      try Task.checkCancellation()
      return DevelopmentCache.xcodeLeaves.compactMap { name -> ScanRoot? in
        let url = parent.appending(path: name)
        guard (try? TrashFiles.directory(url, enumerate: false, { _, info in
          device == nil || info.st_dev == device
        })) == true else { return nil }
        return ScanRoot(group: .xcode, title: "Xcode · " + name, url: url, profile: .xcodeCompilerCache)
      }
    }
  }

  @concurrent static func derive(
    home: URL, selected: [URL], measurement: RootSize?, outputBytes: [String: Int64] = [:],
    only folders: Set<String>? = nil
  ) async throws
    -> [ProjectArtifact]
  {
    guard let measurement, measurement.measured, !selected.isEmpty else { return [] }
    let base = home.appending(path: "Library/Developer/Xcode/DerivedData")
    var output: [ProjectArtifact] = []
    for (folder, bytes) in measurement.largest.merging(outputBytes, uniquingKeysWith: +)
    where folder != "Kök dosyaları" && (folders?.contains(folder) ?? true) {
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
    guard !ScanExclusions.current.contains(url) else { return nil }
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
