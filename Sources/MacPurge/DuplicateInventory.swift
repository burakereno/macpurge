import Darwin
import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

struct DuplicateGroup: Identifiable, Sendable {
  let id: Data
  let files: [FileProof]
  var bytes: Int64 { files.first?.logicalBytes ?? 0 }
  var estimatedRecovery: Int64 {
    files.dropFirst().filter { $0.links == 1 && $0.mayShareBlocks == false }.reduce(0) { $0 + $1.allocatedBytes }
  }
}

struct DuplicateGuard: Codable, Sendable {
  let scope: String
  let original: FileProof
  let survivor: FileProof

  func validate(_ path: URL) throws {
    let keep = URL(fileURLWithPath: survivor.path)
    let freshKeep = try FileComparison.proof(keep, expectedBytes: survivor.logicalBytes)
    let fresh = try FileComparison.proof(path, expectedBytes: original.logicalBytes)
    guard freshKeep == survivor, fresh.identity == original.identity, fresh.digest == original.digest,
      fresh.logicalBytes == original.logicalBytes, fresh.links == 1,
      freshKeep.identity != fresh.identity, try FileComparison.equal(path, keep) else {
      throw CleanupFailure("The duplicate or its retained copy changed. Search again.")
    }
  }
}

struct DuplicateReport: Identifiable, Sendable {
  let id = UUID()
  let root: URL
  let home: URL
  let groups: [DuplicateGroup]
  let examined: Int
  let unreadable: Int
  let limited: Bool

  func plan(selected: Set<String>, engine: CacheTrash) async throws -> TrashPlan {
    guard !selected.isEmpty else { throw CleanupFailure("Select the copies to review, keeping at least one in every group.") }
    let known = Set(groups.flatMap(\.files).map(\.path))
    guard selected.isSubset(of: known) else { throw CleanupFailure("The duplicate selection does not match this search.") }
    var rows: [ReportItem] = []
    var reviews: [String: ManualReview] = [:]
    for group in groups {
      let moving = group.files.filter { selected.contains($0.path) }
      guard !moving.isEmpty else { continue }
      guard let survivor = group.files.first(where: { !selected.contains($0.path) }) else {
        throw CleanupFailure("Keep at least one copy of every duplicate group.")
      }
      for file in moving {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: file.path)
        guard file.links == 1, file.path.hasPrefix(home.path + "/"),
          DuplicateInventory.allowed(url, root: root, home: home),
          try FileComparison.proof(url, expectedBytes: file.logicalBytes) == file else { throw CleanupFailure("The file could not be verified. Search again.") }
        let proof = DuplicateGuard(scope: root.path, original: file, survivor: survivor)
        try proof.validate(url)
        let row = ReportItem(id: file.path, name: url.lastPathComponent, category: ScanGroup.other.rawValue,
          path: file.path, bytes: file.allocatedBytes, status: "complete", safety: SafetyLevel.review.rawValue,
          reason: "An identical copy will be retained. Removing this copy moves it to the Trash.", basis: "allocated",
          eligibleBytes: 0, modified: Date(timeIntervalSince1970: Double(file.modifiedSeconds)), parts: [:],
          volume: file.identity.device, directoryInode: file.identity.inode)
        rows.append(row)
        reviews[row.id] = ManualReview(scope: nil, title: row.name, profile: .personal,
          category: row.category, path: file.path, device: file.identity.device, inode: file.identity.inode,
          file: true, warning: row.reason, duplicate: proof)
      }
    }
    var plan = await engine.prepare(items: rows, reportID: id, projects: [], manual: reviews)
    for i in plan.targets.indices {
      if plan.targets[i].review?.duplicate?.original.mayShareBlocks != false {
        plan.targets[i].snapshot.sharedBytes = plan.targets[i].snapshot.bytes
      }
    }
    return plan
  }
}

enum DuplicateInventory {
  static let skipped = Set(["Library", "Applications", "node_modules", "Pods", "Carthage", "target", "build", "vendor", "venv", "site-packages", "__pycache__"])
  static let bundles = Set(["app", "framework", "bundle", "photoslibrary", "musiclibrary", "fcpbundle", "logicx", "band", "xcodeproj", "xcworkspace", "xcarchive", "pages", "numbers", "key", "rtfd", "sparsebundle"])

  static func allowed(_ url: URL, root: URL, home: URL) -> Bool {
    guard !ScanExclusions.current.overlaps(url), url.path == root.path || url.path.hasPrefix(root.path + "/") else { return false }
    let parts = url.path.hasPrefix(home.path + "/") ? String(url.path.dropFirst(home.path.count + 1)).split(separator: "/").map(String.init) : [url.lastPathComponent]
    return !parts.contains { $0.hasPrefix(".") || skipped.contains($0) || bundles.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
  }

  @concurrent static func scan(root: URL, home: URL, minimumBytes: Int64 = 1_048_576,
                              maximumFiles: Int = 250_000, hashBudget: Int64 = 64 * 1024 * 1024 * 1024) async throws -> DuplicateReport {
    try Task.checkCancellation()
    guard allowed(root, root: root, home: home) else { throw CleanupFailure("Choose a personal folder outside application and dependency data.") }
    let device = try TrashFiles.directory(root, enumerate: false) { _, info in info.st_dev }
    var stack: [(URL, Int)] = [(root, 0)], seen = Set<FileIdentity>()
    var sizes: [Int64: [URL]] = [:], examined = 0, unreadable = 0, limited = false
    while let (folder, depth) = stack.popLast() {
      try Task.checkCancellation()
      guard depth < 160, examined < maximumFiles else { limited = true; continue }
      let entries: [DirectoryIndex.Entry]
      do { entries = try DirectoryIndex.children(of: folder, onDevice: device) }
      catch is DirectoryIndex.Problem { unreadable += 1; continue }
      for entry in entries where allowed(entry.url, root: root, home: home) {
        try Task.checkCancellation()
        if entry.directory { stack.append((entry.url, depth + 1)); continue }
        examined += 1
        if examined > maximumFiles { limited = true; break }
        do {
          try FileComparison.read(entry.url) { _, info in
            if info.st_dev == device, info.st_size >= max(1, minimumBytes), seen.insert(FileIdentity(info)).inserted {
              sizes[info.st_size, default: []].append(entry.url)
            }
          }
        } catch { unreadable += 1 }
      }
    }
    var groups: [DuplicateGroup] = [], budget = hashBudget
    for size in sizes.keys.sorted(by: >) {
      guard let paths = sizes[size], paths.count > 1 else { continue }
      var prefixes: [Data: [URL]] = [:]
      for path in paths.sorted(by: { $0.path < $1.path }) {
        try Task.checkCancellation()
        let prefixBytes = min(size, 65536)
        guard prefixBytes <= budget else { limited = true; continue }
        budget -= prefixBytes
        do { let proof = try FileComparison.proof(path, prefix: true, expectedBytes: size); prefixes[proof.digest, default: []].append(path) }
        catch is CancellationError { throw CancellationError() } catch { unreadable += 1 }
      }
      for matching in prefixes.values where matching.count > 1 {
        var hashes: [Data: [FileProof]] = [:]
        for path in matching {
          try Task.checkCancellation()
          guard size <= budget else { limited = true; continue }
          budget -= size
          do { let proof = try FileComparison.proof(path, expectedBytes: size); hashes[proof.digest, default: []].append(proof) }
          catch is CancellationError { throw CancellationError() } catch { unreadable += 1 }
        }
        for (digest, files) in hashes where files.count > 1 {
          groups.append(.init(id: digest, files: files.sorted { $0.path < $1.path }))
        }
      }
    }
    groups.sort { $0.bytes == $1.bytes ? $0.files[0].path < $1.files[0].path : $0.bytes > $1.bytes }
    return DuplicateReport(root: root, home: home, groups: groups, examined: examined, unreadable: unreadable, limited: limited)
  }
}
