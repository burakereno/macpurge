import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

enum DiskStatusStyle: String, CaseIterable {
  case icon, freeSpace, usage, freeSpaceAndUsage
  var showsFreeSpace: Bool { self == .freeSpace || self == .freeSpaceAndUsage }
  var showsUsage: Bool { self == .usage || self == .freeSpaceAndUsage }
  var title: String {
    switch self {
    case .icon: "Icon only"
    case .freeSpace: "Free space"
    case .usage: "Usage ring"
    case .freeSpaceAndUsage: "Free space and usage ring"
    }
  }
}

struct DiskStatusConfiguration: Equatable {
  let visible: Bool
  let style: DiskStatusStyle
  let language: String
}

struct DiskStatusPresentation {
  let free: Int64
  let capacity: Int64
  var usedFraction: Double { Double(capacity - free) / Double(capacity) }
  var usedPercent: Int { Int((usedFraction * 100).rounded()) }
  init?(_ reading: VolumeReading?) {
    guard let reading, reading.bytes > 0 else { return nil }
    capacity = reading.bytes
    free = min(capacity, max(0, reading.free))
  }
}

/// Only volume capacity metadata is read. This type has no inventory-scan dependency.
@MainActor final class DiskCapacityMonitor {
  private(set) var reading: VolumeReading?
  private(set) var measuredAt: Date?
  var onUpdate: (() -> Void)?
  private let home: URL
  private let read: @Sendable (URL) async -> VolumeReading?
  private let interval: Duration
  private var work: Task<Void, Never>?
  private var generation = UUID()
  private var refreshing = false
  var isRunning: Bool { work != nil }

  init(home: URL = FileManager.default.homeDirectoryForCurrentUser, interval: Duration = .seconds(30),
       read: @escaping @Sendable (URL) async -> VolumeReading? = VolumeReading.read) {
    self.home = home; self.interval = interval; self.read = read
  }
  deinit { work?.cancel() }

  func start() {
    guard work == nil else { return }
    let token = UUID(); generation = token
    let interval = interval
    work = Task { [weak self] in
      while !Task.isCancelled {
        guard self != nil else { return }
        await self?.refresh()
        do { try await Task.sleep(for: interval) } catch { return }
        guard self?.generation == token else { return }
      }
    }
  }

  func stop() {
    generation = UUID()
    work?.cancel(); work = nil
    reading = nil; measuredAt = nil
  }

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    let token = generation
    defer { refreshing = false }
    let fresh = await read(home)
    guard !Task.isCancelled, generation == token else { return }
    reading = DiskStatusPresentation(fresh) == nil ? nil : fresh
    measuredAt = reading == nil ? nil : .now
    onUpdate?()
  }
}
