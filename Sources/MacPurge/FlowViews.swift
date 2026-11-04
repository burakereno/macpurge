import SwiftUI

struct ProjectDetail: View {
    let demo: Demo
    var body: some View {
        Page {
            PageTitle(kicker: "Projeler / Xcode", title: "Atlas Studio", subtitle: "macOS uygulaması · Son derleme 12 gün önce")
            Surface {
                HStack(spacing: 13) {
                    SymbolTile(symbol: "folder", tint: Ink.sky)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kaynak kod").font(.headline)
                        Text("~/Projects/AtlasStudio").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Label("Korunur", systemImage: "lock.fill").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.padding(17)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionHead(title: "Derleme çıktıları", note: diskAmount(demo.availableMB))
                InventoryList(Output.atlas.sorted { $0.mb > $1.mb }) { output in
                    OutputChoice(output: output, demo: demo)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { selectionSummary; Spacer(); reviewButton }
                VStack(alignment: .leading, spacing: 12) { selectionSummary; reviewButton }
            }
        }
    }
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(demo.draft.count) çıktı seçildi").font(.headline)
            Text("\(diskAmount(demo.draftMB)) işlem planına eklenecek.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var reviewButton: some View {
        MainAction(title: "İşlem planını incele", symbol: "list.bullet.clipboard", action: demo.review)
            .disabled(demo.draft.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
    }
}

private struct OutputChoice: View {
    let output: Output
    let demo: Demo
    @State private var expanded = false
    var body: some View {
        let moved = demo.moved.contains(output.id)
        InventoryDisclosure(isExpanded: $expanded, selectable: [], selected: .constant([]),
            busy: moved, selectionHelp: output.name,
            selection: Binding(get: { demo.selection.contains(output.id) }, set: { _ in demo.toggle(output) })) {
            Text(output.location).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).padding(.leading, InventoryLayout.detailIndent)
                .padding(.vertical, InventoryLayout.verticalPadding)
        } label: {
            InventoryGroupHeader(title: ReviewLanguage.text(output.name), symbol: "doc", tint: Ink.sea,
                amount: diskAmount(output.mb), subtitle: ReviewLanguage.text(moved ? "Örnek Çöp’te" : output.effect)) {
                SafetyBadge(level: .safe)
            }
        } accessory: { EmptyView() }
    }
}

struct Review: View {
    let demo: Demo
    var body: some View {
        Page {
            PageTitle(kicker: "Proje / Önizleme", title: "İşlem planı", subtitle: "Seçtiğin çıktılar örnek Çöp’e taşınacak. İşlemi sonuç ekranından geri alabilirsin.")
            VStack(alignment: .leading, spacing: 14) {
                SectionHead(title: "Çöp’e taşınacaklar", note: ReviewLanguage.format("%lld çıktı", Int64(demo.draft.count)))
                InventoryList(demo.draft.sorted { $0.mb > $1.mb }) { item in
                    InventoryReadout(title: ReviewLanguage.text(item.name), amount: diskAmount(item.mb), symbol: "doc")
                }
                HStack {
                    Text("Toplam").font(.headline)
                    Spacer()
                    InventoryAmount(text: diskAmount(demo.draftMB), prominent: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Note(symbol: "lock", text: "Atlas Studio’nun kaynak kodu proje klasöründe kalır.")
                Note(symbol: "internaldrive", text: "Çöp boşaltılana kadar diskte açılacak alan 0 GB.")
            }
            HStack {
                Button("Seçime dön") { _ = demo.path.popLast() }
                Spacer()
                MainAction(title: "Örnek Çöp’e taşı", symbol: "trash", action: demo.apply)
                    .disabled(demo.draft.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

struct ResultView: View {
    let receipt: Receipt
    let demo: Demo
    var body: some View {
        Page {
            PageTitle(kicker: "Proje / İşlem sonucu", title: receipt.restored ? "İşlem geri alındı" : "İşlem tamamlandı",
                      subtitle: receipt.restored ? "Seçtiğin çıktılar örnek projedeki yerlerine döndü." : ReviewLanguage.format("%lld derleme çıktısı örnek Çöp’e taşındı.", Int64(receipt.outputs.count)))
            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    Label(receipt.restored ? "Yerine dönen" : "Çöp’e taşınan", systemImage: receipt.restored ? "arrow.uturn.backward" : "trash")
                        .font(.headline).foregroundStyle(.secondary)
                    Text(diskAmount(receipt.mb)).font(.system(size: 38, weight: .semibold)).monospacedDigit()
                    Divider()
                    HStack { Label("Diskte açılan alan", systemImage: "internaldrive"); Spacer(); Text("0 GB").font(.headline) }
                    Note(symbol: "info.circle", text: receipt.restored ? "Geri alınan çıktılar tekrar seçilebilir." : "Çöp hâlâ aynı diskte yer kaplıyor. Boş alan 76,4 GB olarak kaldı.")
                }.padding(20)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHead(title: "İşlenen çıktılar")
                InventoryList(receipt.outputs.sorted { $0.mb > $1.mb }) { output in
                    InventoryReadout(title: ReviewLanguage.text(output.name), amount: diskAmount(output.mb), symbol: "checkmark")
                }
            }
            HStack {
                if !receipt.restored {
                    Button("Geri al") { demo.restore(receipt.id) }.controlSize(.large)
                }
                Spacer()
                MainAction(title: "Genel bakışa dön", symbol: "square.grid.2x2") { demo.show(.overview) }
            }
        }
    }
}
