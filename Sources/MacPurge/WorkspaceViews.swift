import SwiftUI
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

struct Overview: View {
    let demo: Demo
    @State private var showCoverage = false
    var body: some View {
        Page(overviewLayout: true) {
            PageTitle(title: "Genel bakış")
        } content: {
            let disk = VolumeReading(name: "Macintosh HD", bytes: 512_000_000_000,
                free: Int64(demo.freeMB) * 1_000_000)
            let safe = Int64(demo.availableMB) * 1_000_000
            DiskBreakdownView(disk: disk, breakdown: DiskBreakdown(reading: disk,
                sizes: [.xcode: .bytes(safe, lowerBound: false),
                    .machines: .bytes(30_000_000_000, lowerBound: false)],
                safeBytes: safe, safeByGroup: [.xcode: safe]))
            if let receipt = demo.receipts.first(where: { !$0.restored }) {
                Button {
                    demo.path.append(.receipt(receipt.id))
                } label: {
                    Label("\(diskAmount(demo.trashMB)) örnek Çöp’te bekliyor · Son işlemi gör", systemImage: "trash")
                }.buttonStyle(.link)
            }
            VStack(spacing: 10) {
                SectionHead(title: "Öne çıkanlar", note: "Örnek envanter")
                InventoryList(["project", "machine"], id: \.self) { item in
                    if item == "project" {
                        ActionRow(symbol: "hammer", tint: Ink.sea, title: "Atlas Studio",
                            description: "Xcode projesi · yeniden üretilebilir çıktılar",
                            amount: diskAmount(demo.availableMB), action: demo.openProject)
                    } else {
                        ActionRow(symbol: "cube", tint: Ink.sky, title: "Laboratuvar VM",
                            description: "Sanal makine · kişisel disk imajı", amount: "30 GB") {
                            demo.path.append(.machine)
                        }
                    }
                }
            }
            InventoryList(["goal"], id: \.self) { _ in
                ActionRow(symbol: "scope", tint: Ink.gold, title: "20 GB alan hedefi", description: "Mevcut adayların hedefi ne kadar karşıladığını gör.", amount: "") { demo.path.append(.goal) }
            }
            DisclosureGroup(isExpanded: $showCoverage) {
                Text("Uygulama kapsayıcıları için erişim kısıtlı. Bu konumun boyutu bilinmiyor ve önerilere dahil edilmiyor.")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            } label: { Label("1 konum ölçülemedi", systemImage: "lock").font(.callout) }
                .foregroundStyle(.secondary)
        }
    }
}

struct Projects: View {
    let demo: Demo
    var body: some View {
        Page {
            PageTitle(title: "Projeler")
        } content: {
            InventoryList(["project"], id: \.self) { _ in
                ActionRow(symbol: "hammer", tint: Ink.sea, title: "Atlas Studio", description: "macOS uygulaması · Swift ve Xcode", amount: diskAmount(demo.availableMB), action: demo.openProject)
            }
        }
    }
}

struct MachineDetail: View {
    let back: () -> Void

    var body: some View {
        Page {
            PageTitle(title: "Laboratuvar VM") {
                WorkspaceBackButton(title: "Back", action: back)
            }
        } content: {
            Surface {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Sanal makine diski", systemImage: "cube").font(.headline)
                    Text("30 GB").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                    Text("~/Virtual Machines/Laboratuvar.utm").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Divider()
                    Note(symbol: "lock", text: "Korumalı öğe. Bu imaj bir temizlik planına eklenemez.")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }
}

struct Goal: View {
    let demo: Demo
    let back: () -> Void

    var body: some View {
        Page {
            PageTitle(title: "20 GB için adaylar") {
                WorkspaceBackButton(title: "Back", action: back)
            }
        } content: {
            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Uygun aday").font(.headline)
                        Spacer()
                        Text("\(diskAmount(demo.availableMB)) / 20 GB").font(.headline).monospacedDigit()
                    }
                    ProgressView(value: Double(demo.availableMB), total: 20_000).tint(Ink.sea)
                        .accessibilityLabel("Hedefe uygun aday boyutu")
                    Text("\(diskAmount(20_000 - demo.availableMB)) daha gerekiyor. Laboratuvar VM kişisel veri içerdiği için hedefin dışında.")
                        .foregroundStyle(.secondary)
                }.padding(20)
            }
            if !demo.available.isEmpty {
                MainAction(title: "Atlas Studio’yu incele", symbol: "arrow.right", action: demo.openProject)
            } else { Note(symbol: "checkmark.circle", text: "Bu örnekte planlanabilecek başka derleme çıktısı kalmadı.") }
        }
    }
}
