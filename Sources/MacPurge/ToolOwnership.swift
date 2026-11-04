import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum ModelInventory {
  /// A manifest references blobs by digest. Count a shared blob once in its
  /// own row, never once per model referencing it.
  @concurrent static func ollama(at root: URL, onDevice: dev_t? = nil) async throws -> [ScanRoot] {
    let manifests = root.appending(path: "manifests")
    var info = stat()
    guard lstat(manifests.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
    var byModel: [String: Set<String>] = [:]
    var failed = false
    func enumerate(_ dir: URL, _ depth: Int) throws {
      guard depth <= 5 else {
        failed = true
        return
      }
      guard let children = try? DirectoryIndex.children(of: dir, onDevice: onDevice) else {
        failed = true
        return
      }
      for child in children {
        try Task.checkCancellation()
        let url = child.url
        if child.directory {
          try enumerate(url, depth + 1)
          continue
        }
        guard let data = SmallMetadata.read(url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let layers = json["layers"] as? [[String: Any]]
        else {
          failed = true
          continue
        }
        let records = layers + ((json["config"] as? [String: Any]).map { [$0] } ?? [])
        let digests = records.compactMap { $0["digest"] as? String }
        guard digests.count == records.count,
          digests.allSatisfy({
            $0.hasPrefix("sha256:") && $0.count == 71 && $0.dropFirst(7).allSatisfy(\.isHexDigit)
          })
        else {
          failed = true
          continue
        }
        let relative = String(url.path.dropFirst(manifests.path.count + 1))
        byModel[relative] = Set(digests)
      }
    }
    try enumerate(manifests, 0)
    guard !byModel.isEmpty, !failed else { return [] }
    var sizes = Dictionary(uniqueKeysWithValues: byModel.keys.map { ($0, Int64(0)) })
    var shared: Int64 = 0
    var unclaimed: Int64 = 0
    var owners: [String: [String]] = [:]
    for (model, digests) in byModel {
      for digest in digests { owners[digest, default: []].append(model) }
    }
    let blobs = root.appending(path: "blobs")
    guard let files = try? DirectoryIndex.children(of: blobs, onDevice: onDevice) else { return [] }
    var seen = Set<FileKey>()
    var available = Set<String>()
    for file in files {
      try Task.checkCancellation()
      let url = file.url
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
      let name = url.lastPathComponent.replacingOccurrences(of: "sha256-", with: "sha256:")
      available.insert(name)
      let key = FileKey(device: info.st_dev, inode: info.st_ino)
      // An unusual linked layout is better measured as one directory.
      guard info.st_nlink == 1, seen.insert(key).inserted else { return [] }
      let bytes = Int64(info.st_blocks) * 512
      let list = owners[name] ?? []
      if list.count == 1 {
        sizes[list[0], default: 0] += bytes
      } else if list.isEmpty {
        unclaimed += bytes
      } else {
        shared += bytes
      }
    }
    guard Set(owners.keys).isSubset(of: available) else { return [] }
    var rows = sizes.map { name, bytes in
      ScanRoot(
        group: .models, title: "Ollama · " + name, url: manifests.appending(path: name),
        profile: .personal, source: .allocation(bytes))
    }
    if shared > 0 {
      rows.append(
        .init(
          group: .models, title: "Ollama · paylaşılan katmanlar", url: blobs, profile: .personal,
          source: .allocation(shared)))
    }
    if unclaimed > 0 {
      rows.append(
        .init(
          group: .models, title: "Ollama · eşleşmeyen katmanlar", url: blobs, profile: .personal,
          source: .allocation(unclaimed)))
    }
    return rows
  }
}

enum ComposeInventory {
  struct Image: Decodable {
    let Id: String
    let Size: Int64?
    let SharedSize: Int64?
  }
  struct Container: Decodable {
    let SizeRw: Int64?
    let ImageID: String?
    let Labels: [String: String]?
  }
  struct Volume: Decodable {
    let Name: String
    let Labels: [String: String]?
    let UsageData: Usage?
    struct Usage: Decodable {
      let Size: Int64?
      let RefCount: Int?
    }
  }
  struct Payload: Decodable {
    struct List<T: Decodable>: Decodable {
      let TotalSize: Int64?
      let Items: [T]?
    }
    struct Build: Decodable {
      let Size: Int64?
      let Shared: Bool?
    }
    let LayersSize: Int64?
    let BuilderSize: Int64?
    let BuildCache: [Build]?
    let ImageUsage: List<Image>?
    let ContainerUsage: List<Container>?
    let VolumeUsage: List<Volume>?
    let BuildCacheUsage: List<Build>?
    let Images: [Image]?
    let Containers: [Container]?
    let Volumes: [Volume]?
    let ImagesUsage: List<Image>?
    let ContainersUsage: List<Container>?
    let VolumesUsage: List<Volume>?
  }
  static func rows(data: Data, socket: URL) throws -> [ScanRoot] {
    let report = try JSONDecoder().decode(Payload.self, from: data)
    let imageUsage = report.ImageUsage ?? report.ImagesUsage
    let containerUsage = report.ContainerUsage ?? report.ContainersUsage
    let volumeUsage = report.VolumeUsage ?? report.VolumesUsage
    let containers = containerUsage?.Items ?? report.Containers
    let volumes = volumeUsage?.Items ?? report.Volumes
    var consumers: [String: Set<String>] = [:]
    var bytes: [String: Int64] = [:]
    var directories: [String: String] = [:]
    for container in containers ?? [] {
      let name = container.Labels?["com.docker.compose.project"] ?? ""
      if let id = container.ImageID { consumers[id, default: []].insert(name) }
      if !name.isEmpty, let path = container.Labels?["com.docker.compose.project.working_dir"],
        path.hasPrefix("/")
      {
        directories[name] = path
      }
    }
    for image in imageUsage?.Items ?? report.Images ?? [] {
      guard let names = consumers[image.Id], names.count == 1, let name = names.first,
        directories[name] != nil,
        let total = image.Size, let shared = image.SharedSize, shared >= 0, shared <= total
      else { continue }
      bytes[name, default: 0] += total - shared
    }
    var rows = bytes.map { name, size in
      ScanRoot(
        group: .docker, title: "Compose · " + name, url: URL(fileURLWithPath: directories[name]!),
        profile: .personal, source: .report(size))
    }
    var assignedVolumes: Int64 = 0
    for volume in volumes ?? [] {
      guard let project = volume.Labels?["com.docker.compose.project"],
        let used = volume.UsageData?.RefCount, used > 0
      else { continue }
      let size = volume.UsageData?.Size.flatMap { $0 >= 0 ? $0 : nil }
      assignedVolumes += size ?? 0
      rows.append(
        .init(
          group: .docker, title: "Volume · \(project)/\(volume.Name)", url: socket,
          profile: .personal, source: .report(size)))
    }
    func total(_ values: [Int64?]?) -> Int64? {
      guard let values, values.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
      return values.compactMap { $0 }.reduce(0, +)
    }
    func remainder(_ name: String, _ total: Int64?, assigned: Int64 = 0) {
      let size = total.flatMap { $0 >= assigned ? $0 - assigned : nil }
      rows.append(
        .init(
          group: .docker, title: "Docker · " + name, url: socket,
          profile: .personal, source: .report(size)))
    }
    // Compose rows are partitions of these totals. Legacy layer totals already deduplicate images.
    remainder(
      "Images", imageUsage.map { $0.TotalSize ?? 0 } ?? report.LayersSize,
      assigned: bytes.values.reduce(0, +))
    remainder(
      "Containers", containerUsage.map { $0.TotalSize ?? 0 } ?? total(containers?.map(\.SizeRw)))
    remainder(
      "Volumes",
      volumeUsage.map { $0.TotalSize ?? 0 } ?? total(volumes?.map { $0.UsageData?.Size }),
      assigned: assignedVolumes)
    let buildBytes = total(report.BuildCache?.map { $0.Shared == true ? 0 : $0.Size })
    remainder(
      "Build Cache",
      report.BuildCacheUsage.map { $0.TotalSize ?? 0 } ?? buildBytes ?? report.BuilderSize)
    return rows
  }
}
