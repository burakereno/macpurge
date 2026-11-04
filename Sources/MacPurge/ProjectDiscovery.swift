import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// A chosen folder is a search scope. Partition it into disjoint measurement roots so
/// listing a project and its outputs never adds the same subtree to inventory twice.
struct ProjectDiscovery: Sendable {
  var projects: [URL] = []
  var roots: [ScanRoot] = []
  var incomplete = false

  private static let manifests: Set<String> = [
    "package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py",
    "requirements.txt", "Podfile", "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
    "settings.gradle", "settings.gradle.kts", "composer.json", "pubspec.yaml", "CMakeLists.txt",
  ]
  private static let skip: Set<String> = [
    "vendor", "venv", "dist", "build", "target", "__pycache__",
  ]
  private static let bundles: Set<String> = [
    "app", "framework", "bundle", "xcarchive", "xcodeproj", "xcworkspace", "playground",
  ]

  @concurrent static func discover(_ selected: [ScanRoot]) async throws -> Self {
    var found = Self()
    for scope in selected {
      var partitions: [String: ScanRoot] = [scope.url.path: scope]
      func add(_ url: URL, owner: URL?, parent: URL, file: Bool = false) {
        let relative = String(url.path.dropFirst(parent.path == "/" ? 1 : parent.path.count + 1))
        partitions[parent.path]?.excludedDirectories.insert(relative)
        var root = ScanRoot(
          group: .projects,
          title: owner.map {
            $0.lastPathComponent + "/" + String(url.path.dropFirst($0.path.count + 1))
          }
            ?? url.lastPathComponent, url: url,
          profile: owner == nil ? .project : ProjectOutput.profile(for: url, file: file),
          source: file ? .file : .directory)
        root.projectOwner = owner?.path
        root.expectedDevice = scope.expectedDevice
        partitions[url.path] = root
      }
      func buildContents(_ build: URL, owner: URL) throws {
        let children = try DirectoryIndex.childrenIfReadable(
          of: build, onDevice: scope.expectedDevice)
        guard let children else {
          found.incomplete = true
          return
        }
        for entry in children {
          add(entry.url, owner: owner, parent: build, file: !entry.directory)
          guard entry.directory,
            ["DerivedData", "ProductionDerivedData", "out", "control-xcode"].contains(
              entry.url.lastPathComponent)
          else { continue }
          let known = try DirectoryIndex.childrenIfReadable(of: entry.url, onDevice: entry.device)
          guard let known else {
            found.incomplete = true
            continue
          }
          for part in known where part.directory {
            if ProjectOutput.generatedFolders.contains(part.url.lastPathComponent) {
              add(part.url, owner: owner, parent: entry.url)
            } else if part.url.lastPathComponent == "Build" {
              let products = try DirectoryIndex.childrenIfReadable(
                of: part.url, onDevice: part.device)
              if products == nil { found.incomplete = true }
              for product in products ?? []
              where product.directory
                && ["Intermediates.noindex", "Products"].contains(product.url.lastPathComponent)
              {
                add(product.url, owner: owner, parent: entry.url)
              }
            }
          }
        }
      }

      func visit(_ url: URL, project: URL?, depth: Int) throws {
        try Task.checkCancellation()
        guard depth < 160 else {
          found.incomplete = true
          return
        }
        let entries: [DirectoryIndex.Entry]
        do {
          entries = try DirectoryIndex.children(of: url, onDevice: scope.expectedDevice)
        } catch is DirectoryIndex.Problem {
          found.incomplete = true
          return
        }
        let files = Set(entries.filter { !$0.directory }.map { $0.url.lastPathComponent })
        let dirs = entries.filter(\.directory)
        var owner = project
        if owner == nil
          && (!files.isDisjoint(with: manifests) || files.contains(".git")
            || dirs.contains(where: {
              $0.url.lastPathComponent == ".git"
                || ["xcodeproj", "xcworkspace"].contains($0.url.pathExtension)
            }))
        {
          owner = url
          found.projects.append(url)
          if url.path != scope.url.path { add(url, owner: nil, parent: scope.url) }
        }
        for entry in dirs {
          let child = entry.url
          let name = child.lastPathComponent
          if let owner, name == ".next", files.contains("package.json") {
            // The cache can be discarded without also taking the compiled app.
            let parts = try DirectoryIndex.childrenIfReadable(of: child, onDevice: entry.device)
            let outputs =
              parts?.filter {
                $0.directory && ProjectOutput.nextParts.contains($0.url.lastPathComponent)
              } ?? []
            if parts == nil { found.incomplete = true }
            add(child, owner: owner, parent: owner)
            for output in outputs { add(output.url, owner: owner, parent: child) }
          } else if let owner,
            StorageMeter.outputFolders.contains(name) || ProjectOutput.matches(name, files: files)
          {
            add(child, owner: owner, parent: owner)
            if name == ".build" { try buildContents(child, owner: owner) }
          } else if !name.hasPrefix("."), !StorageMeter.outputFolders.contains(name),
            !skip.contains(name), !bundles.contains(child.pathExtension)
          {
            try visit(child, project: owner, depth: depth + 1)
          }
        }
      }
      try visit(scope.url, project: nil, depth: 0)
      found.roots += partitions.values.sorted { $0.url.path < $1.url.path }
    }
    return found
  }
}

enum ProjectOutput {
  // Match the generating tool beside the output; a coincidentally named directory is insufficient.
  static let markers: [String: Set<String>] = {
    var rules: [String: Set<String>] = [
      ".build": ["Package.swift"], "Pods": ["Podfile"], "target": ["Cargo.toml", "pom.xml"],
      "build": ["build.gradle", "build.gradle.kts"],
      ".gradle": ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
      ".dart_tool": ["pubspec.yaml"],
    ]
    for name in [
      "node_modules", ".next", ".nuxt", ".svelte-kit", ".astro", ".angular",
      ".turbo", ".parcel-cache", ".expo",
    ] {
      rules[name] = ["package.json"]
    }
    for name in ["__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache"] {
      rules[name] = ["pyproject.toml", "setup.py", "requirements.txt"]
    }
    return rules
  }()

  static func matches(_ name: String, files: Set<String>) -> Bool {
    markers[name].map { !$0.isDisjoint(with: files) } == true
  }

  static let nextParts: Set<String> = [
    "cache", "server", "static", "dev", "types", "build", "diagnostics",
  ]

  static let generatedFolders: Set<String> = [
    "ModuleCache.noindex", "SDKStatCaches.noindex", "SDKExplicitPrecompiledModules",
    "Index.noindex", "Intermediates.noindex", "Products",
  ]

  static func buildContainer(for url: URL) -> URL? {
    var current = url
    while current.path != "/" {
      if current.lastPathComponent == ".build" { return current }
      current.deleteLastPathComponent()
    }
    return nil
  }

  static func definition(for url: URL) -> (parent: URL, names: Set<String>)? {
    let parent = url.deletingLastPathComponent()
    if let build = buildContainer(for: url), build.path != url.path {
      return (build.deletingLastPathComponent(), ["Package.swift"])
    }
    if parent.lastPathComponent == ".next", nextParts.contains(url.lastPathComponent) {
      return (parent.deletingLastPathComponent(), ["package.json"])
    }
    return markers[url.lastPathComponent].map { (parent, $0) }
  }

  static func stillMatches(_ url: URL) -> Bool {
    guard let (parent, names) = definition(for: url) else { return false }
    return
      (try? TrashFiles.directory(parent, enumerate: false) { fd, _ in
        names.contains { name in
          var info = stat()
          return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & S_IFMT == S_IFREG
        }
      }) == true
  }

  static func profile(for url: URL, file: Bool = false) -> StorageProfile {
    guard !file, stillMatches(url) else { return .projectOutput }
    if url.lastPathComponent == ".gradle" { return .projectGradleCache }
    switch ProjectOutputKind.classify(url.path) {
    case .cache: return .projectCache
    case .build: return .projectBuild
    default: return .projectOutput
    }
  }

  static func effect(_ url: URL) -> String {
    if url.lastPathComponent == ".gradle" {
      return StorageProfile.gradleCacheReason
    }
    switch ProjectOutputKind.classify(url.path) {
    case .cache:
      return "Önbellek yeniden oluşur. İlk açılış veya derleme daha uzun sürebilir."
    case .build:
      return "Sonraki derlemede yeniden oluşur. Çalıştırmak için yeniden derlemen gerekir."
    case .dependencies:
      return
        "Bağımlılıkları yeniden kurman gerekir. Paketlerde yaptığın yerel değişiklikler kaybolabilir."
    case .backup:
      return
        "Silinirse eski sürüm ve yedek kopyalarını kaybedersin. Sonraki derleme bunları geri getirmez."
    case .archive:
      return
        "Silinirse dağıtım paketlerini, sürüm arşivlerini ve varsa hata ayıklama simgelerini kaybedersin."
    case .products:
      return
        "Uygulama yeniden derlenebilir. Ancak eski derlemelerin hata ayıklama simgelerini kaybedebilirsin."
    case .diagnostics:
      return
        "Silinirse geçmiş test ve performans kayıtlarını kaybedersin. Eski kayıtlar yeniden oluşmaz."
    case .mixed:
      return "Bu özel dosyaların otomatik yeniden oluşturulacağı bilinmiyor. Alt içeriği incele."
    }
  }

}

/// User-facing consequences, independent of the conservative move confirmation.
enum ProjectOutputKind {
  case cache, build, dependencies, backup, archive, products, diagnostics, mixed

  static func classify(_ path: String) -> Self {
    let url = URL(fileURLWithPath: path)
    if ["node_modules", "Pods", ".dart_tool"].contains(url.lastPathComponent) {
      return .dependencies
    }
    let name = url.lastPathComponent
    if let build = ProjectOutput.buildContainer(for: url), build.path != url.path {
      let relative = String(url.path.dropFirst(build.path.count + 1)).lowercased()
      if relative.contains("backup") { return .backup }
      if ["xcarchive", "dmg", "pkg", "zip", "app"].contains(url.pathExtension)
        || name == "releases"
      {
        return .archive
      }
      if url.pathExtension == "trace" || url.pathExtension == "log" || name == "Logs" {
        return .diagnostics
      }
      if ["checkouts", "repositories", "artifacts"].contains(name) { return .dependencies }
      if name == "Products" || name.hasPrefix("arm64-apple-") || name.hasPrefix("x86_64-apple-") {
        return .products
      }
      if name == "Intermediates.noindex" || name == "SDKExplicitPrecompiledModules" {
        return .build
      }
      if ProjectOutput.generatedFolders.contains(name) { return .cache }
    }
    if name == ".build" { return .mixed }
    if url.deletingLastPathComponent().lastPathComponent == ".next" {
      return url.lastPathComponent == "cache" ? .cache : .build
    }
    if ["build", "target"].contains(url.lastPathComponent) { return .build }
    if [
      ".gradle", ".turbo", ".parcel-cache", "__pycache__", ".pytest_cache",
      ".mypy_cache", ".ruff_cache", ".astro", ".angular", ".expo",
    ].contains(url.lastPathComponent) {
      return .cache
    }
    return .mixed
  }

}

struct ProjectFolderRow: Identifiable {
  struct Output: Identifiable {
    let path: String
    let title: String
    let bytes: Int64?
    let countedBytes: Int64
    let effect: String
    let item: ReportItem?
    let candidateBytes: Int64
    let reclaimableBytes: Int64
    var id: String { path }
    var isReproducible: Bool {
      item?.safety == SafetyLevel.safe.rawValue
    }
  }
  let url: URL
  var id: String { url.path }
  var label: String = ""
  var bytes: Int64?
  var partial = false
  var approximate = false
  var sourceModified: Date?
  var localOutputBytes: Int64 = 0
  var candidateBytes: Int64 { outputs.reduce(0) { $0 + $1.candidateBytes } }
  var reclaimableBytes: Int64 { outputs.reduce(0) { $0 + $1.reclaimableBytes } }
  var reproducibleBytes: Int64 {
    outputs.filter(\.isReproducible).reduce(0) { $0 + $1.reclaimableBytes }
  }

  struct OutputGroup: Identifiable {
    let path: String
    let title: String
    var outputs: [Output]
    var id: String { path }
    var isBuildFolder: Bool { URL(fileURLWithPath: path).lastPathComponent == ".build" }
    var bytes: Int64 { outputs.reduce(0) { $0 + $1.countedBytes } }
    var reproducibleBytes: Int64 {
      outputs.filter(\.isReproducible).reduce(0) { $0 + $1.reclaimableBytes }
    }
  }

  var outputGroups: [OutputGroup] {
    let grouped = Dictionary(grouping: outputs) { output in
      ProjectOutput.buildContainer(for: URL(fileURLWithPath: output.path))?.path ?? output.path
    }
    return grouped.map { path, outputs in
      OutputGroup(
        path: path,
        title: ProjectOutput.buildContainer(for: URL(fileURLWithPath: path)) == nil
          ? outputs.first?.title ?? path : String(path.dropFirst(url.path.count + 1)),
        outputs: outputs.sorted {
          let a = $0.bytes ?? -1
          let b = $1.bytes ?? -1
          return a == b ? $0.id < $1.id : a > b
        })
    }.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
  }
  var outputs: [Output] = []
  var artifacts: [ProjectArtifact] = []
}

extension LiveScan {
  var projectCards: [ProjectFolderRow] {
    let urls = projectDiscovery.projects
    guard !urls.isEmpty else { return [] }
    var cards = Dictionary(uniqueKeysWithValues: urls.map { ($0.path, ProjectFolderRow(url: $0)) })
    let items = phase == .finished ? (report?.items ?? []) : []
    let projectItems = items.filter {
      $0.category == ScanGroup.projects.rawValue || $0.workspace != nil
    }
    let movable = Set(distinctMoves(projectItems.filter { !hiddenIDs.contains($0.id) }).map(\.id))
    let byPath = Dictionary(
      projectItems.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    for root in roots {
      let local = root.group == .projects
      let owner: String?
      if local {
        owner = root.projectOwner ?? root.url.path
      } else if let workspace = root.workspace, root.profile == .xcodeIntermediate {
        owner = ProjectAttribution.owningRoot(workspace: workspace, selected: urls)?.path
      } else {
        continue
      }
      guard let owner, cards[owner] != nil else { continue }
      let size = results[root.id]
      if size?.state == .absent { continue }
      let bytes = size.flatMap { $0.measured ? $0.bytes : nil }
      if local {
        if let bytes {
          let previous = cards[owner]?.bytes ?? 0
          cards[owner]?.bytes = previous + bytes - (size?.projectOverlapBytes ?? 0)
        }
        if size?.approximateProjectSize == true { cards[owner]?.approximate = true }
        if size?.state != .complete { cards[owner]?.partial = true }
      }
      if root.profile == .project {
        cards[owner]?.sourceModified = size?.sourceModified
        continue
      }
      if !root.excludedDirectories.isEmpty && bytes == 0 { continue }
      let item = byPath[root.url.path]
      let title =
        local
        ? String(root.url.path.dropFirst(owner.count + 1))
        : "DerivedData/" + root.url.pathComponents.suffix(3).joined(separator: "/")
      let effect =
        local
        ? ProjectOutput.effect(root.url)
        : (item?.reason ?? "Proje dışındaki DerivedData")
      let candidate = item.flatMap { movable.contains($0.id) ? action(for: $0).bytes : nil } ?? 0
      cards[owner]?.outputs.append(
        .init(
          path: root.url.path,
          title: root.excludedDirectories.isEmpty
            ? title : ReviewLanguage.format("%@ · diğer dosyalar", title), bytes: bytes,
          countedBytes: max(0, (bytes ?? 0) - (size?.projectOverlapBytes ?? 0)),
          effect: item.map { actionDescription($0) } ?? effect, item: item,

          candidateBytes: candidate,
          reclaimableBytes: candidate))
      if local { cards[owner]?.localOutputBytes += bytes ?? 0 }
    }
    for artifact in projectArtifacts { cards[artifact.project.path]?.artifacts.append(artifact) }
    let names = Dictionary(grouping: urls, by: \.lastPathComponent)
    return cards.values.map { card in
      var card = card
      card.label = card.url.lastPathComponent
      if (names[card.label]?.count ?? 0) > 1 {
        let scope = ProjectAttribution.owningRoot(workspace: card.id, selected: projects)
        // Include the scope name too when searching across multiple selected folders.
        let base = projects.count == 1 ? scope : scope?.deletingLastPathComponent()
        if let base, card.id.hasPrefix(base.path + "/") {
          card.label = String(card.id.dropFirst(base.path.count + 1))
        } else {
          card.label = (card.id as NSString).abbreviatingWithTildeInPath
        }
      }
      card.outputs.sort {
        (-$0.reclaimableBytes, -($0.bytes ?? 0), $0.path) < (
          -$1.reclaimableBytes, -($1.bytes ?? 0), $1.path
        )
      }
      return card
    }.sorted {
      if phase == .finished {
        return (-$0.reclaimableBytes, -$0.candidateBytes, $0.id) < (
          -$1.reclaimableBytes, -$1.candidateBytes, $1.id
        )
      }
      return $0.id < $1.id
    }
  }
}
