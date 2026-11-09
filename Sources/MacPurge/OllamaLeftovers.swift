import CryptoKit
import Darwin
import Foundation
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

struct OllamaBlob: Sendable {
  let url: URL
  let bytes: Int64
  let old: Bool
  let partial: Bool
}

struct OllamaBlobGuard: Codable, Sendable {
  let root: String
  let name: String
  let identity: FileIdentity
  let size: Int64
  let mayShareBlocks: Bool?

  func permits(_ url: URL, home: URL) -> Bool {
    let base = URL(fileURLWithPath: root)
    guard root.hasPrefix(home.path + "/"), !root.split(separator: "/").contains(".."),
      !root.hasPrefix(home.appending(path: ".Trash").path),
      !root.hasPrefix(home.appending(path: "Library/Mobile Documents").path),
      !root.hasPrefix(home.appending(path: "Library/CloudStorage").path) else { return false }
    let relative = String(root.dropFirst(home.path.count + 1)).lowercased()
    guard !relative.hasPrefix("library/application support/macpurge"), !relative.hasPrefix("library/application support/com.apple.tcc") else { return false }
    return url.path == base.appending(path: "blobs/" + name).path && OllamaLeftovers.blobName(name) != nil
  }

  func validate(_ url: URL) throws {
    let graph = try OllamaLeftovers.inspect(root: URL(fileURLWithPath: root))
    guard graph.complete, !graph.references.contains(name) else {
      throw CleanupFailure("Model references changed or could not be verified. Rescan before cleanup.")
    }
    try FileComparison.read(url) { _, info in
      guard FileIdentity(info) == identity, info.st_size == size, info.st_nlink == 1,
        Date.now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= OllamaLeftovers.minimumAge else {
        throw CleanupFailure("The model layer is recent or changed. Wait and rescan before cleanup.")
      }
    }
  }
}

enum OllamaLeftovers {
  static let minimumAge: TimeInterval = 72 * 3600
  struct Graph {
    let complete: Bool
    let references: Set<String>
    let leftovers: [OllamaBlob]
  }
  static func blobName(_ name: String) -> Bool? {
    guard name.hasPrefix("sha256-"), name.count >= 71 else { return nil }
    let digest = name.dropFirst(7).prefix(64)
    guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    let suffix = String(name.dropFirst(71))
    if suffix.isEmpty { return false }
    return suffix.range(of: "^-partial(?:-[0-9]+)?$", options: .regularExpression) != nil ? true : nil
  }

  static func inspect(root: URL, onDevice: Int32? = nil) throws -> Graph {
    let manifests = root.appending(path: "manifests"), blobs = root.appending(path: "blobs")
    let failed = Graph(complete: false, references: [], leftovers: [])
    guard !ScanExclusions.current.overlaps(manifests), !ScanExclusions.current.overlaps(blobs) else { return failed }
    do {
      let device = try TrashFiles.directory(root, enumerate: false) { _, info in info.st_dev }
      guard onDevice == nil || onDevice == device else { return failed }
      func files(_ directory: URL, depth: Int = 0) throws -> [URL] {
        guard depth <= 8 else { throw CleanupFailure("Model metadata exceeded the inspection budget.") }
        var paths: [URL] = []
        for entry in try DirectoryIndex.children(of: directory, onDevice: device, rejectUnsupported: true) {
          try Task.checkCancellation()
          if entry.url.lastPathComponent == ".DS_Store" { continue }
          if entry.directory { paths += try files(entry.url, depth: depth + 1) } else { paths.append(entry.url) }
          guard paths.count <= 10_000 else { throw CleanupFailure("Model metadata exceeded the inspection budget.") }
        }
        return paths.sorted { $0.path < $1.path }
      }
      let paths = try files(manifests)
      var references = Set<String>(), proofs: [FileProof] = [], budget = 16 * 1024 * 1024
      for path in paths {
        try Task.checkCancellation()
        guard let data = SmallMetadata.read(path), data.count <= budget,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let layers = json["layers"] as? [[String: Any]] else { return failed }
        budget -= data.count
        let proof = try FileComparison.proof(path)
        guard proof.digest == Data(SHA256.hash(data: data)) else { return failed }
        proofs.append(proof)
        var records = layers
        if let config = json["config"] as? [String: Any] { records.append(config) }
        for record in records {
          guard let digest = record["digest"] as? String, digest.hasPrefix("sha256:"), digest.count == 71,
            digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return failed }
          references.insert(digest.replacingOccurrences(of: "sha256:", with: "sha256-"))
        }
      }
      guard try files(manifests) == paths else { return failed }
      for proof in proofs where try FileComparison.proof(URL(fileURLWithPath: proof.path)) != proof { return failed }
      let entries = try DirectoryIndex.children(of: blobs, onDevice: device, rejectUnsupported: true)
      guard entries.count <= 50_000, references.isSubset(of: Set(entries.filter { !$0.directory }.map { $0.url.lastPathComponent })) else { return failed }
      var leftovers: [OllamaBlob] = []
      for entry in entries {
        try Task.checkCancellation()
        guard !entry.directory, !references.contains(entry.url.lastPathComponent),
          let partial = blobName(entry.url.lastPathComponent) else { continue }
        let blob = try FileComparison.read(entry.url) { _, info in
          OllamaBlob(url: entry.url, bytes: Int64(info.st_blocks) * 512,
            old: info.st_nlink == 1 && Date.now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= minimumAge,
            partial: partial)
        }
        leftovers.append(blob)
      }
      return Graph(complete: true, references: references, leftovers: leftovers)
    } catch is CancellationError { throw CancellationError() } catch { return failed }
  }

  static func guardFor(_ url: URL) throws -> OllamaBlobGuard {
    let root = url.deletingLastPathComponent().deletingLastPathComponent()
    guard url.deletingLastPathComponent().lastPathComponent == "blobs", blobName(url.lastPathComponent) != nil else {
      throw CleanupFailure("The model layer could not be verified.")
    }
    let proof = try FileComparison.read(url) { fd, info in
      OllamaBlobGuard(root: root.path, name: url.lastPathComponent, identity: FileIdentity(info), size: info.st_size,
                      mayShareBlocks: FileComparison.mayShareBlocks(fd))
    }
    try proof.validate(url)
    return proof
  }
}
