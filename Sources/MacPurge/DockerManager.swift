import Foundation
import Darwin

struct DockerPreview: Identifiable, Sendable {
  let id = UUID()
  let date: Date
  let engine: String
  let item: DockerItem
  let operation: DockerOperation
  let request: DockerRequest
}

struct DockerActionReceipt: Codable, Identifiable, Sendable {
  let id: UUID
  let date: Date
  let object: String
  let request: String
  let status: String
  let reclaimedBytes: Int64?
  let message: String?
}

actor DockerActionJournal {
  static let shared = DockerActionJournal(file: BuildIdentity.supportDirectory.appending(path: "DockerActions.jsonl"))
  let file: URL
  init(file: URL) { self.file = file }
  func append(_ receipt: DockerActionReceipt) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: file.path) {
      try Data().write(to: file, options: .withoutOverwriting)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: JSONEncoder().encode(receipt) + Data([10]))
    try handle.synchronize()
  }
}

actor DockerManager {
  typealias Transport = @Sendable (DockerRequest) async throws -> Data
  private let transport: Transport
  private let record: @Sendable (DockerActionReceipt) async throws -> Void
  private let now: @Sendable () -> Date
  private var plans: [UUID: DockerPreview] = [:]
  private var executing = false

  init(transport: @escaping Transport, record: @escaping @Sendable (DockerActionReceipt) async throws -> Void,
       now: @escaping @Sendable () -> Date = { .now }) {
    self.transport = transport; self.record = record; self.now = now
  }

  static func local(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DockerManager {
    let sockets = [home.appending(path: ".docker/run/docker.sock"), URL(fileURLWithPath: "/var/run/docker.sock"),
      home.appending(path: ".colima/default/docker.sock"), home.appending(path: ".orbstack/run/docker.sock")]
    let socket = sockets.first { FileManager.default.fileExists(atPath: $0.path) }?.resolvingSymlinksInPath()
    var socketInfo = stat()
    let pinned = socket.flatMap { url -> FileIdentity? in
      guard lstat(url.path, &socketInfo) == 0, socketInfo.st_mode & S_IFMT == S_IFSOCK else { return nil }
      return FileIdentity(socketInfo)
    }
    return DockerManager(transport: { request in
      guard let socket else { throw CleanupFailure("A local Docker socket was not found. Start Docker Desktop and try again.") }
      var current = stat()
      guard let pinned, lstat(socket.path, &current) == 0, current.st_mode & S_IFMT == S_IFSOCK,
        FileIdentity(current) == pinned else { throw CleanupFailure("The Docker socket changed. Reopen Docker management before continuing.") }
      return try await InventoryCommand.output("/usr/bin/curl", ["--disable", "--unix-socket", socket.path,
        "--max-time", "12", "--noproxy", "*", "--fail", "--silent", "--show-error", "--request", request.method,
        "--url", "http://localhost" + request.path], timeout: .seconds(14), captureError: true)
    }, record: { try await DockerActionJournal.shared.append($0) })
  }

  func overview() async throws -> DockerOverview {
    let info = try await transport(.init(method: "GET", path: "/info"))
    let version = try await transport(.init(method: "GET", path: "/version"))
    guard let engine = (try JSONSerialization.jsonObject(with: info) as? [String: Any])?["ID"] as? String, !engine.isEmpty else {
      throw CleanupFailure("Docker could not verify the local Engine identity.")
    }
    let api = (try JSONSerialization.jsonObject(with: version) as? [String: Any])?["ApiVersion"] as? String ?? ""
    let data = try await transport(.init(method: "GET", path: "/system/df?verbose=1"))
    return try DockerOverview.parse(data, engine: engine, apiVersion: api)
  }

  func preview(_ operation: DockerOperation) async throws -> DockerPreview {
    guard !executing else { throw CleanupFailure("Wait for the current Docker operation to finish.") }
    let request = try Self.request(operation)
    let state = try await overview()
    guard let item = state.items.first(where: { $0.operation == operation }) else {
      throw CleanupFailure("Docker no longer permits this operation. Refresh and review again.")
    }
    let preview = DockerPreview(date: now(), engine: state.engine, item: item, operation: operation, request: request)
    plans = plans.filter { now().timeIntervalSince($0.value.date) < 600 }
    plans[preview.id] = preview
    return preview
  }

  func discard(_ id: UUID) { plans.removeValue(forKey: id) }

  func execute(id: UUID, acknowledged: Bool) async throws -> DockerActionReceipt {
    guard acknowledged, !executing, let plan = plans.removeValue(forKey: id),
      (0..<600).contains(now().timeIntervalSince(plan.date)) else { throw CleanupFailure("Review this Docker operation again before continuing.") }
    executing = true
    defer { executing = false }
    let fresh = try await overview()
    guard fresh.engine == plan.engine,
      fresh.items.first(where: { $0.id == plan.item.id }) == plan.item else {
      throw CleanupFailure("Docker changed after the preview. Refresh and review again.")
    }
    try Task.checkCancellation()
    let started = DockerActionReceipt(id: plan.id, date: now(), object: plan.item.name, request: plan.request.display,
      status: "started", reclaimedBytes: nil, message: nil)
    try await record(started)
    do {
      let data = try await transport(plan.request)
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      if case .cache(let cacheID) = plan.operation {
        guard let removed = json?["CachesDeleted"] as? [String], removed.allSatisfy({ $0 == cacheID }) else {
          throw CleanupFailure("Docker could not confirm the exact cache result. Refresh before another operation.")
        }
      }
      let receipt = DockerActionReceipt(id: plan.id, date: now(), object: plan.item.name, request: plan.request.display,
        status: "completed", reclaimedBytes: (json?["SpaceReclaimed"] as? NSNumber)?.int64Value, message: nil)
      try await record(receipt)
      return receipt
    } catch {
      try? await record(.init(id: plan.id, date: now(), object: plan.item.name, request: plan.request.display,
        status: "unconfirmed", reclaimedBytes: nil, message: error.localizedDescription))
      throw error
    }
  }

  static func request(_ operation: DockerOperation) throws -> DockerRequest {
    let id = operation.id
    func hex(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
    switch operation {
    case .container:
      guard hex(id) else { throw CleanupFailure("Invalid Docker object identifier.") }
      return .init(method: "DELETE", path: "/containers/\(id)?force=false&v=false&link=false")
    case .image:
      let bare = id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
      guard hex(bare) else { throw CleanupFailure("Invalid Docker object identifier.") }
      return .init(method: "DELETE", path: "/images/sha256:\(bare)?force=false&noprune=true")
    case .cache:
      guard !id.isEmpty, id.count <= 128, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
        throw CleanupFailure("Invalid Docker object identifier.")
      }
      let filters = String(decoding: try JSONSerialization.data(withJSONObject: ["id": [id]], options: [.sortedKeys]), as: UTF8.self)
      var parts = URLComponents()
      parts.path = "/build/prune"
      parts.queryItems = [.init(name: "all", value: "true"), .init(name: "filters", value: filters)]
      return .init(method: "POST", path: parts.string!)
    }
  }
}
