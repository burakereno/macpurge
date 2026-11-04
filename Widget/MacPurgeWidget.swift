import SwiftUI
import WidgetKit

struct DiskEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
}
struct DiskProvider: TimelineProvider {
  func placeholder(in context: Context) -> DiskEntry { .init(date: .now, snapshot: nil) }
  func getSnapshot(in context: Context, completion: @escaping (DiskEntry) -> Void) {
    completion(.init(date: .now, snapshot: WidgetSnapshot.load()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<DiskEntry>) -> Void) {
    completion(
      .init(
        entries: [.init(date: .now, snapshot: WidgetSnapshot.load())],
        policy: .after(.now.addingTimeInterval(3600))))
  }
}

@main struct MacPurgeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "MacPurge.Disk", provider: DiskProvider()) { entry in
      VStack(alignment: .leading, spacing: 5) {
        Label("MacPurge", systemImage: "externaldrive").font(.caption.weight(.semibold))
        if let reading = entry.snapshot {
          Text(reading.free.map { $0.formatted(.byteCount(style: .file)) } ?? "—").font(
            .title.bold())
          Text("Free space").font(.caption)
          Text(reading.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
        } else {
          Text("Run a scan in MacPurge.").font(.callout)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
          Color(red: 0.12, green: 0.34, blue: 0.31).opacity(0.22)
        }
    }.configurationDisplayName("Disk summary").description("Results from the last completed MacPurge scan.")
      .supportedFamilies([.systemSmall, .systemMedium])
  }
}
