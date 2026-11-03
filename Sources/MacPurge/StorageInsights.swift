import Charts
import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

struct FileAgeView: View {
  let age: FileAgeBreakdown
  let partial: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent("Son 72 saatte değişen", value: size(age.recent))
      LabeledContent("72 saatten eski", value: size(age.older))
      if partial {
        Text("Yalnızca okunabilen dosyalar dahil.").font(.caption).foregroundStyle(.secondary)
      }
    }.font(.callout)
  }
  private func size(_ bytes: Int64) -> String { (partial ? "≥ " : "") + byteLabel(bytes) }
}

struct WeeklyGrowthView: View {
  let report: ScanReport
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
            "\(trend.start.formatted(date: .abbreviated, time: .omitted)) – \(trend.end.formatted(date: .abbreviated, time: .omitted)) · \(trend.measuredDays) ölçüm günü"
          )
          .font(.caption).foregroundStyle(.secondary)
          if trend.comparableCategories == 0 {
            Text("İki tarihte de tam ölçülmüş kategori yok.").font(.callout)
          } else if trend.categories.isEmpty {
            Text("Karşılaştırılabilen kategorilerde net büyüme yok.").font(.callout)
          }
          ForEach(trend.categories.prefix(5)) { category in
            Surface {
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(
                    ReviewLanguage.text(
                      ScanGroup(rawValue: category.name)?.titleKey ?? category.name)
                  ).font(.headline)
                  Spacer()
                  Text("+" + byteLabel(category.change)).monospacedDigit()
                }
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
                if category.folders.isEmpty {
                  Text("Artış tek bir ölçülmüş klasöre bağlanamadı.").font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(category.folders) { folder in
                  HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                      Text(folder.item.name)
                      Text(folder.item.shortPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if folder.firstSeen {
                      Text("İlk ölçüm").font(.caption).foregroundStyle(.secondary)
                    }
                    Text((folder.firstSeen ? "" : "+") + byteLabel(folder.bytes)).monospacedDigit()
                  }.font(.callout)
                }
              }.padding(12)
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
