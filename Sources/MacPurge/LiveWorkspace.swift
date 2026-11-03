import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

enum LiveSection: Hashable { case overview, storage, projects, plan, activity }

struct LiveWorkspace: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.scenePhase) private var scenePhase
  let scan: LiveScan
  @Binding var section: LiveSection
  @State private var selectedIDs: Set<String> = []

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 9) {
          LayerMark().frame(width: 26, height: 29)
          Text("MacPurge").font(.system(size: 19, weight: .bold)).tracking(-0.7)
        }.padding(.leading, 18).padding(.top, 13).padding(.bottom, 19)
        List(
          selection: Binding<LiveSection?>(
            get: { section }, set: { if let value = $0 { section = value } })
        ) {
          Section("Çalışma alanı") {
            Label("Genel bakış", systemImage: "square.grid.2x2").tag(LiveSection.overview)
            Label("Depolama", systemImage: "externaldrive").tag(LiveSection.storage)
            Label("Proje klasörleri", systemImage: "folder").tag(LiveSection.projects)
            Label("Alan planı", systemImage: "scope").tag(LiveSection.plan)
            Label("Etkinlik", systemImage: "clock.arrow.circlepath").tag(LiveSection.activity)
          }
        }.listStyle(.sidebar)
        Label("Önizlemeli temizlik", systemImage: "checkmark.shield")
          .font(.callout.weight(.medium)).foregroundStyle(.secondary)
          .padding(.leading, 18).padding(.bottom, 19)
      }
      .navigationSplitViewColumnWidth(min: 165, ideal: 194, max: 230)
    } detail: {
      Group {
        switch section {
        case .overview: LiveOverview(scan: scan, openStorage: { section = .storage })
        case .storage:
          StorageBrowser(scan: scan, selected: $selectedIDs, openPlan: { section = .plan })
        case .projects:
          ProjectRootsView(scan: scan) { item in
            selectedIDs.insert(item.id)
            section = .plan
          }
        case .plan: SpacePreview(scan: scan, selected: $selectedIDs)
        case .activity: ScanActivity(scan: scan)
        }
      }
      .navigationTitle("MacPurge")
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button(action: scan.chooseProjects) {
            Label("Proje klasörü seç", systemImage: "folder.badge.plus")
          }
          .help("Ölçülecek proje klasörlerini seç")
          if scan.phase == .running {
            Button(action: scan.cancel) { Label("Taramayı durdur", systemImage: "stop.circle") }
              .help("Taramayı durdur")
          } else {
            Button(action: scan.start) { Label("Yeniden tara", systemImage: "arrow.clockwise") }
              .help("Tüm konumları yeniden ölç")
          }
          Menu {
            Button("Hızlı tarama", action: scan.startQuick)
            Button("Ayrıntılı tarama", action: scan.startDetailed)
            Divider()
            Button("JSON dışa aktar…", action: scan.exportReport).disabled(scan.report == nil)
          } label: {
            Label("Tarama kapsamı", systemImage: "slider.horizontal.3")
          }
          .help("Tarama kapsamı")
        }
      }
    }
    .tint(Ink.sea)
    .onAppear {
      NoticeDelegate.showActivity = {
        section = .activity
        openWindow(id: "workspace")
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    .task { if scan.phase == .idle { scan.start() } }
    .task(id: eligibilityRequest) {
      guard eligibilityRequest != nil else { return }
      await scan.refreshMoveStates()
      if !Task.isCancelled, !scan.moveStates.isEmpty {
        selectedIDs = selectedIDs.filter {
          scan.moveStates[$0] == .ready && !scan.hiddenIDs.contains($0)
        }
      }
    }
  }
  private var eligibilityRequest: UUID? {
    guard [.storage, .projects, .plan].contains(section), scan.phase == .finished,
      scenePhase == .active
    else { return nil }
    return scan.report?.id
  }
}

private struct LiveOverview: View {
  let scan: LiveScan
  let openStorage: () -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var expanded: Set<ScanGroup> = [.projects]

  var body: some View {
    Page {
      PageTitle(
        kicker: "Çalışma alanı", title: "Genel bakış",
        subtitle: "Mac’indeki araçların, uygulamaların ve seçtiğin projelerin depolama ölçümleri.")
      if let disk = scan.volume {
        DiskView(reading: disk)
      } else if scan.phase == .finished {
        Note(symbol: "internaldrive", text: "Disk kapasitesi okunamadı.")
      }
      VStack(alignment: .leading, spacing: 12) {
        if let report = scan.report {
          OverviewHighlights(
            report: report,
            previous: report.previous(in: scan.history),
            openStorage: openStorage)
        }
        HStack(spacing: 12) {
          SectionHead(title: "Ölçülen alanlar")
          ForEach(SafetyLevel.allCases, id: \.self) { level in
            Label(ReviewLanguage.text(level.rawValue), systemImage: level.symbol)
              .font(.caption.weight(.semibold)).foregroundStyle(level.color(in: scheme))
              .fixedSize()
          }
        }
        ScanStatus(scan: scan)
        Surface {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleGroups, id: \.self) { group in
              ScanGroupView(
                group: group, scan: scan,
                isExpanded: Binding(
                  get: { expanded.contains(group) },
                  set: { if $0 { expanded.insert(group) } else { expanded.remove(group) } }
                ))
              if group != visibleGroups.last { Divider().padding(.leading, 32) }
            }
          }.padding(.horizontal, SurfaceCorners.rowInset)
        }
        if let note = scan.selectionNote { Note(symbol: "folder", text: note) }
        Text(
          "Boyutlar diskte ayrılan alanı gösterir. Bir klasör birden fazla grubun kapsamında olabilir."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var visibleGroups: [ScanGroup] {
    if scan.detailed { return ScanGroup.allCases }
    return ScanGroup.allCases.filter { group in
      [.xcode, .simulators, .packages, .projects, .logs].contains(group)
        || scan.roots.contains(where: { $0.group == group })
    }
  }
}

private struct ScanStatus: View {
  let scan: LiveScan
  var body: some View {
    HStack(spacing: 8) {
      if scan.phase == .running {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: scan.phase == .finished ? "checkmark.circle" : "pause.circle")
      }
      switch scan.phase {
      case .idle: Text("Tarama hazırlanıyor")
      case .running:
        Text(
          "\(scan.results.count)/\(scan.roots.count) konum · \(scan.activeRoot?.title ?? "Hazırlanıyor")"
        )
      case .cancelled:
        Text("Durduruldu · \(scan.results.count)/\(scan.roots.count) konum tamamlandı")
      case .finished:
        if let date = scan.measuredAt {
          Text(
            "Son ölçüm \(date.formatted(date: .omitted, time: .shortened)) · \(scan.results.count) konum kontrol edildi"
          )
        }
      }
    }.font(.callout).foregroundStyle(.secondary)
  }
}

extension ScanGroup {
  var symbol: String {
    switch self {
    case .xcode: "hammer"
    case .simulators: "iphone"
    case .packages: "shippingbox"
    case .projects: "folder"
    case .logs: "doc.text"
    case .runtimes: "square.stack.3d.up"
    case .models: "cpu"
    case .tools: "wrench"
    case .temp: "hourglass"
    case .docker: "shippingbox"
    case .machines: "desktopcomputer"
    case .trash: "trash"
    case .backups: "iphone.and.arrow.forward"
    case .shared: "person.2"
    case .android: "apps.iphone"
    case .apps: "app"
    case .system: "gearshape"
    case .other: "folder.badge.questionmark"
    case .snapshots: "clock.arrow.circlepath"
    }
  }
  var tint: Color {
    switch self {
    case .packages, .logs, .temp: Ink.gold
    case .simulators, .projects, .models, .machines: Ink.sky
    default: Ink.sea
    }
  }
  var detail: String {
    switch self {
    case .xcode: "Derleme çıktıları, arşivler ve aygıt desteği"
    case .simulators: "Cihaz başına yerel veriler ve önbellekler"
    case .packages: "Paket yöneticilerinin bilinen yerel depoları"
    case .projects: "Seçtiğin klasörlerin tamamı"
    case .logs: "Kullanıcı günlükleri ve tanılama raporları"
    case .models: "Model ağırlıkları, yerel imajlar ve yapay zekâ araçları"
    case .android: "SDK, emülatörler ve Android Studio"
    case .apps: "Uygulama desteği, önbellekler ve medya kitaplıkları"
    case .tools: "Editörler, eklentiler ve geliştirme ortamları"
    case .runtimes: "Cihazlardan ayrı, yüklü simülatör imajları"
    case .other: "Araç konumlarında ve seçtiğin klasörlerde 500 MiB ve üzeri alt klasörler"
    case .temp: "macOS’un geçici dosya ve önbellek klasörleri"
    case .system: "Sistem önbellekleri, destek dosyaları ve komut satırı araçları"
    default: "Yerel envanter ve ölçüm kapsamı"
    }
  }
}

private struct DisclosureRowStyle: ButtonStyle {
  let compact: Bool
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    let hoverOpacity = isHovered ? 0.05 : 0
    return configuration.label.background {
      RoundedRectangle(cornerRadius: compact ? 6 : SurfaceCorners.rowRadius, style: .continuous)
        .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : hoverOpacity))
        .padding(.vertical, compact ? 0 : SurfaceCorners.rowInset)
    }
  }
}

private struct OverviewDisclosure<Content: View, RowLabel: View>: View {
  @Binding var isExpanded: Bool
  var compact = false
  @ViewBuilder let content: Content
  @ViewBuilder let label: RowLabel
  @State private var hovering = false
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        focused = true
        isExpanded.toggle()
      } label: {
        HStack(spacing: 7) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovering || focused ? .primary : .secondary)
            .frame(width: 12).accessibilityHidden(true)
          label
        }
        .padding(.horizontal, 9).padding(.vertical, compact ? 5 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(DisclosureRowStyle(compact: compact, isHovered: hovering))
      .focusable()
      .focusEffectDisabled()
      .focused($focused)
      .onHover { hovering = $0 }
      .onKeyPress(.rightArrow) {
        isExpanded = true
        return .handled
      }
      .onKeyPress(.leftArrow) {
        isExpanded = false
        return .handled
      }
      .accessibilityRepresentation {
        DisclosureGroup(isExpanded: $isExpanded) {
          EmptyView()
        } label: {
          label.accessibilityElement(children: .combine)
        }
      }
      if isExpanded { content }
    }
  }
}

private struct ScanGroupView: View {
  let group: ScanGroup
  let scan: LiveScan
  @Binding var isExpanded: Bool

  var roots: [ScanRoot] {
    let members = scan.roots.filter {
      guard $0.group == group else { return false }
      if group == .other, let result = scan.results[$0.id], result.state == .complete {
        return result.bytes >= 500 * 1024 * 1024
      }
      return true
    }
    guard group == .simulators, scan.phase == .finished else { return members }
    return members.sorted { lhs, rhs in
      let left = scan.results[lhs.id]?.bytes ?? 0
      let right = scan.results[rhs.id]?.bytes ?? 0
      return left != right ? left > right : (lhs.title, lhs.id) < (rhs.title, rhs.id)
    }
  }
  private var counts: [SafetyLevel: Int] {
    let levels = roots.flatMap { root in
      let profiles: [StorageProfile] =
        root.device == nil ? [root.profile] : [.simulatorCache, .simulatorData]
      return profiles.compactMap { $0.assessment(for: scan.results[root.id]?.state)?.level }
    }
    return levels.reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }
  var summary: String {
    if group == .simulators && roots.isEmpty {
      guard let inventory = scan.simulatorInventory else {
        return scan.phase == .running ? "Aranıyor…" : "Ölçülmedi"
      }
      return inventory.note == nil ? "Cihaz yok" : "Okunamadı"
    }
    guard !roots.isEmpty else {
      if group == .projects { return "Seçilmedi" }
      return scan.phase == .finished ? "Kayıt bulunamadı" : "Bekleniyor"
    }
    let sizes = roots.compactMap { scan.results[$0.id] }
    if let bytes = scan.groupBytes[group] {
      let incomplete =
        sizes.count != roots.count
        || sizes.contains { $0.state != .complete && $0.state != .absent }
        || (group == .simulators && scan.simulatorInventory?.note != nil)
      return (incomplete ? "≥ " : "") + byteLabel(bytes)
    }
    if scan.activeRoot?.group == group { return "Ölçülüyor…" }
    if sizes.count < roots.count { return "Ölçülmedi" }
    return sizes.allSatisfy { $0.state == .absent } ? "Bulunamadı" : "Okunamadı"
  }

  var body: some View {
    OverviewDisclosure(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        if group == .projects && roots.isEmpty {
          Button("Proje klasörü seç…", action: scan.chooseProjects)
        } else {
          if group == .simulators {
            if let note = scan.simulatorInventory?.note { Note(symbol: "info.circle", text: note) }
            if !roots.isEmpty {
              Text(
                "\(roots.filter { $0.device != nil }.count) cihaz · Paylaşılan runtime imajları cihaz boyutlarının dışındadır."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }
          ForEach(roots) { root in
            if let device = root.device {
              SimulatorRow(device: device, root: root, scan: scan)
              if root.id != roots.last?.id { Divider() }
            } else {
              MeasuredRoot(root: root, scan: scan)
            }
          }
        }
      }.padding(.leading, 29).padding(.trailing, 8).padding(.bottom, 8)
    } label: {
      ScanGroupHeader(group: group, counts: counts, summary: summary)
    }
  }
}

private struct ScanGroupHeader: View {
  let group: ScanGroup
  let counts: [SafetyLevel: Int]
  let summary: String
  @ScaledMetric(relativeTo: .headline) private var sizeColumnWidth: CGFloat = 108

  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: group.symbol)
        .font(.system(size: 16, weight: .medium)).foregroundStyle(group.tint)
        .frame(width: 22).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(ReviewLanguage.text(group.titleKey)).font(.headline)
        Text(ReviewLanguage.text(group.detail)).font(.caption).foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .help(ReviewLanguage.text(group.detail))
      .frame(maxWidth: .infinity, alignment: .leading)
      if !counts.isEmpty {
        HStack(spacing: 6) {
          ForEach(SafetyLevel.allCases, id: \.self) { level in
            if let count = counts[level] {
              SafetyBadge(level: level, count: count)
            }
          }
        }.fixedSize()
      }
      Text(ReviewLanguage.text(summary))
        .font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        .frame(width: sizeColumnWidth, alignment: .trailing)
    }
  }
}

private struct SimulatorRow: View {
  let device: SimulatorDevice
  let root: ScanRoot
  let scan: LiveScan

  var body: some View {
    let result = scan.results[root.id]
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(device.name).font(.headline)
        Spacer()
        Text(ReviewLanguage.text(totalText(result))).font(.headline).monospacedDigit()
      }
      Text(device.detail).font(.caption).foregroundStyle(.secondary)
        .help(root.url.path)
      if let result, result.measured {
        portion(
          "Cihaz verileri", profile: .simulatorData, bytes: result.simulatorDataBytes,
          state: result.state)
        portion(
          "Önbellek ve geçici dosyalar", profile: .simulatorCache,
          bytes: result.simulatorCacheBytes, state: result.state)
        if result.state == .partial {
          Text("\(result.missed) girdi okunamadı. Boyutlar ölçülebilen kısmı gösterir.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }.padding(.vertical, 4)
      .accessibilityElement(children: .contain)
  }

  private func totalText(_ result: RootSize?) -> String {
    guard let result else { return scan.activeRoot == root ? "Ölçülüyor…" : "Ölçülmedi" }
    switch result.state {
    case .complete: return byteLabel(result.bytes)
    case .partial: return "≥ " + byteLabel(result.bytes)
    case .unavailable(let message): return message
    case .absent: return "Bulunamadı"
    }
  }

  private func portion(_ title: String, profile: StorageProfile, bytes: Int64, state: ReadState)
    -> some View
  {
    let assessment = profile.assessment(for: state)
    return HStack(alignment: .firstTextBaseline) {
      Text(ReviewLanguage.text(title)).font(.callout)
      if let assessment { SafetyBadge(level: assessment.level) }
      Spacer()
      Text(byteLabel(bytes)).font(.callout).monospacedDigit()
    }
    .padding(.leading, 10)
    .help(ReviewLanguage.text(assessment?.reason ?? ""))
    .accessibilityElement(children: .combine)
    .accessibilityHint(assessment?.reason ?? "")
  }
}

private struct MeasuredRoot: View {
  let root: ScanRoot
  let scan: LiveScan
  @State private var expanded = false

  var result: RootSize? { scan.results[root.id] }
  var assessment: SafetyAssessment? { root.profile.assessment(for: result?.state) }
  var amount: String {
    guard let result else { return scan.activeRoot == root ? "Ölçülüyor…" : "Ölçülmedi" }
    switch result.state {
    case .complete: return byteLabel(result.bytes)
    case .partial: return "≥ " + byteLabel(result.bytes)
    case .absent: return "Bulunamadı"
    case .unavailable(let message): return message
    }
  }
  var body: some View {
    OverviewDisclosure(isExpanded: $expanded, compact: true) {
      VStack(alignment: .leading, spacing: 5) {
        Text(root.url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        if let usage = root.runtimeUsage {
          RuntimeDetails(usage: usage)
        } else if let result, result.measured {
          Text("\(result.files) dosya ölçüldü").font(.caption)
          if root.group == .projects {
            Text(
              "Bilinen çıktı klasörleri toplamın \(byteLabel(result.outputBytes)) kadarını oluşturuyor."
            ).font(.caption)
          }
          if result.state == .partial {
            Text("\(result.missed) girdi okunamadı. Gösterilen boyut alt sınırdır.").font(.caption)
          }
          ForEach(
            result.largest.sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
              .prefix(5), id: \.key
          ) { name, bytes in
            HStack {
              Text(name)
              Spacer()
              Text(byteLabel(bytes)).monospacedDigit()
            }.font(.caption)
          }
        }
      }.foregroundStyle(.secondary).padding(.leading, 28).padding(.bottom, 6)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(ReviewLanguage.text(root.displayTitle)).font(.callout.weight(.medium))
          if let assessment { SafetyBadge(level: assessment.level) }
          Spacer(minLength: 2)
          Text(ReviewLanguage.text(amount)).font(.callout).foregroundStyle(.secondary)
            .monospacedDigit()
        }
        if let assessment {
          Text(ReviewLanguage.text(assessment.reason)).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.vertical, 3)
  }
}

extension SafetyLevel {
  var symbol: String { self == .safe ? "checkmark.shield" : "eye" }
  func color(in scheme: ColorScheme) -> Color {
    switch self {
    case .safe: scheme == .dark ? .mint : Color(red: 0.08, green: 0.39, blue: 0.27)
    case .review: scheme == .dark ? .orange : Color(red: 0.56, green: 0.29, blue: 0.04)
    }
  }
}

struct SafetyBadge: View {
  let level: SafetyLevel
  var count: Int? = nil
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let color = level.color(in: scheme)
    let title =
      count.map { number in
        let format = ReviewLanguage.text(
          level == .safe ? "%lld güvenli öğe" : "%lld öğe incelenmeli")
        return String(format: format, Int64(number))
      } ?? ReviewLanguage.text(level.rawValue)
    HStack(spacing: 3) {
      Image(systemName: level.symbol)
      if let count {
        Text(count.formatted()).monospacedDigit()
      } else {
        Text(title)
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(color)
    .padding(.horizontal, 7).padding(.vertical, 2)
    .background(color.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .help(title)
  }
}

private struct ProjectRootsView: View {
  let scan: LiveScan
  let openPlan: (ReportItem) -> Void
  @State private var cardMessage: String?
  @State private var removableRoots: [URL]?
  var body: some View {
    Page {
      PageTitle(
        kicker: "Çalışma alanı", title: "Proje klasörleri",
        subtitle:
          "Seçilen her klasörün tamamı ölçülür. Bilinen derleme çıktıları ayrıca gösterilir.")
      ViewThatFits(in: .horizontal) {
        HStack {
          MainAction(
            title: "Proje klasörü seç…", symbol: "folder.badge.plus", action: scan.chooseProjects)
          externalButton
        }
        VStack(alignment: .leading) {
          MainAction(
            title: "Proje klasörü seç…", symbol: "folder.badge.plus", action: scan.chooseProjects)
          externalButton
        }
      }
      if let removableRoots {
        if removableRoots.isEmpty {
          Note(
            symbol: "externaldrive",
            text: "Bağlı yerel disklerde standart bir proje klasörü bulunamadı.")
        }
        ForEach(removableRoots, id: \.path) { url in
          Button("Taramaya ekle · \(url.path)") { scan.addProjects([url]) }
            .disabled(scan.projects.contains(where: { $0.path == url.path }))
        }
      }
      if let note = scan.selectionNote { Note(symbol: "folder", text: note) }
      if scan.projects.isEmpty {
        ContentUnavailableView(
          "Henüz proje seçilmedi", systemImage: "folder",
          description: Text("Ölçmek istediğin bir veya daha fazla klasör seç.")
        )
        .frame(maxWidth: .infinity).padding(.vertical, 16)
      } else {
        ScanStatus(scan: scan)
        ForEach(scan.roots.filter { $0.group == .projects }) { root in
          Surface {
            VStack(alignment: .leading, spacing: 9) {
              MeasuredRoot(root: root, scan: scan)
              Text(root.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              if let row = scan.results[root.id], row.measured {
                if let date = row.sourceModified {
                  LabeledContent(
                    "Son kaynak değişikliği",
                    value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let date = row.lastBuild {
                  LabeledContent(
                    "Son çıktı değişikliği",
                    value: date.formatted(date: .abbreviated, time: .shortened))
                }
                ForEach(row.outputKinds.sorted { $0.value > $1.value }, id: \.key) { name, bytes in
                  LabeledContent(name, value: byteLabel(bytes))
                }
                ForEach(scan.projectArtifacts.filter { $0.project.path == root.url.path }) {
                  artifact in
                  LabeledContent("Proje dışındaki DerivedData", value: byteLabel(artifact.bytes))
                    .help(artifact.url.path)
                }
                ForEach(
                  scan.report?.items.filter { item in
                    guard let path = item.workspace else { return false }
                    return ProjectAttribution.owningRoot(workspace: path, selected: scan.projects)?
                      .path == root.url.path
                  } ?? []
                ) { output in
                  HStack {
                    Text(output.name)
                    Spacer()
                    Text(byteLabel(output.bytes ?? 0)).monospacedDigit()
                    Button("Alan planına ekle") { openPlan(output) }
                      .disabled(
                        scan.moveStates[output.id] != .ready || scan.hiddenIDs.contains(output.id))
                  }
                  if case .blocked(let reason) = scan.moveStates[output.id] {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                  }
                }
                if let date = row.sourceModified, Date.now.timeIntervalSince(date) > 60 * 86400 {
                  Note(
                    symbol: "clock", text: "60 günden uzun süredir kaynak değişikliği görülmedi.")
                }
                if let date = row.lastBuild, Date.now.timeIntervalSince(date) < 7 * 86400 {
                  Note(symbol: "hammer", text: "Bu proje son hafta derlendi.")
                }
                Button("İsimsiz özet kartını kopyala") {
                  cardMessage =
                    AnonymousCard.copy(bytes: row.bytes, build: row.outputBytes)
                    ? "İsimsiz kart kopyalandı." : "Kart hazırlanamadı."
                }
              }
              Button("Tarama listesinden çıkar") { scan.exclude(root.url) }
                .controlSize(.small).help("Yalnızca tarama kapsamını değiştirir")
            }.padding(15)
          }
        }
        if let cardMessage { Text(cardMessage).font(.caption).foregroundStyle(.secondary) }
      }
    }
  }
  private var externalButton: some View {
    Button("Harici disklerde proje klasörü bul") {
      Task { removableRoots = await ExternalProjects.suggestions() }
    }
  }
}
