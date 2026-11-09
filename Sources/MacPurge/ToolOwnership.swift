import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum DevelopmentCache: Hashable, Sendable {
  case npx
  case compiler(String)
  case orphanIntermediates
  case expo(String)

  static let xcodeLeaves = [
    "ModuleCache.noindex", "SDKExplicitPrecompiledModules", "SDKStatCaches.noindex",
    "CompilationCache.noindex", "Index.noindex",
  ]

  static func npxKey(_ name: String) -> Bool {
    name.utf8.count == 16 && isHex(name)
  }

  private static func isHex(_ value: String) -> Bool {
    value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func at(_ url: URL, home: URL) -> Self? {
    let npx = home.appending(path: ScanRoot.npxCachePath)
    let leaf = url.lastPathComponent
    let parent = url.deletingLastPathComponent()
    if parent.path == npx.path && npxKey(leaf) { return .npx }
    if parent.path == home.appending(path: ".expo").path, ScanRoot.expoCacheLeaves.contains(leaf) {
      return .expo(leaf)
    }
    if url.path == ExtendedInventory.clangModuleCache(home: home)?.url.path {
      return .compiler("ModuleCache")
    }
    let derived = home.appending(path: "Library/Developer/Xcode/DerivedData").path
    if xcodeLeaves.contains(leaf),
      parent.path == derived || parent.deletingLastPathComponent().path == derived
    { return .compiler(leaf) }
    return nil
  }

  @concurrent static func npxRoots(in home: URL, onDevice device: dev_t?) async throws -> [ScanRoot] {
    let base = home.appending(path: ScanRoot.npxCachePath)
    return (try DirectoryIndex.childrenIfReadable(of: base, onDevice: device) ?? []).compactMap {
      guard $0.directory, npxKey($0.url.lastPathComponent) else { return nil }
      let names = npmDependencies(at: $0.url)?.keys.sorted().joined(separator: ", ")
      return .init(group: .packages, title: "npx · " + (names ?? $0.url.lastPathComponent),
        url: $0.url, profile: .npxEntry)
    }
  }

  static func npmDependencies(at root: URL) -> [String: String]? {
    json(root.appending(path: "package.json"))?["dependencies"] as? [String: String]
  }

  private static func json(_ path: URL, limit: Int = 512 * 1024) -> [String: Any]? {
    guard let data = SmallMetadata.read(path, limit: limit) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  func validate(_ root: URL, date: Date = .now) throws {
    switch self {
    case .npx:
      guard let deps = Self.npmDependencies(at: root), !deps.isEmpty,
        deps.values.allSatisfy({ $0.range(of: #"^(?:file:|link:|git|https?:|workspace:|\.|/)"#,
          options: .regularExpression) == nil })
      else { throw CleanupFailure("The npx entry could not be verified as a registry install.") }
      let manifest = root.appending(path: "package.json")
      let modules = root.appending(path: "node_modules")
      let lockfiles = [root.appending(path: "package-lock.json"), modules.appending(path: ".package-lock.json")]
      let present = lockfiles.filter { FileManager.default.fileExists(atPath: $0.path) }
      let cutoff = date.addingTimeInterval(-30 * 24 * 60 * 60)
      guard ([root, manifest, modules] + present).allSatisfy({
        guard let values = try? $0.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
          let modified = values.contentModificationDate
        else { return false }
        return values.isSymbolicLink == false && modified <= cutoff
      }) else { throw CleanupFailure("This npx entry is recent or its age could not be verified.") }
      guard !present.isEmpty, present.allSatisfy({
        guard let entries = Self.json($0, limit: 4 * 1024 * 1024)?["packages"] as? [String: [String: Any]],
          entries.count > 1 || entries.keys.contains(where: { $0.hasPrefix("node_modules/") })
        else { return false }
        return entries.allSatisfy { key, value in
          guard value["link"] as? Bool != true else { return false }
          if key.isEmpty { return true }
          guard key.hasPrefix("node_modules/"), let resolved = value["resolved"] as? String,
            let url = URL(string: resolved)
          else { return value["inBundle"] as? Bool == true }
          return url.scheme == "https" && url.host == "registry.npmjs.org"
        }
      }) else { throw CleanupFailure("The npx entry could not be verified as a registry install.") }
    case .expo(let leaf):
      let entries = try DirectoryIndex.children(of: root, rejectUnsupported: true)
      guard !entries.isEmpty else { return }
      switch leaf {
      case "android-apk-cache":
        for entry in entries {
          guard accepts([entry.url.lastPathComponent], directory: entry.directory, link: false),
            try Self.hasZipHeader(entry.url)
          else { throw CleanupFailure("Unrecognized Expo download cache contents.") }
        }
      case "ios-simulator-app-cache":
        for entry in entries {
          guard accepts([entry.url.lastPathComponent], directory: entry.directory, link: false),
            let data = SmallMetadata.read(entry.url.appending(path: "Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            plist["CFBundleIdentifier"] as? String == "host.exp.Exponent"
          else { throw CleanupFailure("Unrecognized Expo download cache contents.") }
        }
      default:
        let names = Set(entries.map { $0.url.lastPathComponent })
        for entry in entries {
          let name = entry.url.lastPathComponent
          guard accepts([name], directory: entry.directory, link: false) else {
            throw CleanupFailure("Unrecognized Expo download cache contents.")
          }
          let key = String(name.prefix(64))
          guard names.contains(key + "-body.bin"),
            let metadata = Self.json(root.appending(path: key + "-info.json")),
            let status = metadata["status"] as? Int, (200..<300).contains(status),
            metadata["headers"] is [String: Any], metadata["expiration"] is NSNumber,
            let source = metadata["url"] as? String,
            (leaf == "expo-go" && source.isEmpty) ||
              (URL(string: source)?.scheme == "https" && URL(string: source)?.host == "api.expo.dev"),
            let body = metadata["bodyPath"] as? String, URL(fileURLWithPath: body).lastPathComponent == key + "-body.bin"
          else { throw CleanupFailure("Unrecognized Expo download cache contents.") }
        }
      }
    case .compiler: break
    case .orphanIntermediates: try XcodeOrphanBuild.validateRoot(root)
    }
  }

  private static func hasZipHeader(_ url: URL) throws -> Bool {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var header = [UInt8](repeating: 0, count: 4)
    return read(fd, &header, header.count) == 4 && header == [0x50, 0x4b, 0x03, 0x04]
  }

  func accepts(_ parts: [String], directory: Bool, link: Bool) -> Bool {
    guard let first = parts.first, let name = parts.last else { return false }
    switch self {
    case .npx:
      if link { return first == "node_modules" && parts.dropLast().contains(".bin") }
      if parts.count == 1 {
        return directory ? name == "node_modules" : ["package.json", "package-lock.json"].contains(name)
      }
      return first == "node_modules"
    case .expo(let leaf):
      guard !link else { return false }
      switch leaf {
      case "android-apk-cache":
        return parts.count == 1 && !directory && name.range(
          of: #"^Expo-Go-[0-9][0-9.]*\.apk$"#, options: .regularExpression) != nil
      case "ios-simulator-app-cache":
        return (parts.count > 1 || directory) && first.range(
          of: #"^Expo-Go-[0-9][0-9.]*\.tar\.app$"#, options: .regularExpression) != nil
      default:
        return parts.count == 1 && !directory && name.range(
          of: #"^[0-9a-f]{64}-(info\.json|body\.bin)$"#, options: .regularExpression) != nil
      }
    case .orphanIntermediates:
      return !link && XcodeOrphanBuild.accepts(parts, directory: directory)
    case .compiler(let leaf):
      guard !link else { return false }
      switch leaf {
      case "SDKStatCaches.noindex": return !directory && parts.count == 1 && name.hasSuffix(".sdkstatcache")
      case "CompilationCache.noindex":
        if directory { return parts == ["generic"] || parts == ["generic", "v1.1"] }
        return parts == ["generic", "lock"] || (parts.count == 3 && first == "generic"
          && parts[1] == "v1.1" && ["data", "index", "pool"].contains(name.components(separatedBy: ".").first ?? "")
          && (name.hasSuffix(".v1") || name.hasSuffix(".v1.shared")))
      case "Index.noindex":
        guard first == "DataStore", parts.count < 2 || parts[1] == "v5" else { return false }
        if parts.count < 3 { return directory }
        if parts.count == 3 { return directory && ["records", "units"].contains(name) }
        if parts[2] == "units" { return parts.count == 4 && !directory && name.hasSuffix(".unit") }
        guard parts[2] == "records", parts[3].utf8.count == 2,
          parts[3].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
        else { return false }
        return parts.count == 4 ? directory : parts.count == 5 && !directory
      default:
        if directory { return parts.count == 1 && name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } }
        return name.hasSuffix(".pcm") || name.hasSuffix(".swiftmodule")
          || ["modules.timestamp", "modules.idx", "Session.modulevalidation"].contains(name)
      }
    }
  }

  func validateEntry(_ parts: [String], in fd: Int32, info: stat) throws {
    guard let name = parts.last else { return }
    if self == .npx, info.st_mode & S_IFMT == S_IFLNK {
      var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
      let count = bytes.withUnsafeMutableBytes { readlinkat(fd, name, $0.baseAddress!, $0.count) }
      guard count > 0, count < bytes.count, let destination = String(bytes: bytes.prefix(count), encoding: .utf8),
        !destination.hasPrefix("/")
      else { throw CleanupFailure("Unrecognized link in this npx cache entry.") }
      var depth = parts.count - 1
      for component in destination.split(separator: "/") where component != "." {
        depth += component == ".." ? -1 : 1
        guard depth >= 1 else { throw CleanupFailure("Unrecognized link in this npx cache entry.") }
      }
    }
    guard case .compiler = self, info.st_mode & S_IFMT == S_IFREG else { return }
    let headers: [[UInt8]]
    switch URL(filePath: name).pathExtension {
    case "pcm": headers = [[0x43, 0x50, 0x43, 0x48], [0xcf, 0xfa, 0xed, 0xfe]]
    case "swiftmodule": headers = [[0xe2, 0x9c, 0xa8, 0x0e], [0x2d, 0x2d, 0x2d, 0x0a]]
    case "sdkstatcache": headers = [[0x53, 0x54, 0x41, 0x54]]
    case "idx": headers = [[0x42, 0x43, 0x47, 0x49]]
    case "v1": headers = [[0x53, 0xba, 0x7a, 0xda]]
    default: return
    }
    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { throw TrashFiles.posix() }
    defer { close(file) }
    var opened = stat()
    var header = [UInt8](repeating: 0, count: 4)
    guard fstat(file, &opened) == 0, FileIdentity(opened) == FileIdentity(info),
      read(file, &header, header.count) == header.count, headers.contains(header)
    else { throw CleanupFailure("Unrecognized compiler cache file format.") }
  }
}

struct DevelopmentCacheUse: Sendable {
  private struct ProcessEntry: Sendable {
    let parent: Int
    let command: String
  }

  private let processes: [Int: ProcessEntry]
  private let processReferences: [Int: ProcessEntry]
  private let files: [Int: [String]]
  private let activeNpx: Set<String>
  private let unresolvedNpm: Bool

  init(
    processList: String, openFiles: String, environmentList: String? = nil, user: uid_t = getuid(),
    npxRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ScanRoot.npxCachePath)
  ) throws {
    let processes = try Self.parse(processList, user: user)
    let references = try environmentList.map { try Self.parse($0, user: user) } ?? processes
    var files: [Int: [String]] = [:]
    var pid: Int?
    for line in openFiles.split(separator: "\n") {
      if line.hasPrefix("p") { pid = Int(line.dropFirst()) }
      if line.hasPrefix("n/"), let pid { files[pid, default: []].append(String(line.dropFirst())) }
      if line.hasPrefix("lsof:") { throw CleanupFailure("Could not verify cache use by running processes.") }
    }
    guard !files.isEmpty else { throw CleanupFailure("Could not verify cache use by running processes.") }
    self.processes = processes
    processReferences = references
    self.files = files
    let prefix = npxRoot.path + "/"
    var users = Set<Int>()
    var keys = Set<String>()
    for (pid, process) in references {
      let referenced = Self.npxKeys(in: process.command, prefix: prefix)
      if !referenced.isEmpty { users.insert(pid); keys.formUnion(referenced) }
    }
    for (pid, paths) in files {
      for path in paths where path.hasPrefix(prefix) {
        let key = String(path.dropFirst(prefix.count).prefix(while: { $0 != "/" }))
        if DevelopmentCache.npxKey(key) { users.insert(pid); keys.insert(key) }
      }
    }
    activeNpx = keys
    // An npm exec wrapper may wait for a child that already has a resolved cache
    // entry. Unresolved exec, package mutations and other npm commands can write any entry.
    var resolvedWrappers = Set<Int>()
    for pid in users {
      var parent = processes[pid]?.parent
      while let id = parent, id > 1, resolvedWrappers.insert(id).inserted {
        parent = processes[id]?.parent
      }
    }
    unresolvedNpm = processes.contains { pid, process in
      guard let match = process.command.range(
        of: #"^(?:\S*/)?(?:npm|npx)(?:\s+|$)|^(?:\S*/)?node\s+(?:\S*/)?(?:npm|npx)-cli\.js(?:\s+|$)"#,
        options: .regularExpression)
      else { return false }
      let operation = process.command[match.upperBound...].split(whereSeparator: \.isWhitespace).first
      if operation == "run" || operation == "run-script" { return false }
      return operation != "exec" || !resolvedWrappers.contains(pid)
    }
  }

  private static func parse(_ listing: String, user: uid_t) throws -> [Int: ProcessEntry] {
    var processes: [Int: ProcessEntry] = [:]
    for line in listing.split(separator: "\n") {
      let columns = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
      guard columns.count == 4, let pid = Int(columns[0]), let parent = Int(columns[1]),
        let owner = uid_t(columns[2]) else {
        throw CleanupFailure("Could not verify cache use by running processes.")
      }
      if owner == user { processes[pid] = .init(parent: parent, command: String(columns[3])) }
    }
    guard !processes.isEmpty else { throw CleanupFailure("Could not verify cache use by running processes.") }
    return processes
  }

  @concurrent static func read() async throws -> Self {
    async let processes = InventoryCommand.output("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,args="])
    async let references = InventoryCommand.output("/bin/ps", ["axeww", "-o", "pid=,ppid=,uid=,command="])
    async let files = InventoryCommand.output("/usr/sbin/lsof",
      ["-nP", "-u", String(getuid()), "-F", "pn"], captureError: true)
    return try await Self(processList: String(decoding: processes, as: UTF8.self),
      openFiles: String(decoding: files, as: UTF8.self),
      environmentList: String(decoding: references, as: UTF8.self))
  }

  func verify(_ cache: DevelopmentCache, at url: URL, movedTo: URL? = nil) throws {
    if cache == .npx {
      if activeNpx.contains(url.lastPathComponent) {
        throw CleanupFailure("A running process is using this cache.", inUse: true)
      }
      if unresolvedNpm {
        throw CleanupFailure("An npm command may be preparing an npx cache entry.", inUse: true)
      }
    }
    let locations: [URL]
    switch cache {
    case .npx: locations = []
    case .orphanIntermediates: locations = [url.deletingLastPathComponent().deletingLastPathComponent()]
    default: locations = [url]
    }
    try verifyUnused(locations + (movedTo.map { [$0] } ?? []))

    switch cache {
    case .npx: break
    case .compiler, .orphanIntermediates:
      if processes.values.contains(where: { $0.command.range(
        of: #"(?:^|/)(?:Xcode|xcodebuild|XCBBuildService|swift|swiftc|swift-frontend|swift-build(?:-tool)?|swift-driver|clang(?:\+\+|-[0-9]+)?)(?:\s|$)"#,
        options: .regularExpression) != nil
      }) { throw CleanupFailure("A compiler is running. Wait for the build to finish.", inUse: true) }
      if cache == .orphanIntermediates, processes.values.contains(where: { $0.command.range(
        of: #"^(?:\S*/)?(?:XCBuildService|xcbuild|xctest|ibtool|actool|metal|ld)(?:\s|$)"#,
        options: .regularExpression) != nil
      }) { throw CleanupFailure("A compiler is running. Wait for the build to finish.", inUse: true) }
    case .expo:
      if processes.values.contains(where: { $0.command.range(
        of: #"(?:^|[ /])(?:expo(?:-cli|-go)?|eas(?:-cli)?)(?:\s|/bin/|$)|/node_modules/@expo/cli/"#,
        options: .regularExpression) != nil
      }) { throw CleanupFailure("Expo is running. Wait for its downloads to finish.", inUse: true) }
    }
  }

  func verifyUnused(_ locations: [URL]) throws {
    let aliases = locations.flatMap { location -> [String] in
      let path = location.path
      return path.hasPrefix("/private/var/") ? [path, String(path.dropFirst("/private".count))] : [path]
    }
    let referenced = aliases.contains { alias in
      processReferences.values.contains { process in
        process.command.contains(alias + "/") || process.command.contains(alias + " ")
          || process.command.hasSuffix(alias)
      } || files.values.joined().contains { $0 == alias || $0.hasPrefix(alias + "/") }
    }
    guard !referenced else { throw CleanupFailure("A running process is using this cache.", inUse: true) }
  }

  private static func npxKeys(in value: String, prefix: String) -> Set<String> {
    Set(value.components(separatedBy: prefix).dropFirst().compactMap { suffix in
      let key = String(suffix.prefix(16))
      guard DevelopmentCache.npxKey(key),
        suffix.utf8.count == 16 || suffix.dropFirst(16).first.map({ "/ :\t\"'".contains($0) }) == true
      else { return nil }
      return key
    })
  }
}

enum ModelInventory {
  /// A manifest references blobs by digest. Count a shared blob once in its
  /// own row, never once per model referencing it.
  @concurrent static func ollama(at root: URL, onDevice: dev_t? = nil) async throws -> [ScanRoot] {
    let graph = try OllamaLeftovers.inspect(root: root, onDevice: onDevice)
    guard graph.complete else { return [] }
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
    guard !failed else { return [] }
    var sizes = Dictionary(uniqueKeysWithValues: byModel.keys.map { ($0, Int64(0)) })
    var shared: Int64 = 0
    var unclaimed: Int64 = 0
    var owners: [String: [String]] = [:]
    for (model, digests) in byModel {
      for digest in digests { owners[digest, default: []].append(model) }
    }
    let blobs = root.appending(path: "blobs")
    let separate = Set(graph.leftovers.map { $0.url.path })
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
      } else if list.isEmpty && !separate.contains(url.path) {
        unclaimed += bytes
      } else if !list.isEmpty {
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
    for blob in graph.leftovers {
      var row = ScanRoot(group: .models, title: "Ollama · " + blob.url.lastPathComponent, url: blob.url,
        profile: .personal, source: .file)
      row.evidence = .init(owner: "Ollama", kind: .modelFragment, finding: blob.partial ? .partialModel : .orphanModel,
        rule: "ollama.leftover", inspectionOnly: !blob.old)
      row.evidence?.note = blob.old ? "Older than 72 hours; requires a fresh reference check and an idle Ollama process."
        : "Modified within the last 72 hours or hard-linked. Inspection only."
      rows.append(row)
    }
    if rows.isEmpty {
      var empty = ScanRoot(group: .models, title: "Ollama model deposu", url: root, profile: .personal, source: .allocation(0))
      empty.evidence = .init(owner: "Ollama", kind: .applicationData, rule: "ollama.empty")
      rows.append(empty)
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
