import Foundation

/// Read-only allocated space of a user-selected directory. The byte count is
/// not an estimate of the space deleting the directory would return.
public struct DirectoryMeasurement: Sendable {
  public let allocatedBytes: Int64
  public let buildOutputBytes: Int64
  public let fileCount: Int
  public let unreadableEntries: Int
  public let isComplete: Bool

  public static func measure(_ url: URL) async throws -> Self {
    let result = try await StorageMeter.measure(
      ScanRoot(group: .projects, title: url.lastPathComponent, url: url, profile: .project))
    guard result.measured else { throw CocoaError(.fileReadUnknown) }
    return Self(
      allocatedBytes: result.bytes, buildOutputBytes: result.outputBytes, fileCount: result.files,
      unreadableEntries: result.missed, isComplete: result.state == .complete)
  }
}
