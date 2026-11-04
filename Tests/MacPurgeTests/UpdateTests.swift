import Foundation
import Testing
@testable import MacPurge

struct UpdateTests {
  private static func manifest(version: String = "0.7.0", asset: String = ReleaseContract.assetName,
    bundle: String = ReleaseContract.bundleIdentifier, team: String = ReleaseContract.teamIdentifier,
    hash: String = String(repeating: "a", count: 64)) -> UpdateManifest {
    UpdateManifest(version: version, asset: asset, sha256: hash, bundleIdentifier: bundle, teamIdentifier: team)
  }
  private static func response(_ url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
  }
  private static let releaseURL = URL(string: "https://github.com/burakereno/macpurge/releases/tag/v0.7.0")!

  @Test func versionsCompareNumericallyAndRejectAmbiguousTags() throws {
    #expect(try UpdateVersion("1.10.0") > UpdateVersion("1.9.9"))
    #expect(try UpdateVersion("1.0.0") == UpdateVersion("1.0.0"))
    for version in ["1.0", "v1.0.0", "01.0.0", "1.0.0-beta", "1.0.0/evil", "1.0.-1", "", "x.y.z"] {
      #expect(throws: UpdateError.self) { try UpdateVersion(version) }
    }
    for url in ["https://example.com/burakereno/macpurge/releases/tag/v0.7.0",
      "https://github.com/other/macpurge/releases/tag/v0.7.0",
      "https://github.com/burakereno/macpurge/releases/latest",
      "http://github.com/burakereno/macpurge/releases/tag/v0.7.0",
      "https://github.com/burakereno/macpurge/releases/tag/v0.7.0?unexpected=1"] {
      #expect(throws: UpdateError.self) { try UpdateService.releaseURLs(from: URL(string: url)!) }
    }
    let urls = try UpdateService.releaseURLs(from: Self.releaseURL)
    #expect(urls.version == "0.7.0")
    #expect(urls.dmg.absoluteString == "https://github.com/burakereno/macpurge/releases/download/v0.7.0/MacPurge.dmg")
  }

  @Test func manifestRejectsWrongPublisherBundleVersionAssetAndHash() throws {
    try Self.manifest().validate(version: "0.7.0")
    for manifest in [Self.manifest(version: "0.6.0"), Self.manifest(asset: "other.dmg"),
      Self.manifest(bundle: "other.app"), Self.manifest(team: "OTHERTEAM"), Self.manifest(hash: "invalid")] {
      #expect(throws: UpdateError.self) { try manifest.validate(version: "0.7.0") }
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("abc".utf8).write(to: file)
    #expect(try UpdateSecurity.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    try Data("damaged".utf8).write(to: file)
    #expect(try UpdateSecurity.sha256(of: file) != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func releaseIsOfferedOnlyAfterAssetAndManifestAreValidated() async throws {
    let good = UpdateService(load: { request in
      let url = request.url!
      if url.lastPathComponent == "latest" { return (Data(), Self.response(Self.releaseURL)) }
      if url.lastPathComponent == ReleaseContract.manifestName {
        return (try JSONEncoder().encode(Self.manifest()), Self.response(url))
      }
      #expect(request.httpMethod == "HEAD")
      return (Data(), Self.response(url))
    })
    #expect(try await good.fetch().version == "0.7.0")
    let missing = UpdateService(load: { request in
      let url = request.url!
      return url.lastPathComponent == "latest"
        ? (Data(), Self.response(Self.releaseURL)) : (Data(), Self.response(url, status: 404))
    })
    await #expect(throws: UpdateError.missingAsset) { try await missing.fetch() }
    let badManifest = UpdateService(load: { request in
      let url = request.url!
      if url.lastPathComponent == "latest" { return (Data(), Self.response(Self.releaseURL)) }
      return (try JSONEncoder().encode(Self.manifest(team: "WRONG")), Self.response(url))
    })
    await #expect(throws: UpdateError.invalidManifest) { try await badManifest.fetch() }
    #expect(throws: UpdateError.self) {
      try UpdateService.validate(Self.response(URL(string: "https://evil.example/update.dmg")!))
    }
    #expect(throws: UpdateError.self) { try UpdateService.validate(Self.response(Self.releaseURL, status: 403)) }
  }

  @MainActor @Test func automaticErrorsStayQuietAndManualErrorsAreVisible() async throws {
    let suite = "macpurge-updater-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let failure = UpdateChecker(defaults: defaults, version: "0.6.0", fetch: { throw UpdateError.badResponse })
    await failure.check(manual: false)
    #expect(failure.lastError == nil && failure.lastChecked == nil && !failure.available)
    await failure.check(manual: true)
    #expect(failure.lastError != nil && !failure.checking)
    let urls = try UpdateService.releaseURLs(from: Self.releaseURL)
    let release = UpdateRelease(tag: urls.tag, version: urls.version, downloadURL: urls.dmg,
      manifestURL: urls.manifest, manifest: Self.manifest())
    let success = UpdateChecker(defaults: defaults, version: "0.6.0", fetch: { release })
    await success.check(manual: true)
    #expect(success.available && success.lastError == nil && success.lastChecked != nil)
    let current = UpdateChecker(defaults: defaults, version: "0.7.0", fetch: { release })
    await current.check(manual: true)
    #expect(!current.available && current.lastChecked != nil)
  }
}
