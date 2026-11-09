import Foundation

enum DockerOperation: Codable, Hashable, Sendable {
  case container(String), image(String), cache(String)
  var id: String { switch self { case .container(let id), .image(let id), .cache(let id): id } }
}

struct DockerRequest: Sendable {
  let method: String
  let path: String
  var display: String { method + " " + (path.removingPercentEncoding ?? path) }
}

struct DockerItem: Identifiable, Equatable, Sendable {
  enum Kind: String, CaseIterable, Sendable { case container, image, volume, cache }
  let kind: Kind
  let objectID: String
  let name: String
  let bytes: Int64?
  let uniqueBytes: Int64?
  let detail: String
  let references: [String]
  let operation: DockerOperation?
  let warning: String
  var id: String { kind.rawValue + ":" + objectID }
}

struct DockerOverview: Sendable {
  let engine: String
  let items: [DockerItem]

  static func parse(_ data: Data, engine: String, apiVersion: String) throws -> Self {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CleanupFailure("Docker returned an invalid storage report.") }
    func list(_ legacy: String, _ current: [String]) -> [[String: Any]] {
      for key in current {
        if let items = (json[key] as? [String: Any])?["Items"] as? [[String: Any]] { return items }
      }
      return json[legacy] as? [[String: Any]] ?? []
    }
    func size(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value.flatMapNonnegative }
    let containers = list("Containers", ["ContainerUsage", "ContainersUsage"])
    let images = list("Images", ["ImageUsage", "ImagesUsage"])
    let volumes = list("Volumes", ["VolumeUsage", "VolumesUsage"])
    let caches = list("BuildCache", ["BuildCacheUsage"])
    var items: [DockerItem] = []
    for c in containers {
      guard let id = c["Id"] as? String else { continue }
      let names = c["Names"] as? [String] ?? []
      let state = c["State"] as? String ?? "unknown"
      let project = (c["Labels"] as? [String: String])?["com.docker.compose.project"]
      let image = c["ImageID"] as? String ?? c["Image"] as? String ?? ""
      let stopped = ["exited", "dead", "created"].contains(state)
      items.append(.init(kind: .container, objectID: id, name: names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? String(id.prefix(12)),
        bytes: size(c["SizeRw"]), uniqueBytes: size(c["SizeRw"]),
        detail: [state, project, image].compactMap { $0 }.joined(separator: " · "), references: [image],
        operation: stopped ? .container(id) : nil,
        warning: stopped ? "Removing this stopped container permanently loses its writable filesystem. Volumes are retained."
          : "Only containers explicitly reported as stopped can be removed."))
    }
    for image in images {
      guard let id = image["Id"] as? String else { continue }
      let users = containers.filter { $0["ImageID"] as? String == id }.compactMap { $0["Id"] as? String }
      let references = (image["Containers"] as? NSNumber)?.intValue
      let bytes = size(image["Size"]), shared = size(image["SharedSize"])
      let unique = bytes.flatMap { total in shared.flatMap { $0 <= total ? total - $0 : nil } }
      let unused = references == 0 && users.isEmpty
      items.append(.init(kind: .image, objectID: id, name: (image["RepoTags"] as? [String])?.first ?? String(id.prefix(19)),
        bytes: bytes, uniqueBytes: unique, detail: ReviewLanguage.format("%lld container references", Int64(references ?? -1)),
        references: users, operation: unused ? .image(id) : nil,
        warning: unused ? "The image must be downloaded or rebuilt again. Shared layers and parent images are retained."
          : "A container uses this image or its reference count is unknown."))
    }
    for volume in volumes {
      guard let name = volume["Name"] as? String else { continue }
      let usage = volume["UsageData"] as? [String: Any]
      items.append(.init(kind: .volume, objectID: name, name: name, bytes: size(usage?["Size"]), uniqueBytes: nil,
        detail: "Volume data may contain databases and personal files.", references: [], operation: nil,
        warning: "MacPurge never removes Docker volumes."))
    }
    let api = apiVersion.split(separator: ".").compactMap { Int($0) }
    let supportsID = api.count >= 2 && (api[0] > 1 || api[0] == 1 && api[1] >= 41)
    for cache in caches {
      guard let id = cache["ID"] as? String ?? cache["Id"] as? String else { continue }
      let unused = cache["InUse"] as? Bool == false && cache["Shared"] as? Bool == false && supportsID
      items.append(.init(kind: .cache, objectID: id, name: cache["Description"] as? String ?? id,
        bytes: size(cache["Size"]), uniqueBytes: cache["Shared"] as? Bool == false ? size(cache["Size"]) : nil,
        detail: id, references: cache["Parents"] as? [String] ?? [], operation: unused ? .cache(id) : nil,
        warning: unused ? "Only this unused private cache record will be pruned. The next build may take longer."
          : "Cache removal requires a supported Engine and a verified unused, unshared record."))
    }
    return Self(engine: engine, items: items.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : ($0.bytes ?? -1) > ($1.bytes ?? -1) })
  }
}

private extension Int64 {
  var flatMapNonnegative: Int64? { self >= 0 ? self : nil }
}
