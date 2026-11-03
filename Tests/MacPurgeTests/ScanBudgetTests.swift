import Darwin
import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct ScanBudgetTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MACPURGE_BENCHMARK"] == "1"))
  func syntheticStorageSweep() async throws {
    let root = URL(fileURLWithPath: "/private/tmp").appending(
      path: "macpurge-bench-" + UUID().uuidString)
    let many = root.appending(path: "many")
    let one = root.appending(path: "one")
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: many, withIntermediateDirectories: true)
    try fm.createDirectory(at: one, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 100_000).write(to: one.appending(path: "payload"))
    for bucket in 0..<100 {
      let folder = many.appending(path: String(bucket))
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      let dir = open(folder.path, O_RDONLY | O_DIRECTORY)
      defer { close(dir) }
      for index in 0..<1000 {
        let fd = openat(dir, String(index), O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var byte: UInt8 = 1
        let n = write(fd, &byte, 1)
        close(fd)
        guard n == 1 else { throw CocoaError(.fileWriteOutOfSpace) }
      }
    }
    func ms(_ duration: Duration) -> Double {
      Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    let clock = ContinuousClock()
    for path in [one, many] {
      let target = ScanRoot(group: .projects, title: path.lastPathComponent, url: path)
      var times: [Double] = []
      for _ in 0..<10 {
        let start = clock.now
        let m = try await StorageMeter.measure(target)
        #expect(m.files == (path == one ? 1 : 100_000))
        times.append(ms(start.duration(to: clock.now)))
      }
      print(
        "MacPurge fixture", path.lastPathComponent, "first-ms", times[0], "10-run-p95-ms",
        times.sorted().last!)
    }
    let target = ScanRoot(group: .projects, title: "cancel", url: many)
    var times: [Double] = []
    for _ in 0..<10 {
      let task = Task { try await StorageMeter.measure(target) }
      try await Task.sleep(for: .milliseconds(10))
      let start = clock.now
      task.cancel()
      do {
        _ = try await task.value
        Issue.record("Expected cancellation")
      } catch is CancellationError {}
      times.append(ms(start.duration(to: clock.now)))
    }
    print("MacPurge cancellation 10-run-p95-ms", times.sorted().last!)
  }
}
