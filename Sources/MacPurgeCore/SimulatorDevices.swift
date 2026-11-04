import Darwin
import Foundation

package struct SimulatorDevice: Hashable, Codable, Sendable {
  package let id: UUID
  package let name: String
  package let runtime: String?

  package var detail: String {
    let prefix = "com.apple.CoreSimulator.SimRuntime."
    let display = runtime.map { raw in
      guard raw.hasPrefix(prefix) else { return raw }
      let parts = raw.dropFirst(prefix.count).split(separator: "-")
      guard let platform = parts.first else { return raw }
      let version = parts.dropFirst().joined(separator: ".")
      return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }
    return [display, String(id.uuidString.prefix(8))].compactMap { $0 }.joined(separator: " · ")
  }
}

package struct RuntimeUsage: Hashable, Codable, Sendable {
  package let lastUsed: Date?
  package let devices: [SimulatorDevice]
  package let deviceListComplete: Bool
  package let multipleImages: Bool

  package init(
    lastUsed: Date?, devices: [SimulatorDevice], deviceListComplete: Bool, multipleImages: Bool
  ) {
    self.lastUsed = lastUsed
    self.devices = devices
    self.deviceListComplete = deviceListComplete
    self.multipleImages = multipleImages
  }
}

package struct SimulatorInventory: Sendable {
  package var roots: [ScanRoot] = []
  package var note: String?

  private struct Metadata: Decodable {
    let name: String?
    let runtime: String?
  }

  /// Uses only the local device set and its small configuration plists.
  /// Even an unbooted device or one with a missing runtime can occupy space.
  @concurrent package static func discover(in directory: URL, onDevice expected: dev_t? = nil)
    async throws -> Self
  {
    try Task.checkCancellation()
    guard !ScanExclusions.current.contains(directory) else { return Self() }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else {
      return Self(note: errno == ENOENT ? nil : "CoreSimulator cihaz klasörüne erişilemedi.")
    }
    var parent = stat()
    guard fstat(fd, &parent) == 0, expected == nil || expected == parent.st_dev else {
      close(fd)
      return Self(note: "CoreSimulator cihaz klasörüne erişilemedi.")
    }
    guard let stream = fdopendir(fd) else {
      close(fd)
      return Self(note: "CoreSimulator cihaz klasörü listelenemedi.")
    }
    defer { closedir(stream) }
    var inventory = Self()
    while true {
      try Task.checkCancellation()
      errno = 0
      guard let entry = readdir(stream) else {
        if errno != 0 { inventory.note = "Cihaz listesinin bir kısmı okunamadı." }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      guard let id = UUID(uuidString: name),
        !ScanExclusions.current.contains(directory.appending(path: name)) else { continue }
      var info = stat()
      guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        inventory.note = "Cihaz listesinin bir kısmı okunamadı."
        continue
      }
      guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == parent.st_dev else { continue }
      let metadata = metadata(in: name, parent: fd)
      let device = SimulatorDevice(
        id: id, name: metadata?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Adsız simülatör",
        runtime: metadata?.runtime)
      inventory.roots.append(
        ScanRoot(
          group: .simulators, title: device.name,
          url: directory.appending(path: name), profile: .simulatorData, device: device))
    }
    inventory.roots.sort { ($0.title, $0.id) < ($1.title, $1.id) }
    return inventory
  }

  private static func metadata(in name: String, parent: Int32) -> Metadata? {
    let fd = openat(
      parent, name + "/device.plist", O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    let limit = 128 * 1024
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
      let data = try? handle.read(upToCount: limit + 1), data.count <= limit
    else { return nil }
    return try? PropertyListDecoder().decode(Metadata.self, from: data)
  }
}

/// Matches exact simulator-owned locations. In particular, a folder named
/// Caches or tmp inside Documents remains device data.
package enum SimulatorDirectory {
  case device, data, library, containers, containerData, applications, sandbox, cache, other

  package var checksChildName: Bool { self != .cache && self != .other }

  package func descending(into name: String) -> Self {
    switch (self, name) {
    case (.device, "data"): .data
    case (.data, "Library"), (.sandbox, "Library"): .library
    case (.library, "Caches"), (.data, "tmp"), (.sandbox, "tmp"), (.cache, _): .cache
    case (.data, "Containers"): .containers
    case (.containers, "Data"): .containerData
    case (.containerData, "Application"): .applications
    case (.applications, _) where UUID(uuidString: name) != nil: .sandbox
    default: .other
    }
  }
}
