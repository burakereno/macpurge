#if MACPURGE_PROFILE
  import AppKit
  import Foundation

  /// Included only in the local profiling build. The harness launches each
  /// sample as a separate .app process and supplies the monotonic start time.
  @MainActor enum StartupProbe {
    static var window: Double?
    static var result: Double?
    private static func elapsed() -> Double? {
      guard let raw = ProcessInfo.processInfo.environment["MACPURGE_PROFILE_START"],
        let start = UInt64(raw)
      else { return nil }
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func watchWindow() {
      Task { @MainActor in
        while window == nil {
          if NSApp.windows.contains(where: { $0.isVisible && $0.contentView?.frame.width ?? 0 > 0 })
          {
            window = elapsed()
            finish()
            return
          }
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
    }
    static func firstResult() {
      if result == nil {
        result = elapsed()
        finish()
      }
    }
    private static func finish() {
      guard let window, let result,
        let path = ProcessInfo.processInfo.environment["MACPURGE_PROFILE_OUTPUT"]
      else { return }
      try? JSONEncoder().encode(["window": window, "firstResult": result]).write(
        to: URL(fileURLWithPath: path), options: .atomic)
      NSApp.terminate(nil)
    }
  }
#endif
