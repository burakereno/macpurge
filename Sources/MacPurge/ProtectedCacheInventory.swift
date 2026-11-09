import Darwin
import Foundation

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// Read-only inventories for caches whose contents cannot be offered for cleanup.
enum ProtectedCacheInventory {
  static let coreDeviceRule = "coredevice.old-installation-record"
  static let telegramRule = "telegram.media-cache"
  static let coreDevicePath =
    "Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas"
  static let telegramPath = "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"

  private static let coreTitle = "Older CoreDevice installation cache"
  private static let coreNote =
    "Records at least 14 days old. The newest record for each app and device is retained. Installation use cannot be ruled out."
  private static let telegramTitle = "Telegram media cache"
  private static let telegramNote =
    "Cached media can include local copies from secret chats. Manage this data in Telegram."

  private struct Record {
    let url: URL
    let deviceID: UUID
    var latest = 0
    var bytes: Int64 = 0
    var privateBytes: Int64? = 0
  }

  static func coreDevice(home: URL, volumes: ScanVolumes, now: Date = .now) throws -> [ScanRoot] {
    let base = home.appending(path: coreDevicePath)
    guard let device = volumes.device(for: base), !ScanExclusions.current.contains(base) else { return [] }
    let threshold = Int(now.timeIntervalSince1970) - 14 * 86_400
    let apps: [URL]
    do { apps = try directories(base, device: device) }
    catch is CancellationError { throw CancellationError() }
    catch { return [coreRow(base, source: .status("Protected cache could not be read."))] }
    var rows: [ScanRoot] = []
    for app in apps where
      app.lastPathComponent.wholeMatch(of: /[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/) != nil
    {
      // If one record for an app cannot be measured, keep the app out of this
      // breakdown rather than guessing which record is newest.
      var records: [Record] = []
      do {
        for build in try DirectoryIndex.children(of: app, onDevice: device, rejectUnsupported: true)
          where build.directory && build.url.lastPathComponent.wholeMatch(of: /[a-fA-F0-9]{64}/) != nil
        {
          for entry in try DirectoryIndex.children(of: build.url, onDevice: device, rejectUnsupported: true)
            where entry.directory
          {
            guard let id = UUID(uuidString: entry.url.lastPathComponent),
              !ScanExclusions.current.overlaps(entry.url) else { throw DirectoryIndex.Problem(code: EINVAL) }
            var record = Record(url: entry.url, deviceID: id)
            try measure(entry.url, device: device, record: &record)
            records.append(record)
          }
        }
      } catch is CancellationError { throw CancellationError() }
      catch { continue }
      let newest = Dictionary(grouping: records, by: \.deviceID).mapValues { $0.map(\.latest).max() ?? 0 }
      for record in records where record.latest <= threshold && record.latest < newest[record.deviceID, default: 0] {
        try Task.checkCancellation()
        let snapshot: CacheSnapshot
        do {
          snapshot = try TrashFiles.snapshot(record.url, on: device, fingerprint: false, appCache: true)
        } catch is CancellationError { throw CancellationError() }
        catch { continue }
        guard record.bytes == snapshot.bytes else { continue }
        var row = coreRow(record.url)
        if let privateBytes = record.privateBytes {
          row.evidence?.privateAllocation = .init(allocated: record.bytes, privateBytes: privateBytes)
        }
        rows.append(row)
      }
    }
    return rows
  }

  private static func coreRow(_ url: URL, source: MeasurementSource = .directory) -> ScanRoot {
    var row = ScanRoot(group: .tools, title: coreTitle, url: url, profile: .systemManaged, source: source)
    row.evidence = .init(owner: "CoreDevice", kind: .build, rule: coreDeviceRule)
    row.evidence?.note = coreNote
    return row
  }

  private static func measure(_ url: URL, device: dev_t, record: inout Record) throws {
    try TrashFiles.directory(url, enumerate: false) { _, info in
      try verify(info, device: device, record: &record)
    }
    for entry in try DirectoryIndex.children(of: url, onDevice: device, rejectUnsupported: true) {
      if entry.directory {
        try measure(entry.url, device: device, record: &record)
      } else {
        try FileComparison.read(entry.url) { fd, info in
          try verify(info, device: device, record: &record)
          guard info.st_nlink == 1 else { throw DirectoryIndex.Problem(code: EMLINK) }
          let bytes = Int64(info.st_blocks) * 512
          record.bytes += bytes
          if bytes > 0, let previous = record.privateBytes {
            record.privateBytes = FileComparison.privateAllocatedBytes(fd).map { previous + min(bytes, $0) }
          }
        }
      }
    }
  }

  private static func verify(_ info: stat, device: dev_t, record: inout Record) throws {
    guard info.st_dev == device, info.st_uid == getuid(),
      info.st_flags & UInt32(SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE | SF_NOUNLINK | UF_APPEND | SF_APPEND) == 0
    else { throw DirectoryIndex.Problem(code: EACCES) }
    record.latest = max(record.latest, info.st_mtimespec.tv_sec, info.st_ctimespec.tv_sec,
      info.st_birthtimespec.tv_sec)
  }

  static func telegram(home: URL, volumes: ScanVolumes, apps: [ApplicationIdentity]) throws -> [ScanRoot] {
    let base = home.appending(path: telegramPath)
    guard let device = volumes.device(for: base) else { return [] }
    let app = apps.first { $0.bundleID == "ru.keepcoder.Telegram" }
    var accounts: [URL]
    do {
      let children = try directories(base, device: device)
      accounts = children.filter { $0.lastPathComponent.hasPrefix("account-") }
      for channel in children where !channel.lastPathComponent.hasPrefix("account-") {
        accounts += try directories(channel, device: device).filter { $0.lastPathComponent.hasPrefix("account-") }
      }
    } catch is CancellationError { throw CancellationError() }
    catch { return [telegramRow(base, app: app, source: .status("Protected cache could not be read."))] }
    return try accounts.compactMap { account in
      try Task.checkCancellation()
      let media = account.appending(path: "postbox/media")
      guard !ScanExclusions.current.contains(media),
        (try? TrashFiles.directory(media, enumerate: false, { _, info in
          info.st_dev == device && info.st_uid == getuid()
        })) == true else { return nil }
      return telegramRow(media, app: app)
    }
  }

  private static func telegramRow(_ url: URL, app: ApplicationIdentity?,
                                  source: MeasurementSource = .directory) -> ScanRoot {
    var row = ScanRoot(group: .appCaches, title: telegramTitle, url: url, profile: .systemManaged, source: source)
    row.evidence = .init(owner: "Telegram", kind: .applicationData, rule: telegramRule)
    row.evidence?.note = telegramNote
    row.application = app
    return row
  }

  private static func directories(_ url: URL, device: dev_t) throws -> [URL] {
    do {
      return try DirectoryIndex.children(of: url, onDevice: device)
        .filter { $0.directory && !$0.url.lastPathComponent.hasPrefix(".") }.map(\.url)
    } catch let error as DirectoryIndex.Problem where error.code == ENOENT { return [] }
  }
}
