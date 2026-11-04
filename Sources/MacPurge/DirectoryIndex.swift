import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// Only explicitly selected project trees may start on another volume.
struct ScanVolumes: Sendable {
  private let home: URL
  private let homeDevice: dev_t?
  private let systemDevice: dev_t?
  private let dataDevice: dev_t?
  private let projects: [(URL, dev_t)]

  @concurrent static func read(home: URL, projects: [URL]) async -> Self {
    Self(home: home, projects: projects)
  }

  init(home: URL, projects: [URL]) {
    func device(_ path: String) -> dev_t? {
      var info = stat()
      return lstat(path, &info) == 0 ? info.st_dev : nil
    }
    self.home = home
    homeDevice = device(home.path)
    systemDevice = device("/")
    dataDevice = device("/System/Volumes/Data") ?? systemDevice
    self.projects = projects.compactMap { url in device(url.path).map { (url, $0) } }
  }

  func device(for url: URL) -> dev_t? {
    let path = url.path
    func contains(_ root: String) -> Bool {
      path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    if contains(home.path) { return homeDevice }
    if path == "/" || (contains("/System") && !contains("/System/Volumes/Data")) {
      return systemDevice
    }
    return dataDevice
  }

  func restrict(_ root: ScanRoot) -> ScanRoot {
    var root = root
    if root.expectedDevice == nil {
      root.expectedDevice =
        root.group == .projects
        ? projects.first(where: { $0.0.path == root.url.path })?.1 ?? device(for: root.url)
        : device(for: root.url)
    }
    return root
  }
}

enum DirectoryIndex {
  struct Entry {
    let url: URL
    let directory: Bool
    let device: dev_t
  }
  struct Problem: Error { let code: Int32 }

  static func childrenIfReadable(of url: URL, onDevice device: dev_t?) throws -> [Entry]? {
    do { return try children(of: url, onDevice: device) }
    catch is Problem { return nil }
  }

  /// Direct children only, anchored to one opened directory descriptor.
  static func children(of url: URL, onDevice expected: dev_t? = nil) throws -> [Entry] {
    guard !ScanExclusions.current.contains(url) else { return [] }
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else { throw Problem(code: errno) }
    var parent = stat()
    guard fstat(fd, &parent) == 0 else {
      let code = errno
      close(fd)
      throw Problem(code: code)
    }
    if let expected, parent.st_dev != expected {
      close(fd)
      throw Problem(code: EXDEV)
    }
    guard let stream = fdopendir(fd) else {
      let code = errno
      close(fd)
      throw Problem(code: code)
    }
    defer { closedir(stream) }
    var result: [Entry] = []
    while true {
      try Task.checkCancellation()
      errno = 0
      guard let entry = readdir(stream) else {
        if errno != 0 { throw Problem(code: errno) }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      guard name != "." && name != "..",
        !ScanExclusions.current.contains(url.appending(path: name)) else { continue }
      var info = stat()
      guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { continue }
        throw Problem(code: errno)
      }
      guard info.st_dev == parent.st_dev else { continue }
      let type = info.st_mode & S_IFMT
      if type == S_IFDIR || type == S_IFREG {
        result.append(
          .init(url: url.appending(path: name), directory: type == S_IFDIR, device: info.st_dev))
      }
    }
    return result.sorted { $0.url.path < $1.url.path }
  }
}
