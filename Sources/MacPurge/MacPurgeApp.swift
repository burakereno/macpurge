import AppKit
import SwiftUI

struct MacPurgeApp: App {
  @NSApplicationDelegateAdaptor(NoticeDelegate.self) private var noticeDelegate
  @State private var demo = Demo()
  @State private var scan = LiveScan()
  @State private var section: LiveSection = .overview
  private let showingDemo = CommandLine.arguments.contains("--demo")
  @AppStorage("showsDiskMenu") private var showsDiskMenu = false
  @AppStorage("reviewLanguage") private var language = "tr"
  @AppStorage("scheduledScan") private var daily = false

  var body: some Scene {
    Window("MacPurge", id: "workspace") {
      Group {
        if showingDemo {
          WorkspaceView(demo: demo)
        } else {
          LiveWorkspace(scan: scan, section: $section)
        }
      }
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if MACPURGE_PROFILE
          StartupProbe.watchWindow()
        #endif
      }
    }
    .defaultSize(width: 1020, height: 730)
    .defaultPosition(.center)
    .windowToolbarStyle(.unified)
    .commands {
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
          ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { index, section in
            Button(section.rawValue) { demo.show(section) }
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
    Settings { ControlSettings(scan: scan) }
    MenuBarExtra(isInserted: $showsDiskMenu) {
      DiskMenu(scan: scan)
    } label: {
      Label(scan.report?.free.map { byteLabel($0) } ?? "MacPurge", systemImage: "externaldrive")
    }
  }
}

struct WorkspaceView: View {
  @Bindable var demo: Demo
  @State private var confirmReset = false

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 9) {
          LayerMark().frame(width: 26, height: 29)
          Text("MacPurge").font(.system(size: 19, weight: .bold)).tracking(-0.7)
        }.padding(.leading, 18).padding(.top, 13).padding(.bottom, 19)
        List(
          selection: Binding<Workspace?>(
            get: { demo.workspace }, set: { if let section = $0 { demo.show(section) } })
        ) {
          Section("Çalışma alanı") {
            ForEach(Workspace.allCases) { section in
              Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
          }
        }.listStyle(.sidebar)
        Spacer(minLength: 0)
        HStack(spacing: 9) {
          Image(systemName: "flask").foregroundStyle(Ink.sea).font(.system(size: 16))
          VStack(alignment: .leading, spacing: 2) {
            Text("Örnek oturum").font(.callout.weight(.semibold))
            Text("Veriler simüle edilir").font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.leading, 19).padding(.bottom, 19)
      }
      .navigationSplitViewColumnWidth(min: 165, ideal: 194, max: 230)
    } detail: {
      NavigationStack(path: $demo.path) {
        Group {
          switch demo.workspace {
          case .overview: Overview(demo: demo)
          case .projects: Projects(demo: demo)
          case .activity: Activity(demo: demo)
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
      .navigationTitle("MacPurge")
      .toolbar {
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
    .tint(Ink.sea)
    .alert("Örnek oturum sıfırlansın mı?", isPresented: $confirmReset) {
      Button("Vazgeç", role: .cancel) {}
      Button("Sıfırla") { demo.reset() }
    } message: {
      Text("Proje çıktıları ve etkinlik geçmişi başlangıçtaki örnek duruma döner.")
    }
  }
}
