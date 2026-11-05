import AppKit
import SwiftUI

struct MacPurgeApp: App {
  @NSApplicationDelegateAdaptor(NoticeDelegate.self) private var noticeDelegate
  @State private var demo = Demo()
  @State private var scan = LiveScan()
  @State private var section: LiveSection = .overview
  private let showingDemo = CommandLine.arguments.contains("--demo")
  @State private var presence = AppPresence()
  @State private var statusItem = DiskStatusItem()
  @State private var updater = UpdateChecker.shared
  @Environment(\.openWindow) private var openWindow
  @AppStorage("reviewLanguage") private var language = ReviewLanguage.defaultLanguage
  @AppStorage("scheduledScan") private var daily = false

  var body: some Scene {
    let menuInserted = presence.location.hasMenu
    Window(BuildIdentity.name, id: "workspace") {
      Group {
        if showingDemo {
          WorkspaceView(demo: demo, scan: scan)
        } else {
          LiveWorkspace(scan: scan, section: $section)
        }
      }
      .environment(presence)
      .environment(updater)
      .frame(minWidth: 690, minHeight: 510)
      .environment(\.locale, ReviewLanguage.locale(language))
      .task(id: daily) {
        guard daily, !showingDemo else { return }
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(24 * 3600)) } catch { return }
          if scan.phase != .running { scan.startQuick() }
        }
      }
      .onAppear {
        noticeDelegate.showWorkspace = { showWorkspace() }
        noticeDelegate.showSettings = { showWorkspace(settings: true) }
        noticeDelegate.showActivity = {
          if showingDemo { demo.show(.activity) } else { section = .activity }
          showWorkspace()
        }
        #if MACPURGE_PROFILE
          StartupProbe.watchWindow()
        #endif
      }
    }
    .defaultSize(width: 1020, height: 730)
    .defaultPosition(.center)
    .windowToolbarStyle(.unified)
    .onChange(of: menuInserted, initial: true) {
      statusItem.update(
        visible: menuInserted, scan: scan,
        showWorkspace: { showWorkspace() },
        showSettings: { showWorkspace(settings: true) },
        didRemove: { [weak presence = presence] in presence?.setMenuInserted(false) })
    }
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          showWorkspace(settings: true)
          Task { await updater.check(manual: true) }
        }.disabled(updater.checking || updater.installing)
      }
      CommandMenu("Çalışma Alanı") {
        if !showingDemo {
          Button("Genel bakış") { section = .overview }.keyboardShortcut("1")
          Button("Proje klasörleri") { section = .projects }.keyboardShortcut("2")
          Button("Depolama") { section = .storage }.keyboardShortcut("3")
          Button("Alan planı") { section = .plan }.keyboardShortcut("4")
          Button("Etkinlik") { section = .activity }.keyboardShortcut("5")
          Divider()
          Button("Proje klasörü seç…", action: scan.chooseProjects).keyboardShortcut("o")
          Button("Yeniden tara", action: scan.start).keyboardShortcut("r").disabled(
            scan.phase == .running)
          Button("Ayrıntılı tarama", action: scan.startDetailed).keyboardShortcut(
            "r", modifiers: [.command, .shift])
          Button("Taramayı durdur", action: scan.cancel).disabled(scan.phase != .running)
        } else {
          ForEach(Array(Workspace.destinations.enumerated()), id: \.element) { index, section in
            Button(ReviewLanguage.text(section.rawValue)) { demo.show(section) }
              .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
          }
          Divider()
          Button("Atlas Studio’yu aç") {
            demo.show(.projects)
            demo.openProject()
          }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
      }
    }
  }

  private func showWorkspace(settings: Bool = false) {
    if settings {
      if showingDemo { demo.show(.settings) } else { section = .settings }
    }
    openWindow(id: "workspace")
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

struct WorkspaceView: View {
  @Bindable var demo: Demo
  let scan: LiveScan
  @State private var confirmReset = false

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 9) {
          LayerMark().frame(width: 32, height: 32)
          Text("MacPurge").font(.system(size: 19, weight: .bold)).tracking(-0.7)
        }.padding(.leading, 18).padding(.top, 13).padding(.bottom, 19)
        List(
          selection: Binding<Workspace?>(
            get: { demo.workspace }, set: { if let section = $0 { demo.show(section) } })
        ) {
          Section("Çalışma alanı") {
            ForEach(Workspace.destinations) { section in
              Label(ReviewLanguage.text(section.rawValue), systemImage: section.symbol).tag(section)
            }
          }
        }.listStyle(.sidebar)
        SettingsSidebarFooter(selected: demo.workspace == .settings) { demo.show(.settings) }
      }
      .navigationSplitViewColumnWidth(min: 165, ideal: 194, max: 230)
    } detail: {
      NavigationStack(path: $demo.path) {
        Group {
          switch demo.workspace {
          case .overview: Overview(demo: demo)
          case .projects: Projects(demo: demo)
          case .activity: Activity(demo: demo)
          case .settings: ControlSettings(scan: scan)
          }
        }
        .navigationDestination(for: Destination.self) { destination in
          switch destination {
          case .project: ProjectDetail(demo: demo)
          case .machine: MachineDetail()
          case .plan: Review(demo: demo)
          case .goal: Goal(demo: demo)
          case .receipt(let id):
            if let receipt = demo.receipts.first(where: { $0.id == id }) {
              ResultView(receipt: receipt, demo: demo)
            }
          }
        }
      }
      .navigationTitle(demo.workspace == .settings ? Text("Ayarlar") : Text("MacPurge"))
      .toolbar {
        if demo.workspace != .settings {
          ToolbarItem(placement: .primaryAction) {
            Menu {
              Button("20 GB alan hedefini incele") {
                demo.show(.overview)
                demo.path.append(.goal)
              }
              Divider()
              Button("Örnek oturumu sıfırla") { confirmReset = true }
            } label: {
              Label("Örnek oturum seçenekleri", systemImage: "ellipsis")
            }
            .help("Örnek oturum seçenekleri")
          }
        }
      }
    }
    .tint(Ink.sea)
    .alert("Örnek oturum sıfırlansın mı?", isPresented: $confirmReset) {
      Button("Vazgeç", role: .cancel) {}
      Button("Sıfırla") { demo.reset() }
    } message: {
      Text("Proje çıktıları ve etkinlik geçmişi başlangıçtaki örnek duruma döner.")
    }
  }
}
