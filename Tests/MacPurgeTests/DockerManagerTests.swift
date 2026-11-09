import Foundation
import Testing
@testable import MacPurge

struct DockerManagerTests {
  /// Test-only clock. Every access is serialized by the lock.
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date.now
    func now() -> Date { lock.withLock { value } }
    func advance() { lock.withLock { value = value.addingTimeInterval(601) } }
  }
  actor Mock {
    var running = false
    var engine = "fixture-engine"
    var writes: [DockerRequest] = []
    var records: [DockerActionReceipt] = []
    let id = String(repeating: "a", count: 64)
    func request(_ request: DockerRequest) throws -> Data {
      if request.method != "GET" { writes.append(request); return Data(#"{"CachesDeleted":["cache123"],"SpaceReclaimed":4096}"#.utf8) }
      if request.path == "/info" { return try JSONSerialization.data(withJSONObject: ["ID": engine]) }
      if request.path == "/version" { return Data(#"{"ApiVersion":"1.51"}"#.utf8) }
      return try JSONSerialization.data(withJSONObject: [
        "Containers": [["Id": id, "Names": ["/fixture"], "ImageID": "sha256:" + String(repeating: "b", count: 64),
          "State": running ? "running" : "exited", "SizeRw": 4096]],
        "Images": [["Id": "sha256:" + String(repeating: "b", count: 64), "RepoTags": ["fixture:latest"], "Size": 8192, "SharedSize": 4096, "Containers": 1]],
        "Volumes": [["Name": "database", "UsageData": ["Size": 1000, "RefCount": 0]]],
        "BuildCache": [["ID": "cache123", "Size": 4096, "InUse": false, "Shared": false]],
      ])
    }
    func start() { running = true }
    func replaceEngine() { engine = "another-engine" }
    func record(_ receipt: DockerActionReceipt) { records.append(receipt) }
  }

  @Test func previewsAreReadOnlyAndChangedOrReplayedPlansCannotWrite() async throws {
    let mock = Mock()
    let manager = DockerManager(transport: { try await mock.request($0) }, record: { await mock.record($0) })
    let preview = try await manager.preview(.container(String(repeating: "a", count: 64)))
    #expect(await mock.writes.isEmpty)
    await mock.start()
    await #expect(throws: (any Error).self) { _ = try await manager.execute(id: preview.id, acknowledged: true) }
    await #expect(throws: (any Error).self) { _ = try await manager.execute(id: preview.id, acknowledged: true) }
    #expect(await mock.writes.isEmpty)
    await #expect(throws: (any Error).self) { _ = try await manager.preview(.image("sha256:" + String(repeating: "b", count: 64))) }
  }

  @Test func onlyExactIdsAreRemovedAndVolumesHaveNoAction() async throws {
    let mock = Mock()
    let manager = DockerManager(transport: { try await mock.request($0) }, record: { await mock.record($0) })
    let state = try await manager.overview()
    #expect(state.items.first { $0.kind == .volume }?.operation == nil)
    let preview = try await manager.preview(.cache("cache123"))
    #expect(preview.request.path.contains("filters="))
    #expect(preview.request.display.contains("cache123"))
    _ = try await manager.execute(id: preview.id, acknowledged: true)
    #expect(await mock.writes.count == 1)
    #expect(await mock.records.count == 2)
    await #expect(throws: (any Error).self) { _ = try await manager.execute(id: preview.id, acknowledged: true) }
    await #expect(throws: (any Error).self) { _ = try await manager.preview(.container("../../volumes/database")) }
  }

  @Test func replacementEngineAndUnacknowledgedPlansCannotWrite() async throws {
    let mock = Mock()
    let manager = DockerManager(transport: { try await mock.request($0) }, record: { await mock.record($0) })
    let preview = try await manager.preview(.container(String(repeating: "a", count: 64)))
    await #expect(throws: (any Error).self) { _ = try await manager.execute(id: preview.id, acknowledged: false) }
    await mock.replaceEngine()
    await #expect(throws: (any Error).self) { _ = try await manager.execute(id: preview.id, acknowledged: true) }
    #expect(await mock.writes.isEmpty)
  }
  @Test func expiredPlansAndFailedAuditWritesPreventMutations() async throws {
    let mock = Mock(), clock = Clock()
    let manager = DockerManager(transport: { try await mock.request($0) }, record: { await mock.record($0) }, now: { clock.now() })
    let plan = try await manager.preview(.container(String(repeating: "a", count: 64)))
    clock.advance()
    await #expect(throws: (any Error).self) { _ = try await manager.execute(id: plan.id, acknowledged: true) }
    let failed = DockerManager(transport: { try await mock.request($0) }, record: { _ in throw POSIXError(.EIO) })
    let other = try await failed.preview(.container(String(repeating: "a", count: 64)))
    await #expect(throws: (any Error).self) { _ = try await failed.execute(id: other.id, acknowledged: true) }
    #expect(await mock.writes.isEmpty)
    let request = try DockerManager.request(.container(String(repeating: "a", count: 64)))
    #expect(request.path.contains("force=false") && request.path.contains("v=false"))
  }
}
