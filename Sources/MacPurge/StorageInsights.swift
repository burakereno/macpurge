import Charts
import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct FileAgeView: View {
  let age: FileAgeBreakdown
  let partial: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      InventoryRows([("Son 72 saatte değişen", age.recent), ("72 saatten eski", age.older)],
        id: \.0) { title, bytes in
        InventoryReadout(title: ReviewLanguage.text(title), amount: size(bytes), symbol: "clock")
      }
      if partial {
        Text("Yalnızca okunabilen dosyalar dahil.").font(.caption).foregroundStyle(.secondary)
          .padding(.leading, InventoryLayout.detailIndent)
          .padding(.vertical, InventoryLayout.verticalPadding)
      }
    }.font(.callout)
  }
  private func size(_ bytes: Int64) -> String { (partial ? "≥ " : "") + byteLabel(bytes) }
}

struct WeeklyGrowthView: View {
  let scan: LiveScan
  let report: ScanReport
  @Binding var selected: Set<String>
  @State private var trend: WeeklyGrowth?
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      SectionHead(title: "Son 7 günde büyüyen kategoriler")
      if let trend {
        if trend.measuredDays < 2 {
          Text(
            "Haftalık eğilim için son 7 günde, en az iki farklı günde aynı kapsamda tarama gerekiyor."
          )
          .font(.callout).foregroundStyle(.secondary)
        } else {
          Text(
            "\(trend.start.reviewDate(date: .abbreviated, time: .omitted)) – \(trend.end.reviewDate(date: .abbreviated, time: .omitted)) · \(trend.measuredDays) ölçüm günü"
          )
          .font(.caption).foregroundStyle(.secondary)
          if trend.comparableCategories == 0 {
            Text("İki tarihte de tam ölçülmüş kategori yok.").font(.callout)
          } else if trend.categories.isEmpty {
            Text("Karşılaştırılabilen kategorilerde net büyüme yok.").font(.callout)
          }
          InventoryList(Array(trend.categories.prefix(5))) { category in
              VStack(alignment: .leading, spacing: 0) {
                let group = ScanGroup(rawValue: category.name)
                InventoryReadout(title: ReviewLanguage.text(group?.titleKey ?? category.name),
                  amount: "+" + byteLabel(category.change), symbol: group?.symbol ?? "chart.bar",
                  tint: group?.tint ?? Ink.sea)
                Chart(category.samples) { point in
                  BarMark(
                    x: .value("Tarih", point.date, unit: .day),
                    y: .value("Boyut", Double(point.bytes) / 1e9)
                  )
                  .foregroundStyle(Ink.sea)
                }.chartXScale(
                  domain: Calendar.current.startOfDay(
                    for: trend.start)...(Calendar.current.dateInterval(of: .day, for: trend.end)?
                    .end ?? trend.end)
                )
                .chartYAxisLabel("GB").frame(height: 80)
                  .padding(.horizontal, InventoryLayout.detailIndent)
                  .padding(.vertical, InventoryLayout.verticalPadding)
                if category.folders.isEmpty {
                  Text("Artış tek bir ölçülmüş klasöre bağlanamadı.").font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, InventoryLayout.detailIndent)
                    .padding(.vertical, InventoryLayout.verticalPadding)
                }
                InventoryRows(category.folders) { folder in
                    if scan.report?.id == report.id {
                      InventoryMeasuredRow(scan: scan, item: folder.item, selected: $selected,
                        amount: folder.item.bytes.map(byteLabel),
                        delta: folder.firstSeen ? nil : folder.bytes)
                    } else {
                      InventoryReadout(title: folder.item.actionTitle,
                        amount: (folder.firstSeen ? "" : "+") + byteLabel(folder.bytes),
                        subtitle: folder.item.shortPath)
                    }
                }.padding(.leading, InventoryLayout.nestedIndent)
              }
          }
        }
      } else if let failure {
        Text(failure).font(.callout)
      } else {
        ProgressView().controlSize(.small)
      }
    }.task(id: report.id) {
      trend = nil
      failure = nil
      do {
        let reading = try await HistoryIO.shared.weeklyGrowth(ending: report)
        try Task.checkCancellation()
        trend = reading
      } catch {
        if !Task.isCancelled { failure = ReviewLanguage.text("Haftalık ölçümler okunamadı.") }
      }
    }
  }
}
