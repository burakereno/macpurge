import Darwin
import Foundation

/// An old Intermediates.noindex tree can contain generated sources as well as compiled objects.
enum XcodeOrphanBuild {
  private static let minimumAge: time_t = 24 * 60 * 60
  private static let metadataExtensions: Set<String> = [
    "d", "dia", "scan", "dep", "dat", "hmap", "resp", "linkfilelist", "json", "plist_thinned",
    "dependencymetadatafilelist", "dependencystaticmetadatafilelist", "swiftfilelist", "swiftdeps",
    "swiftdoc", "swiftconstvalues", "swiftconstvaluesfilelist", "swiftsourceinfo", "priors",
    "stringsdata", "stamp", "xcfilelist", "xcent", "der",
  ]
  private static let targets: Set<String> = [
    "iphoneos", "iphonesimulator", "macosx", "watchos", "watchsimulator", "appletvos",
    "appletvsimulator", "xros", "xrsimulator", "maccatalyst",
  ]
  private static let machO: Set<UInt32> = [
    0xcffaedfe, 0xcefaedfe, 0xfeedfacf, 0xfeedface, 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca,
  ]
  private static let bitcode: Set<UInt32> = [0xdec0170b, 0x4243c0de]
  private static let protectedFlags = UInt32(SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE | SF_NOUNLINK | UF_APPEND | SF_APPEND)

  static func validateRoot(_ root: URL) throws {
    try TrashFiles.directory(root.appending(path: "XCBuildData"), enumerate: false) { fd, _ in
      var info = stat()
      guard fstatat(fd, "build.db", &info, AT_SYMLINK_NOFOLLOW) == 0,
        info.st_mode & S_IFMT == S_IFREG
      else { throw CleanupFailure("Xcode build metadata could not be verified.") }
    }
  }

  static func accepts(_ parts: [String], directory: Bool) -> Bool {
    guard let first = parts.first, let name = parts.last,
      !name.hasPrefix("."), !["Package.swift", "project.pbxproj", "Podfile", "package.json"].contains(name)
    else { return false }
    let suffix = (name as NSString).pathExtension.lowercased()
    switch first {
    case "XCBuildData":
      return acceptsBuildData(parts, directory: directory)
    case "ExplicitPrecompiledModules", "SwiftExplicitPrecompiledModules", "PrecompiledHeaders":
      if directory { return parts.count == 1 }
      return parts.count == 2 && (name == "modules.timestamp"
        || ["pcm", "pch", "swiftmodule", "d", "dia", "scan"].contains(suffix))
    case "EagerLinkingTBDs":
      if directory { return parts.count == 1 || (parts.count == 2 && isConfiguration(name)) }
      return parts.count == 3 && suffix == "tbd"
    default:
      guard first.hasSuffix(".build") else { return false }
      if parts.count == 1 { return directory }
      guard isConfiguration(parts[1]) else { return false }
      if parts.count == 2 { return directory }
      let target = parts[2]
      if target.contains("-VFS-") {
        return parts.count == 3 ? directory : parts.count == 4 && !directory && name == "all-product-headers.yaml"
      }
      guard target.hasSuffix(".build") else { return false }
      if parts.count == 3 { return directory }
      if directory {
        return ["Objects-normal", "DerivedSources", "Binary", "assetcatalog_output", "thinned", "unthinned", "ssu",
          "arm64", "arm64e", "arm64_32", "x86_64", "i386", "armv7k"].contains(name) || suffix == "storyboardc"
      }
      let parent = parts[parts.count - 2]
      if metadataExtensions.contains(suffix) || ["o", "a", "pcm", "pch", "swiftmodule"].contains(suffix) { return true }
      switch suffix {
      case "":
        return parent == "Binary" || ["assetcatalog_dependencies", "assetcatalog_dependencies_thinned",
          "assetcatalog_signature"].contains(name) || name.range(
          of: #"^(supplementaryOutputs|outputs|sources|index-unit-outputs)-[0-9]+$"#,
          options: .regularExpression) != nil
      case "h":
        return name.hasSuffix("-Swift.h") || (parent == "DerivedSources" && name == "GeneratedAssetSymbols.h")
      case "swift", "c":
        return parent == "DerivedSources" && (name == "GeneratedAssetSymbols.swift" || name.hasSuffix("_vers.c"))
      case "sh":
        return parts.count == 4 && name.range(of: #"^Script-[A-F0-9]+\.sh$"#, options: .regularExpression) != nil
      case "log", "txt":
        return parent == "DerivedSources" && (name == "react-codegen.log" || name.hasSuffix("-checkManifestLockResult.txt"))
      case "plist":
        return name.hasPrefix("assetcatalog_generated_") || name.hasSuffix("-SBPartialInfo.plist")
          || (name == "Info.plist" && parent.hasSuffix(".storyboardc"))
          || (parent == "DerivedSources" && ["Entitlements-Simulated.plist", "GeneratedAssetSymbols-Index.plist"].contains(name))
      case "nib":
        return parent.hasSuffix(".storyboardc")
      case "png", "car":
        return parts.contains("assetcatalog_output")
      default:
        return false
      }
    }
  }

  private static func isConfiguration(_ name: String) -> Bool {
    targets.contains(String(name.split(separator: "-").last ?? ""))
  }

  private static func acceptsBuildData(_ parts: [String], directory: Bool) -> Bool {
    if parts.count == 1 { return directory }
    let name = parts.last ?? ""
    if parts[1] == "PIFCache" {
      if parts.count == 2 { return directory }
      guard ["target", "workspace", "project"].contains(parts[2]) else { return false }
      return parts.count == 3 ? directory : parts.count == 4 && !directory
        && name.hasPrefix(parts[2].uppercased() + "@v") && name.hasSuffix("-json")
    }
    if parts.count == 2 && !directory { return ["build.db", "prior-build-descriptions.txt"].contains(name) }
    guard parts[1].hasSuffix(".xcbuilddata"), isBuildHash(String(parts[1].dropLast(".xcbuilddata".count)))
    else { return false }
    if parts.count == 2 { return directory }
    if parts.count == 3 {
      return directory ? name == "attachments" :
        ["target-graph.txt", "task-store.msgpack", "description.msgpack", "manifest.json", "build-request.json"].contains(name)
    }
    return parts.count == 4 && parts[2] == "attachments" && !directory && isBuildHash(name)
  }

  private static func isBuildHash(_ name: String) -> Bool {
    name.utf8.count == 32 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func verifyOld(_ info: stat) throws {
    guard info.st_mtimespec.tv_sec <= time(nil) - minimumAge else {
      throw CleanupFailure("These Xcode build files changed within the last 24 hours.")
    }
    guard info.st_flags & protectedFlags == 0 else {
      throw CleanupFailure("These Xcode build files contain a protected item.")
    }
  }

  /// Return the allocated bytes this entry shares with other files.
  static func sharedBytes(for parts: [String], in parent: Int32, info: stat) throws -> Int64 {
    try verifyOld(info)
    guard info.st_mode & S_IFMT == S_IFREG, let name = parts.last else { return 0 }
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw TrashFiles.posix() }
    defer { close(fd) }
    var current = stat()
    guard fstat(fd, &current) == 0, FileIdentity(current) == FileIdentity(info),
      current.st_size == info.st_size, current.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
      current.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
    else { throw CleanupFailure("Klasör ölçülürken değişti.") }
    try verifyHeader(name, binary: parts.dropLast().last == "Binary", in: fd)
    let allocated = Int64(info.st_blocks) * 512
    guard allocated > 0 else { return 0 }
    guard let privateBytes = FileComparison.privateAllocatedBytes(fd) else {
      throw CleanupFailure("Could not verify private disk blocks for these Xcode build files.")
    }
    return allocated - min(allocated, privateBytes)
  }

  private static func verifyHeader(_ name: String, binary: Bool, in fd: Int32) throws {
    let suffix = (name as NSString).pathExtension.lowercased()
    guard binary || ["o", "a", "pcm", "pch", "swiftmodule", "db"].contains(suffix) else { return }
    var header = [UInt8](repeating: 0, count: 16)
    let count = read(fd, &header, header.count)
    let magic = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let valid: Bool
    switch suffix {
    case "a": valid = count >= 8 && [Array("!<arch>\n".utf8), Array("!<thin>\n".utf8)].contains(Array(header.prefix(8)))
    case "swiftmodule": valid = count >= 4 && [0xe29ca80e, 0x2d2d2d0a].contains(magic)
    case "db": valid = count == 16 && header == Array("SQLite format 3\0".utf8)
    case "pcm", "pch": valid = count >= 4 && (machO.contains(magic) || magic == 0x43504348)
    default: valid = count >= 4 && (machO.contains(magic) || bitcode.contains(magic))
    }
    guard valid else { throw CleanupFailure("Unrecognized Xcode build file format.") }
  }
}
