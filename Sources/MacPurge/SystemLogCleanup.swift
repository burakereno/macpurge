import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum SystemLogStore {
  static let path = "/private/var/db/diagnostics"
  static let textArchive = "/private/var/db/uuidtext"
  static let warning =
    "This permanently erases the unified system logs for this Mac. Past log entries used to diagnose problems will be lost. This cannot be undone."

  static func action(for row: ReportItem) -> CleanupAction? {
    guard row.path == path, row.category == ScanGroup.logs.rawValue, row.basis == "allocated",
      row.complete || row.status == "partial", let bytes = row.bytes, bytes > 0
    else { return nil }
    return .permanent(.systemLogs, bytes: bytes)
  }

  // No path, text from inventory, credential, or other user input reaches this command.
  static let script = """
    try
      do shell script "/usr/bin/log erase --all" with prompt "MacPurge wants to permanently clear the unified system logs." with administrator privileges
    on error number -128
      return "cancelled"
    end try
    return "cleared"
    """

  static func erase() async throws {
    let response = try await CleanupCommand.run("/usr/bin/osascript", ["-e", script])
    if response == "cancelled" { throw CancellationError() }
    guard response == "cleared" else { throw CleanupFailure("macOS did not confirm the operation.") }
  }
}
