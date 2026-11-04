import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// Issued only for an exact physical item in this session's filesystem inventory.
struct ManualReview: Codable, Sendable {
  var parentItemID: String? = nil
  var workspace: String? = nil
  var projectOwner: String? = nil
  let scope: String?
  let title: String
  let profile: StorageProfile
  let category: String
  let path: String
  let device: dev_t
  let inode: ino_t
  let file: Bool
  let warning: String

  @concurrent static func candidates(
    roots: [ScanRoot], results: [String: RootSize], rows: [ReportItem],
    home: URL, projects: [URL], scope: String? = nil
  ) async -> (moves: [String: Self], blocked: [String: String]) {
    let protection = ProjectAttribution.ProtectedProjects(projects)
    let homeDevice = try? TrashFiles.directory(home, enumerate: false) { _, info in info.st_dev }
    let byRoot = Dictionary(
      grouping: rows.filter { $0.complete && $0.safety != nil },
      by: { $0.category + "|" + $0.path })
    var found: [String: Self] = [:]
    let packageBoundaries = ScanRoot.catalog(home: home, projects: []).filter {
      $0.group == .packages && $0.profile.assessment(for: .complete)?.level == .safe
    }.map(\.url.path)
    var blocked: [String: String] = [:]
    for root in roots where root.source == .directory || root.source == .file {
      guard root.profile != .systemManaged, root.downloadCache == nil, root.device == nil,
        root.excludedDirectories.isEmpty,
        let size = results[root.id], size.state == .complete,
        let inode = size.measuredInode, let volume = size.measuredDevice,
        let rows = byRoot[root.id], rows.count == 1, let row = rows.first,
        row.safety == SafetyLevel.review.rawValue,
        row.directoryInode == inode, row.volume == volume, row.basis == "allocated",
        let bytes = row.bytes, bytes > 0
      else { continue }
      guard volume == homeDevice, !protection.containsProject(under: root.url) else { continue }
      if packageBoundaries.contains(where: {
        row.path == $0 || row.path.hasPrefix($0 + "/") || $0.hasPrefix(row.path + "/")
      }) {
        blocked[row.id] = "Bu alanı paket yöneticisinin önbellek satırından temizleyebilirsin."
        continue
      }
      if root.profile == .projectOutput {
        guard let owner = root.projectOwner, projects.contains(where: { $0.path == owner }),
          root.url.path.hasPrefix(owner + "/"), ProjectOutput.stillMatches(root.url) else {
          blocked[row.id] = "Klasörün hangi araç tarafından oluşturulduğu doğrulanamadı."
          continue
        }
      }
      let candidate = Self(
        projectOwner: root.projectOwner, scope: scope, title: root.title, profile: root.profile, category: root.group.rawValue,
        path: root.url.path, device: volume,
        inode: inode, file: root.source == .file, warning: risk(for: root))
      guard candidate.permits(root.url, home: home) else { continue }
      found[row.id] = candidate
    }
    let splitRoots = Set(roots.filter { !$0.excludedDirectories.isEmpty }.map(\.id))
    let downloads = Set(roots.filter { $0.downloadCache != nil }.map(\.url.path))
    let allocations = Set(roots.compactMap { root -> String? in
      if case .allocation = root.source { return ScanReport.itemID(root) }
      return nil
    })
    for row in rows where found[row.id] == nil && blocked[row.id] == nil
      && (row.safety == SafetyLevel.review.rawValue ||
        (row.safety == SafetyLevel.safe.rawValue && !row.safePlanCandidate)) {
      let group = ScanGroup(rawValue: row.category)
      let outsideHome = !row.path.hasPrefix(home.path + "/")
      let reason: String
      if !row.complete {
        reason = row.reason
      } else if downloads.contains(row.path) {
        reason = row.reason
      } else if row.bytes == 0 {
        reason = "Taşımaya uygun alan yok"
      } else if group == .logs && outsideHome {
        reason = "Bu günlükleri macOS yönetir. MacPurge yalnızca kullanıcı klasöründeki günlükleri Çöp’e taşıyabilir."
      } else if group == .simulators && !outsideHome {
        reason = "Bu boyut, simülatördeki uygulamalar, belgeler ve ayarların toplamıdır. Bunlar tek bir klasör olarak Çöp’e taşınamaz."
      } else if group == .trash {
        reason = "Bu öğe zaten Çöp’te."
      } else if splitRoots.contains(row.category + "|" + row.path) {
        reason = "Bu satır bir toplam gösteriyor. Klasörün tamamını taşımak ölçülen kapsamı aşar."
      } else if group == .projects && ProjectOutput.definition(for: URL(fileURLWithPath: row.path)) != nil
        && !protection.containsProject(under: URL(fileURLWithPath: row.path)) {
        reason = outsideHome ? "Bu konum kullanıcı klasörünün dışında. MacPurge burada yalnızca ölçüm yapar."
          : "Bu konum Çöp’e taşınamaz."
      } else if group == .projects || protection.containsProject(under: URL(fileURLWithPath: row.path)) {
        reason = "Seçili proje klasörünü içeriyor."
      } else if group == .runtimes || group == .snapshots || group == .docker || group == .system {
        reason = "Bu konumu macOS veya sahibi olan araç yönetir. Alanı ilgili aracın ayarlarından incele."
      } else if row.estimated || allocations.contains(row.id) {
        reason = "Bu satır bir toplam gösteriyor. Klasörün tamamını taşımak ölçülen kapsamı aşar."
      } else if outsideHome {
        reason = "Bu konum kullanıcı klasörünün dışında. MacPurge burada yalnızca ölçüm yapar."
      } else if let volume = row.volume, let homeDevice, volume != homeDevice {
        reason = "Çöp bu diskte kullanılamıyor."
      } else {
        reason = "Bu öğe bağımsız taşınabilir bir kullanıcı konumu değil."
      }
      blocked[row.id] = reason
    }
    return (found, blocked)
  }

  static func generatedProject(_ row: ReportItem, path: URL, projects: [URL]) throws -> Self {
    let profile = ProjectOutput.profile(for: path)
    guard profile.assessment(for: .complete)?.level == .safe,
      let owner = ProjectAttribution.owningRoot(workspace: path.path, selected: projects)
    else { throw CleanupFailure("Proje derleme çıktısı doğrulanamadı.") }
    return try TrashFiles.directory(path, enumerate: false) { _, info in
      Self(projectOwner: owner.path, scope: nil, title: row.name, profile: profile,
        category: ScanGroup.projects.rawValue, path: path.path, device: info.st_dev,
        inode: info.st_ino, file: false, warning: ProjectOutput.effect(path))
    }
  }

  static func gradleCache(_ row: ReportItem, path: URL, home: URL) throws -> Self {
    guard path.path == home.appending(path: ".gradle/caches").path else {
      throw CleanupFailure("Gradle önbelleği doğrulanamadı.")
    }
    return try TrashFiles.directory(path, enumerate: false) { _, info in
      Self(scope: nil, title: row.name, profile: .gradleCache, category: ScanGroup.packages.rawValue,
        path: path.path, device: info.st_dev, inode: info.st_ino, file: false,
        warning: StorageProfile.gradleCacheReason)
    }
  }

  func permits(_ url: URL, home: URL) -> Bool {
    guard url.isFileURL, path == url.path, path.hasPrefix(home.path + "/"),
      let group = ScanGroup(rawValue: category),
      ![.system, .snapshots, .trash, .docker, .simulators, .runtimes].contains(group)
    else { return false }
    if profile == .gradleCache {
      return group == .packages && !file && path == home.appending(path: ".gradle/caches").path
    }
    let parts = path.dropFirst(home.path.count + 1).components(separatedBy: "/")
    guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
    if group == .projects {
      guard profile.isProjectOutput, (!file || ProjectOutput.buildContainer(for: url) != nil), let projectOwner, path.hasPrefix(projectOwner + "/"),
        ProjectOutput.definition(for: url) != nil else { return false }
      if profile == .projectCache && ProjectOutputKind.classify(path) != .cache { return false }
      if profile == .projectBuild && ProjectOutputKind.classify(path) != .build { return false }
      if profile == .projectGradleCache && url.lastPathComponent != ".gradle" { return false }
    }
    let relative = parts.joined(separator: "/").lowercased()
    // Never turn a broad container, our own state, or the Trash into a manual target.
    let protected = [
      ".trash", "library/application support/macpurge", "library/mobile documents",
      "library/cloudstorage", "library/application support/com.apple.tcc",
    ]
    return !protected.contains {
      relative == $0 || relative.hasPrefix($0 + "/") || $0.hasPrefix(relative + "/")
    }
  }

  var requiresAcknowledgement: Bool {
    profile.assessment(for: .complete)?.level != .safe
  }

  func inCurrentProjects(_ projects: [URL]) -> Bool {
    guard profile.isProjectOutput else { return true }
    let url = URL(fileURLWithPath: path)
    return projects.contains { $0.path == projectOwner } && ProjectOutput.stillMatches(url)
      && (profile == .projectOutput || ProjectOutput.profile(for: url) == profile)
  }

  func matchesCurrentItem(at url: URL) -> Bool {
    (try? TrashFiles.directory(url.deletingLastPathComponent(), enumerate: false) { parent, _ in
      var info = stat()
      return fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0
        && info.st_dev == device && info.st_ino == inode && info.st_uid == getuid()
        && info.st_mode & S_IFMT == (file ? S_IFREG : S_IFDIR)
    }) == true
  }

  private static func risk(for root: ScanRoot) -> String {
    if root.profile == .projectOutput { return ProjectOutput.effect(root.url) }
    if root.group == .xcode {
      if root.url.lastPathComponent == "Archives" || root.url.pathExtension == "xcarchive" {
        return
          "Arşivler ve hata ayıklama simgeleri kaldırılır. Eski sürümleri yeniden dışa aktaramayabilirsin."
      }
      if root.profile == .xcodeWorkspace {
        return
          "Derleme çıktılarıyla birlikte test sonuçları, günlükler ve paket çalışma kopyaları da taşınır."
      }
      return "Bu Xcode verisini kullanan araçlar yeniden indirme veya derleme gerektirebilir."
    }
    if root.url.pathExtension == "avd" {
      return "Bu emülatörün yüklü uygulamaları ve yerel verileri kullanılamaz hale gelir."
    }
    switch root.group {
    case .android, .packages, .tools:
      return "Bu konumu kullanan araçlar ve projeler çalışmayabilir. Yeniden kurulum gerekebilir."
    case .backups: return "Bu yedek geri yükleme için kullanılamaz hale gelir."
    case .machines: return "Sanal makinenin diski ve içindeki dosyalar kullanılamaz hale gelir."
    default:
      return
        "Bu öğe kişisel dosyalar veya uygulama verileri içerebilir. Çöp boşaltılırsa bunları geri alamazsın."
    }
  }
}
