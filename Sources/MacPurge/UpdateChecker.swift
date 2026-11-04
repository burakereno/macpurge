import AppKit
import Foundation
import Observation

struct UpdateVersion: Comparable, Equatable, Sendable {
  let components: [Int]
  init(_ text: String) throws {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({
      !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber })
        && ($0 == "0" || !$0.hasPrefix("0")) && Int($0) != nil
    }) else { throw UpdateError.missingVersion }
    components = parts.map { Int($0)! }
  }
  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.components.lexicographicallyPrecedes(rhs.components)
  }
}

enum UpdateError: LocalizedError, Equatable {
  case badResponse, missingVersion, missingAsset, invalidManifest, checksumMismatch
  case invalidInstaller, unwritableInstallation, localBuild
  var errorDescription: String? {
    let key: String = switch self {
    case .badResponse: "The update server returned an invalid response. Try again later."
    case .missingVersion: "The release does not have a valid version tag."
    case .missingAsset: "The release installer is unavailable. Try again later."
    case .invalidManifest: "The update information does not match MacPurge."
    case .checksumMismatch: "The download is incomplete or damaged. Please download it again."
    case .invalidInstaller: "The update could not be verified as a signed MacPurge release."
    case .unwritableInstallation: "Move MacPurge to a writable Applications folder before updating."
    case .localBuild: "Update installation is available in the released MacPurge app."
    }
    return ReviewLanguage.text(key)
  }
}

struct UpdateRelease: Equatable, Sendable {
  let tag: String
  let version: String
  let downloadURL: URL
  let manifestURL: URL
  let manifest: UpdateManifest
}

struct UpdateService: Sendable {
  let session: URLSession
  private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  init(session: URLSession = .shared,
    load: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    self.session = session
    self.load = load ?? { try await session.data(for: $0) }
  }

  static let latestURL = URL(string: "https://github.com/\(ReleaseContract.owner)/\(ReleaseContract.repository)/releases/latest")!

  static func releaseURLs(from url: URL) throws -> (tag: String, version: String, dmg: URL, manifest: URL) {
    let parts = url.pathComponents
    guard url.scheme == "https", url.host == "github.com", url.port == nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      parts.count == 6,
      Array(parts.prefix(5)) == ["/", ReleaseContract.owner, ReleaseContract.repository, "releases", "tag"],
      let tag = parts.last, tag.hasPrefix("v") else { throw UpdateError.missingVersion }
    let version = String(tag.dropFirst())
    _ = try UpdateVersion(version)
    let base = URL(string: "https://github.com/\(ReleaseContract.owner)/\(ReleaseContract.repository)/releases/download")!
      .appendingPathComponent(tag)
    return (tag, version, base.appendingPathComponent(ReleaseContract.assetName),
      base.appendingPathComponent(ReleaseContract.manifestName))
  }

  static func request(_ url: URL, head: Bool = false) -> URLRequest {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    request.httpMethod = head ? "HEAD" : "GET"
    request.timeoutInterval = 20
    request.setValue("MacPurge-Updater", forHTTPHeaderField: "User-Agent")
    return request
  }

  static func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let url = http.url, url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil,
      ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host)
    else { throw UpdateError.badResponse }
  }

  func fetch() async throws -> UpdateRelease {
    let (_, latest) = try await load(Self.request(Self.latestURL, head: true))
    try Self.validate(latest)
    guard let resolved = latest.url else { throw UpdateError.missingVersion }
    let urls = try Self.releaseURLs(from: resolved)
    let (_, dmgResponse) = try await load(Self.request(urls.dmg, head: true))
    if (dmgResponse as? HTTPURLResponse)?.statusCode == 404 { throw UpdateError.missingAsset }
    try Self.validate(dmgResponse)
    let (data, response) = try await load(Self.request(urls.manifest))
    try Self.validate(response)
    guard data.count < 64 * 1024,
      let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data)
    else { throw UpdateError.invalidManifest }
    try manifest.validate(version: urls.version)
    return UpdateRelease(tag: urls.tag, version: urls.version, downloadURL: urls.dmg,
      manifestURL: urls.manifest, manifest: manifest)
  }

  @concurrent func download(_ release: UpdateRelease, into directory: URL) async throws -> URL {
    // Reconstruct from the trusted tag; never install a caller-supplied download URL.
    guard let tagURL = URL(string:
      "https://github.com/\(ReleaseContract.owner)/\(ReleaseContract.repository)/releases/tag/\(release.tag)") else {
      throw UpdateError.invalidManifest
    }
    let urls = try Self.releaseURLs(from: tagURL)
    guard release.version == urls.version, release.downloadURL == urls.dmg,
      release.manifestURL == urls.manifest else { throw UpdateError.invalidManifest }
    try release.manifest.validate(version: release.version)
    let (temporary, response) = try await session.download(for: Self.request(urls.dmg))
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Self.validate(response)
    let destination = directory.appendingPathComponent(ReleaseContract.assetName)
    try FileManager.default.moveItem(at: temporary, to: destination)
    guard try UpdateSecurity.sha256(of: destination) == release.manifest.sha256 else {
      throw UpdateError.checksumMismatch
    }
    return destination
  }
}

@MainActor @Observable final class UpdateChecker {
  static let shared = UpdateChecker()
  private(set) var release: UpdateRelease?
  private(set) var checking = false
  private(set) var installing = false
  private(set) var lastError: String?
  private(set) var installationError: String?
  private(set) var lastChecked: Date?
  private(set) var installationStatus: String?
  private let currentVersion: String
  private let fetch: @Sendable () async throws -> UpdateRelease
  private var timer: Task<Void, Never>?
  private let defaults: UserDefaults
  var automaticChecks: Bool {
    didSet { defaults.set(automaticChecks, forKey: "automaticUpdateChecks") }
  }
  var version: String { currentVersion }
  var available: Bool {
    guard let release, let latest = try? UpdateVersion(release.version),
      let current = try? UpdateVersion(currentVersion) else { return false }
    return latest > current
  }

  init(defaults: UserDefaults = .standard,
    version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
    fetch: @escaping @Sendable () async throws -> UpdateRelease = { try await UpdateService().fetch() }
  ) {
    self.defaults = defaults
    self.currentVersion = version
    self.fetch = fetch
    automaticChecks = defaults.object(forKey: "automaticUpdateChecks") == nil || defaults.bool(forKey: "automaticUpdateChecks")
  }

  func start() {
    guard timer == nil, Bundle.main.bundleIdentifier == ReleaseContract.bundleIdentifier,
      !CommandLine.arguments.contains("--demo") else { return }
    consumeInstallationResult()
    timer = Task { [weak self] in
      while !Task.isCancelled {
        if self?.automaticChecks == true { await self?.check(manual: false) }
        do { try await Task.sleep(for: .seconds(6 * 3600)) } catch { return }
      }
    }
  }

  func check(manual: Bool) async {
    guard !checking, !installing else { return }
    checking = true
    if manual { lastError = nil }
    defer { checking = false }
    do {
      let found = try await fetch()
      _ = try UpdateVersion(currentVersion)
      release = found
      lastChecked = .now
      lastError = nil
    } catch {
      if manual { lastError = error.localizedDescription }
    }
  }

  func downloadAndInstall() async {
    guard !installing else { return }
    guard Bundle.main.bundleIdentifier == ReleaseContract.bundleIdentifier else {
      lastError = UpdateError.localBuild.localizedDescription; return
    }
    guard let release, available else {
      lastError = UpdateError.missingAsset.localizedDescription; return
    }
    installing = true
    lastError = nil
    installationError = nil
    installationStatus = ReviewLanguage.text("Downloading update…")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macpurge-update-" + UUID().uuidString)
    var handedOff = false
    defer {
      installing = false
      installationStatus = nil
      if !handedOff { try? FileManager.default.removeItem(at: directory) }
    }
    do {
      let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
      guard !target.path.contains("/AppTranslocation/"),
        FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
      else { throw UpdateError.unwritableInstallation }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let dmg = try await UpdateService().download(release, into: directory)
      installationStatus = ReviewLanguage.text("Verifying update…")
      try await UpdateSecurity.validateInstaller(dmg: dmg, directory: directory, version: release.version)
      try UpdateInstaller.launch(dmg: dmg, target: target, release: release, directory: directory)
      handedOff = true
      NSApp.terminate(nil)
    } catch { lastError = error.localizedDescription }
  }

  private func consumeInstallationResult() {
    let result = UpdateInstaller.resultURL
    if let message = try? String(contentsOf: result, encoding: .utf8), !message.isEmpty {
      installationError = ReviewLanguage.text("The update could not be installed. Your previous version was restored.")
      try? FileManager.default.removeItem(at: result)
    }
  }
}
