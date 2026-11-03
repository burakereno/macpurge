import Foundation

enum ExternalProjects {
  @concurrent static func suggestions() async -> [URL] {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [
      .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
      .volumeNameKey,
    ]
    let volumes =
      fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: .skipHiddenVolumes)
      ?? []
    var result: [URL] = []
    for volume in volumes where volume.path.hasPrefix("/Volumes/") {
      guard !Task.isCancelled, let facts = try? volume.resourceValues(forKeys: keys),
        facts.volumeIsLocal == true, facts.volumeIsInternal == false,
        facts.volumeIsReadOnly == false,
        facts.volumeIsRootFileSystem == false,
        !(facts.volumeName ?? "").localizedCaseInsensitiveContains("Time Machine"),
        !fm.fileExists(atPath: volume.appending(path: "Backups.backupdb").path),
        !fm.fileExists(atPath: volume.appending(path: ".com.apple.timemachine.donotpresent").path)
      else { continue }
      for folder in ["Developer", "Projects", "Projeler", "Code", "dev"] {
        let candidate = volume.appending(path: folder)
        let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isDirectory == true && values?.isSymbolicLink == false {
          result.append(candidate)
        }
      }
    }
    return result.sorted { $0.path < $1.path }
  }
}
