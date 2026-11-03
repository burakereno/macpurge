import SwiftUI

struct Overview: View {
    let demo: Demo
    @State private var showCoverage = false
    var body: some View {
        Page {
            PageTitle(kicker: "Çalışma alanı", title: "Genel bakış", subtitle: "Diskindeki alanın hangi projelere ve araçlara ait olduğunu gör.")
            DiskView(freeMB: demo.freeMB)
            if demo.trashMB > 0 {
                Button {
                    demo.show(.activity)
                } label: {
                    Label("\(diskAmount(demo.trashMB)) örnek Çöp’te bekliyor · Etkinliği gör", systemImage: "trash")
                }.buttonStyle(.link)
            }
            VStack(spacing: 10) {
                SectionHead(title: "Öne çıkanlar", note: "Örnek envanter")
                Surface {
                    VStack(spacing: 0) {
                        ActionRow(symbol: "hammer", tint: Ink.sea, title: "Atlas Studio", description: "Xcode projesi · yeniden üretilebilir çıktılar", amount: diskAmount(demo.availableMB), action: demo.openProject)
                        Divider().padding(.leading, 69)
                        ActionRow(symbol: "cube", tint: Ink.sky, title: "Laboratuvar VM", description: "Sanal makine · kişisel disk imajı", amount: "30 GB") { demo.path.append(.machine) }
                    }
                }
            }
            Surface {
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
            PageTitle(kicker: "Çalışma alanı", title: "Projeler", subtitle: "Bir projeyi seçerek kaynaklarıyla derleme çıktılarını birlikte incele.")
            Surface {
                ActionRow(symbol: "hammer", tint: Ink.sea, title: "Atlas Studio", description: "macOS uygulaması · Swift ve Xcode", amount: diskAmount(demo.availableMB), action: demo.openProject)
            }
        }
    }
}

struct Activity: View {
    let demo: Demo
    var body: some View {
        Page {
            PageTitle(kicker: "Çalışma alanı", title: "Etkinlik", subtitle: "Bu oturumdaki örnek işlemler ve sonuçları.")
            if demo.receipts.isEmpty {
                ContentUnavailableView("Henüz işlem yok", systemImage: "clock", description: Text("Bir işlem planı uyguladığında sonucunu burada görebilirsin."))
                    .padding(.vertical, 40).frame(maxWidth: .infinity)
                Button("Genel bakışa git") { demo.show(.overview) }
            } else {
                Surface {
                    VStack(spacing: 0) {
                        ForEach(demo.receipts) { receipt in
                            let status = receipt.restored ? "Geri alındı" : "Örnek Çöp’e taşındı"
                            ActionRow(symbol: receipt.restored ? "arrow.uturn.backward" : "trash", tint: Ink.sea, title: "Atlas Studio", description: "\(status) · \(receipt.date.formatted(date: .omitted, time: .shortened))", amount: diskAmount(receipt.mb)) { demo.path.append(.receipt(receipt.id)) }
                            if receipt.id != demo.receipts.last?.id { Divider().padding(.leading, 69) }
                        }
                    }
                }
            }
        }
    }
}

struct MachineDetail: View {
    var body: some View {
        Page {
            PageTitle(kicker: "Depolama / Sanal makineler", title: "Laboratuvar VM", subtitle: "Bu disk imajı işletim sistemini ve sanal makinedeki kişisel dosyaları içeriyor.")
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
    var body: some View {
        Page {
            PageTitle(kicker: "Depolama / Alan hedefi", title: "20 GB için adaylar", subtitle: "Yeniden üretilebilir çıktılar hedefin yalnızca bir kısmını karşılıyor.")
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
