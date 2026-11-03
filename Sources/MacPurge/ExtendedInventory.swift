import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// All external calls are fixed, read-only inventory operations. Output is drained
/// while the process runs; a missing tool, a sleeping engine or a cancelled scan
/// cannot hold the UI or the next scan indefinitely.
enum InventoryCommand {
  enum Failure: Error { case failed, timedOut, tooLarge }

  @concurrent static func output(
    _ executable: String, _ arguments: [String], timeout: Duration = .seconds(6)
  ) async throws -> Data {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    task.standardInput = FileHandle.nullDevice
    try Task.checkCancellation()
    try task.run()
    defer { if task.isRunning { kill(task.processIdentifier, SIGKILL) } }
    try pipe.fileHandleForWriting.close()
    let fd = pipe.fileHandleForReading.fileDescriptor
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.failed }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw Failure.timedOut }
      let n = read(fd, &buffer, buffer.count)
      if n > 0 {
        guard result.count + n <= 8_388_608 else { throw Failure.tooLarge }
        result.append(contentsOf: buffer.prefix(n))
      } else if n == 0 && !task.isRunning {
        guard task.terminationStatus == 0 else { throw Failure.failed }
        return result
      } else if n < 0 && errno != EAGAIN && errno != EINTR {
        throw Failure.failed
      } else {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
  }
}

enum ExtendedInventory {
  @concurrent static func discover(
    home: URL, includeProtected: Bool, simulatorInventory: SimulatorInventory,
    selectedProjects: [URL] = [],
    projectMeasurements: [String: RootSize] = [:]
  )
    async throws -> [ScanRoot]
  {
    var rows: [ScanRoot] = []
    func add(
      _ group: ScanGroup, _ title: String, _ path: String, _ profile: StorageProfile = .personal
    ) {
      let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appending(path: path)
      rows.append(ScanRoot(group: group, title: title, url: url, profile: profile))
    }
    // Discover direct children only. Record denied access so an unavailable
    // disk or permission is not displayed as an empty group.
    func children(
      _ group: ScanGroup, _ location: URL, profile: StorageProfile = .personal,
      keep: (String) -> Bool = { _ in true }
    ) throws {
      try Task.checkCancellation()
      do {
        for entry in try DirectoryIndex.children(of: location) {
          try Task.checkCancellation()
          guard keep(entry.url.lastPathComponent) else { continue }
          rows.append(
            .init(
              group: group, title: entry.url.lastPathComponent, url: entry.url, profile: profile,
              source: entry.directory ? .directory : .file))
        }
      } catch is CancellationError { throw CancellationError() } catch let error
        as DirectoryIndex.Problem where error.code == ENOENT
      { return } catch {
        rows.append(
          .init(
            group: group, title: location.lastPathComponent, url: location,
            source: .status("Konum listelenemedi")))
      }
    }
    add(.xcode, "Dağıtım arşivleri", "Library/Developer/Xcode/Archives")
    add(.xcode, "iOS aygıt desteği", "Library/Developer/Xcode/iOS DeviceSupport")
    for (item, path) in [
      ("Cypress", "Library/Caches/Cypress"), ("Playwright", "Library/Caches/ms-playwright"),
      ("Bun", ".bun/install/cache"), ("Maven", ".m2/repository"),
    ] {
      add(.packages, item, path, .packageDownloads)
    }
    for (name, path) in [
      ("Node sürümleri", ".nvm/versions"), ("Rust toolchain’leri", ".rustup/toolchains"),
      ("Python sürümleri", ".pyenv/versions"), ("Ruby sürümleri", ".rbenv/versions"),
      ("SDKMAN", ".sdkman/candidates"), ("Unity paketleri", "Library/Unity/cache"),
      ("JetBrains", "Library/Application Support/JetBrains"),
      ("VS Code eklentileri", ".vscode/extensions"),
    ] { add(.tools, name, path) }
    let env = ProcessInfo.processInfo.environment
    let hf =
      ProcessInfo.processInfo.environment["HF_HUB_CACHE"].map(URL.init(fileURLWithPath:))
      ?? env["HF_HOME"].map { URL(fileURLWithPath: $0).appending(path: "hub") }
      ?? home.appending(path: ".cache/huggingface/hub")
    try children(.models, hf) {
      $0.hasPrefix("models--") || $0.hasPrefix("datasets--") || $0.hasPrefix("spaces--")
    }
    let ollama =
      ProcessInfo.processInfo.environment["OLLAMA_MODELS"].map(URL.init(fileURLWithPath:))
      ?? home.appending(path: ".ollama/models")
    let models = try await ModelInventory.ollama(at: ollama)
    if models.isEmpty { add(.models, "Ollama model deposu", ollama.path) } else { rows += models }
    add(.models, "LM Studio", ".lmstudio/models")
    add(.models, "PyTorch modelleri", ".cache/torch")
    for (name, path) in [
      ("Claude Code", ".claude"), ("Codex", ".codex"), ("Gemini CLI", ".gemini"),
      ("GitHub Copilot CLI", ".copilot"), ("Grok CLI", ".grok"), ("Kilo Code", ".kilo"),
      ("Claude yerel imajları", "Library/Application Support/Claude/vm_bundles"),
      ("Chrome yerel modeli", "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"),
    ] { add(.models, name, path) }
    let sdk =
      [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }
      .first(where: { $0.hasPrefix("/") }) ?? home.appending(path: "Library/Android/sdk").path
    let sdkParts: Set<String> = [
      "system-images", "platform-tools", "platforms", "build-tools",
      "ndk", "ndk-bundle", "cmdline-tools", "tools", "cmake", "emulator", "sources",
      "extras", "patcher", "lldb", "skins", "add-ons",
    ]
    try children(.android, URL(fileURLWithPath: sdk)) { sdkParts.contains($0) }
    let avd =
      env["ANDROID_AVD_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
      ?? home.appending(path: ".android/avd")
    try children(.android, avd) { $0.hasSuffix(".avd") }
    try children(.android, home.appending(path: "Library/Caches/Google")) {
      $0.hasPrefix("AndroidStudio")
    }
    add(.android, "Android indirme önbelleği", ".android/cache")
    for path in [
      ".tart/vms", ".lima", ".colima", "VirtualBox VMs", "Parallels", "Virtual Machines.localized",
    ] {
      try children(.machines, home.appending(path: path))
    }
    for (name, path) in [
      ("Adobe Media Cache", "Library/Application Support/Adobe/Common/Media Cache Files"),
      ("Spotify", "Library/Application Support/Spotify/PersistentCache"),
      ("Slack", "Library/Application Support/Slack/Cache"),
      ("Discord", "Library/Application Support/discord/Cache"),
      ("Steam oyunları", "Library/Application Support/Steam/steamapps"),
      ("Apple Loops", "/Library/Audio/Apple Loops"),
      ("Logic ses kitaplığı", "/Library/Application Support/Logic"),
    ] { add(.apps, name, path) }
    if let temp = darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR) {
      add(.temp, "Kullanıcı geçici dosyaları", temp, .systemManaged)
    }
    add(.system, "Komut satırı araçları", "/Library/Developer/CommandLineTools", .systemManaged)
    add(.system, "Sistem takas dosyaları", "/private/var/vm", .systemManaged)
    add(.logs, "Sistem tanılama raporları", "/Library/Logs/DiagnosticReports", .logs)
    try children(.shared, URL(fileURLWithPath: "/Users/Shared"))
    if includeProtected {
      add(.trash, "Kullanıcı Çöpü", ".Trash")
      try children(.backups, home.appending(path: "Library/Application Support/MobileSync/Backup"))
      try children(
        .machines, home.appending(path: "Library/Containers/com.utmapp.UTM/Data/Documents")
      ) { $0.hasSuffix(".utm") }
    } else {
      for (group, path) in [
        (ScanGroup.trash, ".Trash"), (.backups, "Library/Application Support/MobileSync/Backup"),
      ] {
        rows.append(
          .init(
            group: group, title: group.rawValue, url: home.appending(path: path),
            source: .status("Korumalı konum taraması kapalı")))
      }
    }
    for (name, path) in [
      ("Xcode önbellekleri", "Library/Caches/com.apple.dt.Xcode"),
      ("SwiftUI önizleme cihazları", "Library/Developer/Xcode/UserData/Previews/Simulator Devices"),
      ("Xcode ürünleri", "Library/Developer/Xcode/Products"),
      ("Xcode kod asistanı", "Library/Developer/Xcode/CodingAssistant"),
      ("watchOS aygıt desteği", "Library/Developer/Xcode/watchOS DeviceSupport"),
      ("tvOS aygıt desteği", "Library/Developer/Xcode/tvOS DeviceSupport"),
      ("visionOS aygıt desteği", "Library/Developer/Xcode/visionOS DeviceSupport"),
    ] { add(.xcode, name, path) }
    for (name, path) in [
      ("pnpm yerel deposu", ".local/share/pnpm/store"), ("pnpm klasik depo", ".pnpm-store"),
      ("Gradle dağıtımları", ".gradle/wrapper/dists"), ("Go modülleri", "go/pkg/mod"),
      ("npx", ".npm/_npx"), ("Conda paketleri", ".conda/pkgs"),
      ("CocoaPods paket dizini", ".cocoapods/repos"), ("Ivy", ".ivy2"),
    ] { add(.packages, name, path, .packageDownloads) }
    for (name, path) in [
      ("Miniconda", "miniconda3"), ("Anaconda", "anaconda3"),
      ("Cursor eklentileri", ".cursor/extensions"),
      ("JetBrains önbellekleri", "Library/Caches/JetBrains"),
      ("Unity editörleri", "/Applications/Unity/Hub/Editor"),
      ("fnm Node sürümleri", ".local/share/fnm"), ("NuGet", ".local/share/NuGet"),
      ("Puppeteer tarayıcıları", ".cache/puppeteer"), ("Prisma", ".cache/prisma"),
      ("Node araç önbelleği", ".cache/node"), ("MongoDB imajları", ".cache/mongodb-binaries"),
      ("Antigravity eklentileri", ".antigravity-ide/extensions"), ("OrbStack", ".orbstack"),
    ] { add(.tools, name, path) }
    for app in RenderCacheOwner.all {
      for cache in RenderCacheOwner.leaves {
        add(
          .apps, app.folder + " · " + cache,
          "Library/Application Support/" + app.folder + "/" + cache,
          .renderCache)
      }
    }
    add(
      .simulators, "Simülatör paylaşılan dyld önbelleği",
      "/Library/Developer/CoreSimulator/Caches/dyld", .simulatorCache)
    add(.logs, "Birleşik sistem günlükleri", "/private/var/db/diagnostics", .logs)
    add(.logs, "Tanılama metin arşivi", "/private/var/db/uuidtext", .logs)
    add(.logs, "iOS aygıt günlükleri", "Library/Developer/Xcode/iOS Device Logs", .logs)
    add(.system, "Sistem önbellekleri", "/Library/Caches", .systemManaged)
    if let cache = darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR) {
      add(.temp, "Kullanıcının geçici önbelleği", cache, .systemManaged)
    }
    let known = ScanRoot.catalog(home: home, projects: selectedProjects) + rows
    rows += try CategoryLocations.discover(
      home: home, known: known, includeProtected: includeProtected)
    let tooling = try await toolReports(home: home, devices: simulatorInventory)
    rows += tooling
    let claimed = (ScanRoot.catalog(home: home, projects: []) + rows).map(\.url)
    for project in selectedProjects {
      rows += try CategoryLocations.largeFolders(
        in: project, excluding: claimed,
        measurement: projectMeasurements[project.path])
    }
    return rows
  }

  private static func darwinUserDirectory(_ key: Int32) -> String? {
    let length = confstr(key, nil, 0)
    guard length > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: length)
    guard confstr(key, &buffer, length) == length else { return nil }
    let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    // Darwin returns /var/folders/…; use the physical system prefix without
    // resolving any symlink inside a user's temp or cache tree.
    return path.hasPrefix("/var/folders/") ? "/private" + path : path
  }

  static func runtimeRows(
    data: Data, devices: SimulatorInventory, sdkBuilds: Set<String>?, base: URL
  ) throws -> [ScanRoot] {
    struct Runtime: Decodable {
      let runtimeIdentifier, path, build, lastUsedAt: String?
      let sizeBytes: Int64?
    }
    let runtimes = try JSONDecoder().decode([String: Runtime].self, from: data)
    let identifiers = runtimes.values.compactMap(\.runtimeIdentifier)
    let devicesByRuntime = Dictionary(grouping: devices.roots.compactMap(\.device), by: \.runtime)
    let dateParser = ISO8601DateFormatter()
    let fractionalParser = ISO8601DateFormatter()
    fractionalParser.formatOptions.insert(.withFractionalSeconds)
    return runtimes.sorted { $0.key < $1.key }.map { key, item in
      let identifier = item.runtimeIdentifier
      let complete = identifier != nil && devices.note == nil && devicesByRuntime[nil] == nil
      let linked = identifier.flatMap { devicesByRuntime[$0] } ?? []
      let sameVersion = identifier.map { id in identifiers.filter { $0 == id }.count > 1 } ?? false
      let usage = RuntimeUsage(
        lastUsed: item.lastUsedAt.flatMap {
          dateParser.date(from: $0) ?? fractionalParser.date(from: $0)
        },
        devices: linked.sorted { ($0.name, $0.id) < ($1.name, $1.id) },
        deviceListComplete: complete, multipleImages: sameVersion)
      let unused =
        complete && linked.isEmpty
        && item.build.flatMap { build in sdkBuilds.map { !$0.contains(build) } } == true
      let id = (identifier ?? key).replacingOccurrences(
        of: "com.apple.CoreSimulator.SimRuntime.", with: "")
      let title = "\(id) · \(item.build ?? key)" + (unused ? " · SDK/cihaz eşleşmesi yok" : "")
      return ScanRoot(
        group: .runtimes, title: title,
        url: item.path.map(URL.init(fileURLWithPath:)) ?? base.appending(path: key),
        profile: .systemManaged, source: .report(item.sizeBytes), runtimeUsage: usage)
    }
  }

  private static func toolReports(home: URL, devices: SimulatorInventory) async throws -> [ScanRoot]
  {
    var rows: [ScanRoot] = []
    func toolError(_ group: ScanGroup, _ title: String, _ url: URL) {
      rows.append(
        .init(
          group: group, title: title, url: url,
          source: .status("Araç kullanılamıyor veya yanıt vermedi")))
    }
    let runtimeRoot = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Images")
    do {
      let data = try await InventoryCommand.output(
        "/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
      let captures = try? await InventoryCommand.output(
        "/usr/bin/xcrun", ["simctl", "runtime", "match", "list", "-j"])
      let matches = captures.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]]
      }
      let sdkBuilds = matches.map {
        Set($0.values.compactMap { $0["chosenRuntimeBuild"] as? String })
      }
      rows += try runtimeRows(data: data, devices: devices, sdkBuilds: sdkBuilds, base: runtimeRoot)
    } catch is CancellationError { throw CancellationError() } catch {
      toolError(.runtimes, "Runtime envanteri", runtimeRoot)
    }
    let snapshots = URL(fileURLWithPath: "/")
    do {
      let data = try await InventoryCommand.output("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
      let list = String(decoding: data, as: UTF8.self).split(separator: "\n").filter {
        $0.hasPrefix("com.apple.")
      }
      for item in list {
        rows.append(
          .init(
            group: .snapshots, title: String(item), url: snapshots, profile: .systemManaged,
            source: .report(nil)))
      }
    } catch is CancellationError { throw CancellationError() } catch {
      toolError(.snapshots, "Yerel snapshot listesi", snapshots)
    }
    let fm = FileManager.default
    let executable = [
      "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
      "/Applications/Docker.app/Contents/Resources/bin/docker",
    ].first(where: fm.isExecutableFile(atPath:))
    let sockets = [home.appending(path: ".docker/run/docker.sock").path, "/var/run/docker.sock"]
    if let executable, let socket = sockets.first(where: fm.fileExists(atPath:)) {
      let url = URL(fileURLWithPath: socket)
      do {
        let data = try await InventoryCommand.output(
          executable, ["--host", "unix://" + socket, "system", "df", "--format", "{{json .}}"])
        struct Usage: Decodable {
          let type: String
          let reclaimable: String
          enum CodingKeys: String, CodingKey { case type = "Type", reclaimable = "Reclaimable" }
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
          let usage = try JSONDecoder().decode(Usage.self, from: Data(line.utf8))
          rows.append(
            .init(
              group: .docker, title: "Docker · " + usage.type + " (araç tahmini)", url: url,
              profile: .personal,
              source: .report(
                parseBytes(String(usage.reclaimable.split(separator: " ").first ?? "")))))
        }
        let local = try await InventoryCommand.output(
          "/usr/bin/curl",
          [
            "--disable", "--unix-socket", socket, "--max-time", "4", "--noproxy", "*", "--fail",
            "--silent", "http://localhost/system/df?verbose=1",
          ])
        rows += try ComposeInventory.rows(data: local, socket: url)
      } catch is CancellationError { throw CancellationError() } catch {
        toolError(.docker, "Yerel Docker Engine", url)
      }
    } else {
      rows.append(
        .init(
          group: .docker, title: "Yerel Docker Engine", url: home.appending(path: ".docker"),
          source: .status("Yerel Docker bağlantısı bulunamadı")))
    }
    return rows
  }

  static func parseBytes(_ raw: String) -> Int64? {
    let text = raw.trimmingCharacters(in: .whitespaces)
    let digits = text.prefix { $0.isNumber || $0 == "." }
    let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).uppercased()
    guard let n = Double(digits),
      let factor = ["B": 1.0, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit],
      n >= 0, n * factor < Double(Int64.max)
    else { return nil }
    return Int64(n * factor)
  }
}
