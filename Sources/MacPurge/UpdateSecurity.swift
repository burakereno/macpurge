import CryptoKit
import Foundation

struct UpdateManifest: Codable, Equatable, Sendable {
  let version, asset, sha256, bundleIdentifier, teamIdentifier: String
  func validate(version expected: String) throws {
    guard version == expected, asset == ReleaseContract.assetName,
      bundleIdentifier == ReleaseContract.bundleIdentifier,
      teamIdentifier == ReleaseContract.teamIdentifier,
      sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw UpdateError.invalidManifest }
    _ = try UpdateVersion(version)
  }
}

enum UpdateSecurity {
  static let requirement = "anchor apple generic and identifier \"\(ReleaseContract.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(ReleaseContract.teamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

  static func sha256(of url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func validateInstaller(dmg: URL, directory: URL, version: String) async throws {
    let mount = directory.appendingPathComponent("validation-mount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
    do {
      // codesign --verify and spctl --assess independently bind the bytes to the publisher.
      try await verifySignature(dmg)
      _ = try await InventoryCommand.output("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", dmg.path], timeout: .seconds(60))
      // hdiutil attach -readonly; no fixed mount paths or quarantine changes.
      _ = try await InventoryCommand.output("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path], timeout: .seconds(60))
      let app = mount.appendingPathComponent(ReleaseContract.appBundleName)
      do {
        try await verifySignature(app, app: true)
        guard let bundle = Bundle(url: app),
          bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String == ReleaseContract.bundleIdentifier,
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
          FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + ReleaseContract.executableName).path)
        else { throw UpdateError.invalidInstaller }
        _ = try await InventoryCommand.output("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: .seconds(60))
      } catch {
        _ = try? await InventoryCommand.output("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: .seconds(30))
        throw error
      }
      _ = try await InventoryCommand.output("/usr/bin/hdiutil", ["detach", mount.path], timeout: .seconds(30))
    } catch { throw UpdateError.invalidInstaller }
  }

  private static func verifySignature(_ url: URL, app: Bool = false) async throws {
    var arguments = ["--verify", "--strict"]
    if app { arguments += ["--deep", "-R=" + requirement] }
    _ = try await InventoryCommand.output("/usr/bin/codesign", arguments + [url.path], timeout: .seconds(60))
    let data = try await InventoryCommand.output("/usr/bin/codesign", ["-d", "--verbose=4", url.path], captureError: true)
    let details = String(decoding: data, as: UTF8.self)
    guard details.split(separator: "\n").contains(where: { $0 == "TeamIdentifier=" + ReleaseContract.teamIdentifier }) else {
      throw UpdateError.invalidInstaller
    }
  }
}
