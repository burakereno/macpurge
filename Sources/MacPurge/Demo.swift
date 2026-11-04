import Foundation
import Observation

enum Workspace: String, Identifiable {
    case overview = "Genel bakış"
    case projects = "Projeler"
    case activity = "Etkinlik"
    case settings = "Ayarlar"
    static let destinations: [Self] = [.overview, .projects, .activity]
    var id: Self { self }
    var symbol: String {
        switch self {
        case .settings: "gearshape"
        case .overview: "square.grid.2x2"
        case .projects: "folder"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

enum Destination: Hashable { case project, machine, plan, goal, receipt(UUID) }

struct Output: Identifiable, Hashable {
    let id: String
    let name: String
    let location: String
    let effect: String
    let mb: Int
    static let atlas = [
        Output(id: "data", name: "Derleme verileri", location: "~/Library/Developer/Xcode/DerivedData/AtlasStudio/Build", effect: "Xcode sonraki derlemede bu çıktıları yeniden üretir.", mb: 5600),
        Output(id: "index", name: "Kod dizini", location: "~/Library/Developer/Xcode/DerivedData/AtlasStudio/Index.noindex", effect: "Kod tamamlama, Xcode dizini yeniden oluşturunca hazır olur.", mb: 1600),
        Output(id: "previews", name: "Önizleme çıktıları", location: "~/Library/Developer/Xcode/DerivedData/AtlasStudio/Previews", effect: "İlk SwiftUI önizlemesi biraz daha geç açılır.", mb: 800)
    ]
}

func diskAmount(_ mb: Int) -> String {
    if mb == 0 { return "0 GB" }
    if mb < 1000 { return "\(mb) MB" }
    let value = (Double(mb) / 1000).formatted(.number.locale(ReviewLanguage.locale(ReviewLanguage.current)).precision(.fractionLength(0...1)))
    return "\(value) GB"
}

struct Receipt: Identifiable {
    let id = UUID()
    let date = Date()
    let outputs: [Output]
    var restored = false
    var mb: Int { outputs.reduce(0) { $0 + $1.mb } }
}

/// Entirely in memory. The paths identify fictional entries for display.
@MainActor @Observable final class Demo {
    var workspace: Workspace = .overview
    var path: [Destination] = []
    var selection: Set<String> = []
    var receipts: [Receipt] = []
    var freeMB: Int { 76_400 }
    var moved: Set<String> { Set(receipts.filter { !$0.restored }.flatMap { $0.outputs.map(\.id) }) }
    var available: [Output] { Output.atlas.filter { !moved.contains($0.id) } }
    var draft: [Output] { available.filter { selection.contains($0.id) } }
    var availableMB: Int { available.reduce(0) { $0 + $1.mb } }
    var draftMB: Int { draft.reduce(0) { $0 + $1.mb } }
    var trashMB: Int { receipts.filter { !$0.restored }.reduce(0) { $0 + $1.mb } }

    func show(_ section: Workspace) {
        workspace = section
        path = []
    }

    func openProject() {
        selection = Set(available.map(\.id))
        path.append(.project)
    }

    func toggle(_ output: Output) {
        guard !moved.contains(output.id) else { return }
        if selection.contains(output.id) { selection.remove(output.id) }
        else { selection.insert(output.id) }
    }

    func review() {
        guard !draft.isEmpty else { return }
        path.append(.plan)
    }

    func apply() {
        guard path.last == .plan, !draft.isEmpty else { return }
        let receipt = Receipt(outputs: draft)
        receipts.insert(receipt, at: 0)
        selection = []
        path = [.receipt(receipt.id)]
    }

    func restore(_ id: UUID) {
        guard let i = receipts.firstIndex(where: { $0.id == id && !$0.restored }) else { return }
        receipts[i].restored = true
    }

    func reset() {
        receipts = []
        selection = []
        show(.overview)
    }
}
