import Foundation

enum PayloadVerification {
  static let identifier = "com.burakerenoglu.macpurge.prototype"
  static let team = "66K3EFBVB6"
  struct Invalid: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
  @concurrent static func inspect(_ url: URL) async throws -> String {
    let requirement =
      "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    guard url.pathExtension == "app" else { throw Invalid("Bir MacPurge uygulama paketi seç.") }
    do {
      _ = try await InventoryCommand.output(
        "/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R=" + requirement, url.path],
        timeout: .seconds(20))
    } catch { throw Invalid("Paket, MacPurge kimliği ve geliştirici imzasıyla doğrulanamadı.") }
    guard let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier,
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else { throw Invalid("Sürüm bilgisi okunamadı.") }
    let current =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let relation = version.compare(current, options: .numeric)
    return "İmza ve paket bütünlüğü doğrulandı · \(version) · "
      + (relation == .orderedDescending
        ? "Daha yeni sürüm" : relation == .orderedSame ? "Mevcut sürüm" : "Eski sürüm")
  }
}
