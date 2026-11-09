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
