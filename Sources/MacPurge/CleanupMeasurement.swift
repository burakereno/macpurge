import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// Patch the last inventory using physical moves (both sides of each rename).
/// Only matching filesystem roots are opened. Sibling totals use their saved measurements.
struct CleanupMeasurement {
  var roots: [ScanRoot]
  var results: [String: RootSize]
  var categories: [ScanGroup: OverviewCategory] = [:]
  var groupBytes: [ScanGroup: Int64] = [:]
  var affectedGroups = Set<ScanGroup>()
  var removedIDs = Set<String>()
  var freshItems: [ReportItem] = []
  var report: ScanReport?
  var artifacts: [ProjectArtifact]

  /// Partition only trees which can enclose a supported cleanup target. The ordinary scan
  /// records small per-boundary summaries in one pass, including the rest of a project's dates.
  struct Boundaries {
    let patterns: [[String]]
    let caseInsensitive: Bool

    init(home: URL, trash: URL, devices: [ScanRoot], catalog: [ScanRoot]) {
      var paths = catalog.filter {
        $0.profile == .npxEntry || $0.profile.assessment(for: .complete)?.level == .safe
      }.map(
        \.url)
      paths.append(trash.appending(path: "{receipt}"))
      paths.append(
        home.appending(
          path: "Library/Developer/Xcode/DerivedData/*/" + ProjectAttribution.intermediates))
      for owner in RenderCacheOwner.all {
        for leaf in RenderCacheOwner.leaves {
          paths.append(
            home.appending(path: "Library/Application Support/" + owner.folder + "/" + leaf))
        }
      }
      for device in devices {
        for dir in ["data", "data/Containers/Data/Application/*"] {
          for leaf in ["tmp", "Library/Caches"] {
            paths.append(device.url.appending(path: dir + "/" + leaf))
          }
        }
      }
      let insensitive =
        (try? home.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
        .volumeSupportsCaseSensitiveNames == false
      caseInsensitive = insensitive
      patterns = paths.map { url in url.pathComponents.map { insensitive ? $0.lowercased() : $0 } }
    }

    func partition(_ root: ScanRoot) -> ScanRoot {
      guard root.source == .directory else { return root }
      var root = root
      root.caseInsensitiveCleanup = caseInsensitive
      let prefix = root.url.pathComponents.map(root.cleanupKey)
      root.cleanupPatterns = Set(
        patterns.compactMap { parts -> String? in
          guard parts.count > prefix.count,
            zip(parts, prefix).allSatisfy({ $0 == "*" || $0 == $1 })
          else { return nil }
          return parts.dropFirst(prefix.count).joined(separator: "/")
        })
      return root
    }
  }

  private static func within(_ path: String, _ parent: String) -> Bool {
    path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/")
  }

  private static func affected(_ root: ScanRoot, paths: Set<String>) -> Bool {
    guard root.source == .directory || root.source == .file else { return false }
    let base = root.cleanupKey(root.url.path)
    return paths.contains { raw in
      let path = root.cleanupKey(raw)
      if within(base, path) { return true }
      guard root.source == .directory, within(path, base) else { return false }
      return !root.excludedDirectories.contains {
        within(path, root.cleanupKey(root.url.appending(path: $0).path))
      }
    }
  }

  @concurrent static func read(
    receipts: [TrashReceipt], trash: URL, restored: Bool, disk: VolumeReading?,
    remeasurePaths: Set<String> = [], roots originalRoots: [ScanRoot], results originalResults: [String: RootSize],
    report prior: ScanReport?, simulatorListIncomplete: Bool, home: URL, projects: [URL],
    artifacts: [ProjectArtifact], interrupted: Bool = false, priorRoots: [ScanRoot] = [],
    priorResults: [String: RootSize] = [:]
  ) async throws -> Self {
    var patch = Self(roots: originalRoots, results: originalResults, artifacts: artifacts)
    let paths = Set(
      receipts.flatMap { [$0.original.path, trash.appending(path: $0.trashName).path] }).union(remeasurePaths)
    if interrupted {
      let known = Set(originalRoots.map(\.id))
      patch.roots += priorRoots.filter { !known.contains($0.id) && affected($0, paths: paths) }
    }
    if restored {
      let xcode = home.appending(path: "Library/Developer/Xcode")
      let products = xcode.appending(path: "Products").path
      let collections = [products, xcode.appending(path: "Archives").path]
      for receipt in receipts {
        guard let review = receipt.review,
          !review.profile.isMissingWorkspaceOutput,
          (review.profile.isProjectOutput ? review.inCurrentProjects(projects)
            : review.scope != nil && review.scope == prior?.scope),
          let group = ScanGroup(rawValue: review.category),
          review.permits(receipt.original, home: home),
          !patch.roots.contains(where: { $0.group == group && $0.url.path == review.path })
        else { continue }
        if group == .xcode && collections.contains(review.path) {
          let known = Set(patch.roots.map(\.id))
          let entries = try ExtendedInventory.xcodeEntries(in: receipt.original, device: review.device)
          patch.roots += entries.filter { !known.contains($0.id) }.map { entry in
            var root = entry
            root.expectedDevice = review.device
            return root
          }
          continue
        }
        // Receipts issued for old breakdown rows can still be restored. Only products
        // now have their own inventory root; other old children belong to their parent.
        guard review.parentItemID == nil || (group == .xcode &&
          receipt.original.deletingLastPathComponent().path == products) else { continue }
        var root = ScanRoot(
          group: group, title: review.title, url: receipt.original, profile: review.profile,
          source: review.file ? .file : .directory)
        if review.profile.isProjectOutput {
          guard review.inCurrentProjects(projects), let owner = review.projectOwner,
            let parent = patch.roots.filter({ ($0.url.path == owner || $0.projectOwner == owner)
              && review.path.hasPrefix($0.url.path + "/") }).max(by: { $0.url.path.count < $1.url.path.count }),
            let index = patch.roots.firstIndex(where: { $0.id == parent.id })
          else { continue }
          root.projectOwner = owner
          patch.roots[index].excludedDirectories.insert(String(review.path.dropFirst(parent.url.path.count + 1)))
        }
        if review.profile == .npxEntry,
          let index = patch.roots.firstIndex(where: { $0.url.path == receipt.original.deletingLastPathComponent().path }) {
          patch.roots[index].excludedDirectories.insert(receipt.original.lastPathComponent)
        }
        root.expectedDevice = review.device
        patch.roots.append(root)
      }
    }
    let derivedIndex = patch.roots.firstIndex { $0.profile == .xcodeWorkspace }
    var artifactFolders = Set<String>()
    if let i = derivedIndex {
      let base = patch.roots[i].url
      for receipt in receipts {
        let output = receipt.original
        if restored, output.path.hasPrefix(base.path + "/"),
          case .compiler(let name) = DevelopmentCache.at(output, home: home),
          !patch.roots.contains(where: { $0.url.path == output.path })
        {
          var root = ScanRoot(group: .xcode, title: "Xcode · " + name, url: output, profile: .xcodeCompilerCache)
          root.expectedDevice = patch.roots[i].expectedDevice
          patch.roots.append(root)
          patch.roots[i].excludedDirectories.insert(String(output.path.dropFirst(base.path.count + 1)))
          continue
        }
        let folder = output.deletingLastPathComponent().deletingLastPathComponent()
        guard folder.deletingLastPathComponent().path == base.path,
          output.path == folder.appending(path: ProjectAttribution.intermediates).path
        else { continue }
        artifactFolders.insert(folder.lastPathComponent)
        // A full scan while the output was in the Trash has no row for it.
        if restored,
          var root = ProjectAttribution.outputRoot(in: folder, home: home, selected: projects)
        {
          root.expectedDevice = patch.roots[i].expectedDevice
          if let index = patch.roots.firstIndex(where: { $0.id == root.id }) {
            patch.roots[index] = root
          } else {
            patch.roots.append(root)
          }
          patch.roots[i].excludedDirectories.insert(
            folder.lastPathComponent + "/" + ProjectAttribution.intermediates)
        }
      }
    }
    let device = receipts.first?.identity.device
    var leaves: [String: RootSize] = [:]
    var linkedLeaves = Set<String>()
    let projectDetails = patch.roots.contains {
      $0.group == .projects && affected($0, paths: paths)
    }
    // Only open physical endpoints covered by this inventory. The same reading can update
    // a simulator, an enclosing project, and the Trash without walking any of their siblings.
    patch.roots = patch.roots.compactMap(ScanExclusions.current.applying)
    let reviewFiles = Set(
      receipts.filter { $0.review?.file == true }.flatMap {
        [$0.original.path, trash.appending(path: $0.trashName).path]
      })
    let removedReviews = Dictionary(
      receipts.compactMap { receipt -> (String, RootSize)? in
        guard receipt.review != nil, !restored,
          let root = originalRoots.first(where: { $0.url.path == receipt.original.path }),
          let size = originalResults[root.id]
        else { return nil }
        return (receipt.original.path, size)
      }, uniquingKeysWith: { first, _ in first })
    for path in paths {
      let known = patch.roots.first {
        $0.url.path == path && ($0.source == .directory || $0.source == .file)
      }
      guard known != nil || patch.roots.contains(where: { affected($0, paths: [path]) }) else {
        continue
      }
      var leaf =
        known
        ?? ScanRoot(
          group: .other, title: "", url: URL(fileURLWithPath: path),
          source: reviewFiles.contains(path) ? .file : .directory)
      leaf.expectedDevice = device ?? leaf.expectedDevice
      var size = try await StorageMeter.measure(
        leaf, projectDetails: projectDetails, inspectCleanup: true)
      if size.sharedLinkBytes > 0 { linkedLeaves.insert(path) }
      size.projectHadLinks = !size.links.isEmpty
      size.releaseLinkIndex()
      leaves[path] = size
    }
    var changed: [ScanRoot] = []
    var oldRoots: [ScanRoot] = []
    for (index, var root) in patch.roots.enumerated() {
      let old = index < originalRoots.count ? originalRoots[index] : nil
      guard affected(root, paths: paths) || (old != nil && root != old) else { continue }
      // A cancelled discovery may not have pinned this root's volume yet.
      if interrupted && root.expectedDevice == nil {
        root.expectedDevice =
          priorRoots.first(where: { $0.id == root.id })?.expectedDevice ?? device
        patch.roots[index] = root
      }
      if let old { oldRoots.append(old) }
      changed.append(root)
      patch.affectedGroups.insert(root.group)
      if let size = leaves[root.url.path] {
        patch.results[root.id] = size
      } else if paths.contains(where: {
        within(root.cleanupKey(root.url.path), root.cleanupKey($0))
      }) {
        var size = try await StorageMeter.measure(root)
        size.releaseLinkIndex()
        patch.results[root.id] = size
      } else {
        let baseline = originalResults[root.id] ?? priorResults[root.id]
        var size = baseline.flatMap { $0.measured ? $0 : nil } ?? .incomplete
        for path in paths where affected(root, paths: [path]) {
          guard let leaf = leaves[path] else { continue }
          size.replaceBranch(
            path, in: root, with: leaf, previously: removedReviews[path],
            file: reviewFiles.contains(path))
        }
        size.finishBranches()
        patch.results[root.id] = size
      }
    }
    // A targeted refresh has no inode table for unchanged siblings. When a shared
    // allocation may have moved, show an estimate until the next complete scan.
    let priorOverlap = Set(originalRoots.filter {
      $0.group == .projects && (originalResults[$0.id]?.projectOverlapBytes ?? 0) > 0
    }.map { $0.projectOwner ?? $0.url.path })
    let uncertain = Set(changed.compactMap { root -> String? in
      guard root.group == .projects else { return nil }
      let owner = root.projectOwner ?? root.url.path
      let old = originalResults[root.id]
      return old?.approximateProjectSize == true || linkedLeaves.contains(root.url.path)
        || (priorOverlap.contains(owner) && old?.projectHadLinks == true && leaves[root.url.path] != nil)
        ? owner : nil
    })
    for root in patch.roots where root.group == .projects && uncertain.contains(root.projectOwner ?? root.url.path) {
      patch.results[root.id]?.approximateProjectSize = true
      patch.results[root.id]?.projectOverlapBytes = 0
    }
    if let i = derivedIndex, !artifactFolders.isEmpty {
      let outputBytes = Dictionary(
        uniqueKeysWithValues: patch.roots.filter { $0.profile == .xcodeIntermediate }.map {
          (
            $0.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            patch.results[$0.id]?.bytes ?? 0
          )
        })
      let fresh = try await ProjectAttribution.derive(
        home: home, selected: projects, measurement: patch.results[patch.roots[i].id],
        outputBytes: outputBytes, only: artifactFolders)
      patch.artifacts =
        (artifacts.filter { !artifactFolders.contains($0.url.lastPathComponent) } + fresh)
        .sorted { $0.bytes > $1.bytes }
    }

    var groups = prior?.groups ?? [:]
    var safety = prior?.groupSafety ?? [:]
    for group in patch.affectedGroups {
      var size = GroupSize()
      var previousIndependent = GroupSize()
      var uncertainOverlap: Int64 = 0
      var replacedSharedRoot = false
      var overview = OverviewCategory()
      var complete = !interrupted && (group != .simulators || !simulatorListIncomplete)
      for root in patch.roots where root.group == group {
        overview.register(root)
        if let old = originalResults[root.id], root.includedInInventory(old) {
          try previousIndependent.include(old, for: root)
        }
        guard let row = patch.results[root.id] else {
          complete = false
          continue
        }
        overview.record(row, for: root)
        if let leaf = leaves[root.url.path] {
          uncertainOverlap += leaf.sharedLinkBytes
          replacedSharedRoot =
            replacedSharedRoot || (originalResults[root.id]?.sharedLinkBytes ?? 0) > 0
        }
        if root.includedInInventory(row) { try size.include(row, for: root) }
        if row.state != .complete && row.state != .absent { complete = false }
      }
      patch.categories[group] = overview
      let priorSplit = interrupted ? nil : prior?.groupSafety?[group.rawValue]
      if uncertainOverlap > 0 || (replacedSharedRoot && priorSplit != previousIndependent.breakdown)
      {
        complete = false
      }
      let adjusted = size.applyingPreviousOverlap(
        raw: previousIndependent.breakdown,
        deduplicated: priorSplit, uncertain: uncertainOverlap)
      patch.groupBytes[group] = adjusted?.total
      groups[group.rawValue] = complete ? (adjusted?.total ?? 0) : nil
      safety[group.rawValue] = adjusted
    }
    if let prior {
      patch.removedIDs = Set(
        ScanReport.makeItems(
          roots: oldRoots, results: originalResults, homeDevice: device
        ).map(\.id))
      let now = Date.now
      let homeDevice = device ?? (try? TrashFiles.directory(home, enumerate: false) { _, info in info.st_dev })
      patch.freshItems = ScanReport.makeItems(
        roots: changed, results: patch.results, homeDevice: homeDevice
      )
      .map {
        var item = $0
        item.measuredAt = now
        return item
      }
      if interrupted {
        // The previous display can come from history even if this pass stopped before
        // reaching the root. Replace its old rows and leave category totals lower bounds.
        let pathsByGroup = Dictionary(grouping: changed, by: { $0.group.rawValue })
          .mapValues { Set($0.map { $0.url.path }) }
        patch.removedIDs.formUnion(
          prior.items.compactMap { item in
            pathsByGroup[item.category]?.contains(item.path) == true && item.basis == "allocated"
              ? item.id : nil
          })
      }
      let items = prior.items.filter { !patch.removedIDs.contains($0.id) } + patch.freshItems
      patch.report = ScanReport(
        id: UUID(), date: prior.date, extended: prior.extended, free: disk?.free,
        capacity: disk?.bytes, items: items.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) },
        groups: groups, groupSafety: safety, measuredGroupBytes: safety.mapValues(\.total),
        scope: prior.scope,
        applications: prior.applications == nil ? nil : try ApplicationInventory.footprints(roots: patch.roots, results: patch.results))
    }
    return patch
  }
}
