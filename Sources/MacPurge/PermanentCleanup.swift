import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum CleanupCommand {
  static func run(_ executable: String, _ arguments: [String]) async throws -> String {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<String, any Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let task = Process()
          task.executableURL = URL(fileURLWithPath: executable)
          task.arguments = arguments
          task.standardInput = FileHandle.nullDevice
          let output = Pipe()
          task.standardError = output
          task.standardOutput = output
          try task.run()
          let data = output.fileHandleForReading.readDataToEndOfFile()
          task.waitUntilExit()
          let response = String(decoding: data, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
          guard task.terminationStatus == 0 else {
            throw NSError(
              domain: "MacPurge.CleanupCommand", code: Int(task.terminationStatus),
              userInfo: [
                NSLocalizedDescriptionKey: response.isEmpty
                  ? ReviewLanguage.text("macOS did not confirm the operation.") : response
              ])
          }
          continuation.resume(returning: response)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}

enum PermanentCleanup: Equatable, Sendable {
  case systemLogs
  case simulator(SimulatorDevice)

  var title: String {
    ReviewLanguage.text(self == .systemLogs ? "Clear System Logs" : "Erase Simulator")
  }
  var warning: String {
    switch self {
    case .systemLogs: ReviewLanguage.text(SystemLogStore.warning)
    case .simulator(let device):
      ReviewLanguage.format(
        "Erasing %@ permanently removes its installed apps, data, caches and settings. This cannot be undone. The simulator and its runtime stay installed.",
        device.name)
    }
  }
  var confirmation: String {
    switch self {
    case .systemLogs:
      ReviewLanguage.text(
        "Permanently clear the logs now? macOS will request administrator authorization. The logs cannot be restored from the Trash."
      )
    case .simulator(let device):
      ReviewLanguage.format(
        "Reset %@ to factory settings now? Its data cannot be recovered from the Trash.",
        device.name)
    }
  }
  var confirmButton: String {
    switch self {
    case .systemLogs: ReviewLanguage.text("Permanently Clear Logs")
    case .simulator(let device): ReviewLanguage.format("Erase %@", device.name)
    }
  }
}

@MainActor @Observable final class PermanentCleanupReview: Identifiable {
  enum Stage: Equatable {
    case review, confirmation, clearing
    case result(String)
  }
  let id = UUID()
  let reportID: UUID
  let itemID: String
  let operation: PermanentCleanup
  private(set) var stage = Stage.review

  init(reportID: UUID, itemID: String, operation: PermanentCleanup) {
    self.reportID = reportID
    self.itemID = itemID
    self.operation = operation
  }

  func acknowledge() {
    if stage == .review { stage = .confirmation }
  }

  func beginClearing() -> Bool {
    guard stage == .confirmation else { return false }
    stage = .clearing
    return true
  }

  func finish(_ message: String) { stage = .result(message) }
}

struct PermanentCleanupSheet: View {
  let review: PermanentCleanupReview
  let scan: LiveScan
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let operation = review.operation
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(operation.title, systemImage: operation == .systemLogs ? "doc.text" : "iphone")
          .font(.title2.bold())
        Spacer()
        SafetyBadge(level: .review)
      }
      if case .simulator(let device) = operation {
        VStack(alignment: .leading, spacing: 3) {
          Text(device.name).font(.headline)
          Text(device.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
      }
      switch review.stage {
      case .review:
        Text(operation.warning)
        HStack {
          Spacer()
          Button("Vazgeç") { dismiss() }
            .workspaceButton(.secondary)
            .keyboardShortcut(.cancelAction)
          Button("I Understand") { review.acknowledge() }
            .workspaceButton()
        }
      case .confirmation:
        Text(operation.confirmation)
        HStack {
          Spacer()
          Button("Vazgeç") { dismiss() }
            .workspaceButton(.secondary)
            .keyboardShortcut(.cancelAction)
          Button(operation.confirmButton, role: .destructive) {
            scan.cleanup.confirmPermanentCleanup(review, scan: scan)
          }
          .workspaceButton(.destructive)
        }
      case .clearing:
        HStack {
          WorkspaceActivityIndicator()
          Text(
            ReviewLanguage.text(
              operation == .systemLogs ? "Clearing system logs…" : "Erasing simulator…"))
        }
      case .result(let message):
        Text(message).textSelection(.enabled)
        HStack {
          Spacer()
          Button("Bitti") { dismiss() }
            .workspaceButton()
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(22).frame(width: 460, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .interactiveDismissDisabled(review.stage == .clearing)
  }
}
