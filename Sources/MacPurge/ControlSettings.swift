import AppKit
import ServiceManagement
import SwiftUI

struct ControlSettings: View {
  private static let languages: KeyValuePairs<String, LocalizedStringKey> = [
    "system": "Sistem", "tr": "Türkçe", "en": "English", "de": "Deutsch", "fr": "Français",
    "es": "Español", "ja": "日本語", "zh-Hans": "简体中文", "ko": "한국어", "ru": "Русский",
  ]
  let scan: LiveScan
  @Environment(AppPresence.self) private var presence
  @Environment(UpdateChecker.self) private var updater
  @Environment(\.scenePhase) private var scenePhase
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var changingLogin = false
  @State private var loginError: String?
  @State private var confirmsHistoryRemoval = false
  @AppStorage("scanProtectedLocations") private var protectedLocations = false
  @AppStorage("alertsEnabled") private var alerts = false
  @AppStorage("lowSpaceGB") private var low = 10
  @AppStorage("weeklySummary") private var weekly = false
  @AppStorage("growthAlerts") private var growth = false
  @AppStorage("scheduledScan") private var daily = false
  @AppStorage("reviewLanguage") private var language = ReviewLanguage.defaultLanguage
  @AppStorage("diskStatusStyle") private var diskStatusStyle = DiskStatusStyle.icon
  @State private var error: String?

  var body: some View {
    WorkspacePage {
      PageTitle(title: "Ayarlar")
    } content: { _ in
      settingsForm
    }
    .onChange(of: scenePhase, initial: true) { loginStatus = SMAppService.mainApp.status }
    .environment(\.locale, ReviewLanguage.locale(language))
    .onChange(of: language) { _, value in ReviewLanguage.apply(value) }
    .alert("Geçmiş kapatılsın mı?", isPresented: $confirmsHistoryRemoval) {
      Button("Vazgeç", role: .cancel) {}
      Button("Geçmişi temizle", role: .destructive) { Task { await scan.setHistory(false) } }
    } message: {
      Text("MacPurge’ün yerel tarama kayıtları temizlenir.")
    }
  }

  private var settingsForm: some View {
    Form {
      Section("General") {
        Toggle("Show in Dock", isOn: locationToggle(.dock))
          .disabled(!presence.location.canHide(.dock))
          .help("Keep at least one icon visible in the Dock or menu bar.")
        Toggle("Show in menu bar", isOn: locationToggle(.menuBar))
          .disabled(!presence.location.canHide(.menuBar))
          .help("Keep at least one icon visible in the Dock or menu bar.")
        if presence.location.hasMenu {
          settingsPicker("Menu bar display", choices: DiskStatusStyle.allCases, selection: $diskStatusStyle) {
            Text(ReviewLanguage.text($0.title))
          }
          Text("Live capacity updates every 30 seconds without scanning files.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Girişte aç", isOn: Binding(
          get: { loginStatus == .enabled || loginStatus == .requiresApproval },
          set: { updateLogin($0) }
        ))
        .disabled(changingLogin)
        if loginStatus == .requiresApproval {
          Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
            .workspaceButton()
        }
        if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
      }
      .toggleStyle(.switch)
      Section("Görünüm") {
        settingsPicker("Dil", choices: Self.languages.map(\.key), selection: $language) { code in
          Text(Self.languages.first { $0.key == code }?.value ?? LocalizedStringKey(code))
        }
      }
      Section("Tarama kapsamı") {
        Toggle("Ayrıntılı taramada korumalı konumları dahil et", isOn: $protectedLocations)
        Text("macOS may request access to Downloads, Trash, device backups and application containers.").font(
          .caption
        ).foregroundStyle(.secondary)
        Toggle("Uygulama açıkken günlük hızlı tarama", isOn: $daily)
        Button("Gizlenen \(scan.hiddenIDs.count) öğeyi göster", action: scan.restoreHidden)
          .workspaceButton(.secondary)
          .disabled(scan.hiddenIDs.isEmpty)
      }
      Section("Scan exclusions") {
        Text("These folders and everything inside them are skipped in quick and extended scans.")
          .font(.caption).foregroundStyle(.secondary)
        ForEach(scan.excludedFolders, id: \.path) { folder in
          HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent)
                .lineLimit(1).truncationMode(.middle)
              Text((folder.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(folder.path)
            }
            Spacer(minLength: 8)
            Button {
              scan.removeExcludedFolder(folder)
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove exclusion")
            .accessibilityLabel(Text("Remove exclusion") + Text(" · " + folder.path))
            .disabled(scan.cleanup.busy)
          }
        }
        Button(action: scan.chooseExcludedFolders) {
          Label("Add folders…", systemImage: "plus")
        }
        .workspaceButton(.secondary)
        .disabled(scan.cleanup.busy)
      }
      Section("Scan history") {
        Toggle("Ölçüm geçmişini bu Mac’te tut", isOn: Binding(
          get: { scan.historyEnabled },
          set: { enabled in
            if enabled { Task { await scan.setHistory(true) } } else { confirmsHistoryRemoval = true }
          }))
        settingsPicker("Keep history", choices: ActivityRetention.allCases, selection: Binding(
          get: { scan.historyRetention }, set: { value in Task { await scan.setHistoryRetention(value) } }
        )) { retention in
          switch retention {
          case .thirtyDays: Text("30 days")
          case .ninetyDays: Text("90 days")
          case .forever: Text("Forever")
          }
        }
        .disabled(!scan.historyEnabled)
        Text("Only scan records expire. Files in the Trash and their restore options are kept.")
          .font(.caption).foregroundStyle(.secondary)
        if let message = scan.historyError {
          Text(message).font(.caption).foregroundStyle(.secondary)
        }
      }
      Section("Bildirimler") {
        Toggle(
          "Az alan bildirimi",
          isOn: Binding(
            get: { alerts },
            set: { value in
              if value {
                Task {
                  alerts = await ScanAlerts.request()
                  if !alerts { error = "Bildirim izni verilmedi." }
                }
              } else {
                alerts = false
              }
            }))
        if alerts {
          settingsPicker("Boş alan eşiği", choices: [5, 10, 20, 50, 100], selection: $low) { Text("\($0) GB") }
          Toggle("Belirgin büyüme", isOn: $growth)
          Toggle("Haftalık büyüme özeti", isOn: $weekly)
        }
      }
      if let error { Text(ReviewLanguage.text(error)).foregroundStyle(.secondary) }
      Text("Alan planında seçtiğin önbellekleri inceleyip Çöp’e taşıyabilirsin.").font(.caption).foregroundStyle(.secondary)
      Section("Updates") {
        LabeledContent("Version", value: updater.version)
        Toggle("Automatically check for updates", isOn: Binding(
          get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
        HStack {
          Button("Check for Updates…") { Task { await updater.check(manual: true) } }
            .workspaceButton(updater.available ? .secondary : .primary)
            .disabled(updater.checking || updater.installing)
          if updater.checking || updater.installing {
            WorkspaceActivityIndicator(label: updater.installing ? "Updating…" : "Kontrol ediliyor…")
          }
          if updater.available {
            Spacer()
            Button("Download and Restart") {
              scan.cancel()
              Task { await updater.downloadAndInstall() }
            }
            .workspaceButton()
            .disabled(scan.cleanup.busy || updater.installing)
          }
        }
        if let status = updater.installationStatus {
          Text(status).font(.caption).foregroundStyle(.secondary)
        } else if let release = updater.release, updater.available {
          Text(ReviewLanguage.format("MacPurge %@ is available.", release.version))
            .font(.caption).foregroundStyle(.secondary)
        } else if updater.lastChecked != nil && updater.lastError == nil {
          Text("MacPurge is up to date.").font(.caption).foregroundStyle(.secondary)
        }
        if let error = updater.installationError ?? updater.lastError {
          Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }.formStyle(.grouped)
      // Grouped forms already add their own padding at the scroll limits.
      .contentMargins(.vertical, WorkspaceLayout.contentInset - 8, for: .scrollContent)
  }

  private func settingsPicker<Choice: Hashable>(_ label: LocalizedStringKey, choices: [Choice],
    selection: Binding<Choice>, title: @escaping (Choice) -> Text
  ) -> some View {
    HStack {
      Text(label).accessibilityHidden(true)
      Spacer(minLength: 12)
      WorkspacePicker(label: label, choices: choices, selection: selection, title: title)
    }
  }

  private func locationToggle(_ target: AppPresence.Location) -> Binding<Bool> {
    Binding(
      get: { presence.location == .both || presence.location == target },
      set: { presence.use(presence.location.setting(target, visible: $0)) }
    )
  }

  private func updateLogin(_ enabled: Bool) {
    guard !changingLogin else { return }
    changingLogin = true
    loginError = nil
    Task {
      defer {
        loginStatus = SMAppService.mainApp.status
        changingLogin = false
      }
      do {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
      } catch { loginError = error.localizedDescription }
    }
  }
}

enum ReviewLanguage {
  static let defaultLanguage = "en"
  static var current: String {
    UserDefaults.standard.string(forKey: "reviewLanguage") ?? defaultLanguage
  }

  static func apply(_ language: String) {
    // App-domain preference only; AppKit uses it for menus, panels, and sheets.
    if language == "system" {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.set([language], forKey: "AppleLanguages")
    }
  }
  static func locale(_ language: String) -> Locale {
    language == "system" ? .autoupdatingCurrent : Locale(identifier: language)
  }
  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: locale(current), arguments: arguments)
  }
  static func text(_ key: String) -> String {
    let choice = ReviewLanguage.current
    let code = choice == "system" ? Bundle.main.preferredLocalizations.first ?? defaultLanguage : choice
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else { return key }
    let value = bundle.localizedString(forKey: key, value: key, table: nil)
    if value == key, code != "tr", code != "en",
      let en = Bundle.main.path(forResource: "en", ofType: "lproj"), let english = Bundle(path: en)
    {
      return english.localizedString(forKey: key, value: key, table: nil)
    }
    return value
  }
}

extension Date {
  func reviewDate(date: FormatStyle.DateStyle, time: FormatStyle.TimeStyle) -> String {
    formatted(FormatStyle(date: date, time: time, locale: ReviewLanguage.locale(ReviewLanguage.current)))
  }
}

/// A single preference makes it impossible to persist a configuration with no way back in.
@MainActor @Observable final class AppPresence {
  enum Location: String {
    case dock, menuBar, both
    var hasDock: Bool { self != .menuBar }
    var hasMenu: Bool { self != .dock }

    func canHide(_ target: Self) -> Bool { self == .both || self != target }

    func setting(_ target: Self, visible: Bool) -> Self {
      let shown = self == .both || self == target
      guard visible != shown else { return self }
      if visible { return .both }
      guard canHide(target) else { return self }
      return target == .dock ? .menuBar : .dock
    }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
      defaults.string(forKey: "appIconLocation").flatMap(Self.init(rawValue:))
        ?? (defaults.bool(forKey: "showsDiskMenu") ? .both : .dock)
    }
  }

  private(set) var location = Location.saved()

  func use(_ newLocation: Location) {
    guard location != newLocation else { return }
    let window = NSApp.keyWindow
    location = newLocation
    UserDefaults.standard.set(newLocation.rawValue, forKey: "appIconLocation")
    let policy: NSApplication.ActivationPolicy = newLocation.hasDock ? .regular : .accessory
    if NSApp.activationPolicy() != policy {
      NSApp.setActivationPolicy(policy)
      if let window, !window.isMiniaturized {
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  // macOS can remove a menu extra outside Settings (for example, with Command-drag).
  func setMenuInserted(_ inserted: Bool) {
    guard inserted != location.hasMenu else { return }
    use(inserted ? .both : .dock)
  }
}

struct SettingsSidebarFooter: View {
  private enum Destination: Hashable { case settings, about }

  @Environment(UpdateChecker.self) private var updater
  let scan: LiveScan
  let selected: Bool
  let openSettings: () -> Void
  @State private var updateError: String?

  var body: some View {
    VStack(spacing: 0) {
      if updater.available {
        updateButton
          .padding(.horizontal, 10)
          .padding(.top, 4)
          .padding(.bottom, 6)
      }
      List(selection: Binding<Destination?>(
        get: { selected ? .settings : nil },
        set: { destination in
          switch destination {
          case .settings: openSettings()
          case .about: NSApp.orderFrontStandardAboutPanel(nil)
          case nil: break
          }
        }
      )) {
        SidebarLabel("Ayarlar", symbol: "gearshape", selected: selected).tag(Destination.settings)
        SidebarLabel("About", symbol: "info.circle").tag(Destination.about)
      }
      .listStyle(.sidebar)
      .scrollDisabled(true)
      .frame(height: 72)
    }
    .alert("Update failed", isPresented: Binding(
      get: { updateError != nil },
      set: { if !$0 { updateError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(updateError ?? "")
    }
  }

  private var updateButton: some View {
    Button {
      guard !scan.cleanup.busy, !updater.installing, !updater.checking else { return }
      updateError = nil
      scan.cancel()
      Task {
        await updater.downloadAndInstall()
        updateError = updater.lastError
      }
    } label: {
      HStack(spacing: 6) {
        if updater.installing {
          WorkspaceActivityIndicator()
        } else {
          Image(systemName: "arrow.down.circle").accessibilityHidden(true)
        }
        Text(LocalizedStringKey(updater.installing ? "Updating…" : "Update Now"))
          .lineLimit(1).minimumScaleFactor(0.8)
      }
      .font(.callout.weight(.semibold))
      .frame(maxWidth: .infinity)
    }
    .workspaceButton()
    .disabled(scan.cleanup.busy || updater.installing || updater.checking)
    .help(scan.cleanup.busy
      ? ReviewLanguage.text("Önce devam eden işlemin bitmesini bekle.")
      : updater.installationStatus ?? ReviewLanguage.text("Download and Restart"))
    .accessibilityValue(updater.installationStatus ?? "")
  }
}
