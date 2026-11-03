import Darwin
import Foundation

enum DirectoryIndex {
  struct Entry {
    let url: URL
    let directory: Bool
    let device: dev_t
  }
  struct Problem: Error { let code: Int32 }

  /// Direct children only, anchored to one opened directory descriptor.
  static func children(of url: URL) throws -> [Entry] {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else { throw Problem(code: errno) }
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
      guard name != "." && name != ".." else { continue }
      var info = stat()
      guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { continue }
        throw Problem(code: errno)
      }
      let type = info.st_mode & S_IFMT
      if type == S_IFDIR || type == S_IFREG {
        result.append(.init(url: url.appending(path: name), directory: type == S_IFDIR, device: info.st_dev))
      }
    }
    return result.sorted { $0.url.path < $1.url.path }
  }
}
