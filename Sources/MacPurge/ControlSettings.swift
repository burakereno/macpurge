import AppKit
import ServiceManagement
import SwiftUI

struct ControlSettings: View {
  let scan: LiveScan
  @Environment(AppPresence.self) private var presence
  @Environment(UpdateChecker.self) private var updater
  @Environment(\.scenePhase) private var scenePhase
  @State private var proposedLocation: AppPresence.Location?
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var changingLogin = false
  @State private var loginError: String?
  @AppStorage("scanProtectedLocations") private var protectedLocations = false
  @AppStorage("alertsEnabled") private var alerts = false
  @AppStorage("lowSpaceGB") private var low = 10
  @AppStorage("weeklySummary") private var weekly = false
  @AppStorage("growthAlerts") private var growth = false
  @AppStorage("scheduledScan") private var daily = false
  @AppStorage("reviewLanguage") private var language = ReviewLanguage.defaultLanguage
  @State private var error: String?
  var body: some View {
    Form {
      Section("General") {
        Toggle("Show in Dock", isOn: locationToggle(.dock))
        Toggle("Show in menu bar", isOn: locationToggle(.menuBar))
        Toggle("Girişte aç", isOn: Binding(
          get: { loginStatus == .enabled || loginStatus == .requiresApproval },
          set: { updateLogin($0) }
        ))
        .disabled(changingLogin)
        if loginStatus == .requiresApproval {
          Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
        }
        if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
      }
      .toggleStyle(.switch)
      Section("Updates") {
        LabeledContent("Version", value: updater.version)
        Toggle("Automatically check for updates", isOn: Binding(
          get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
        HStack {
          Button("Check for Updates…") { Task { await updater.check(manual: true) } }
            .disabled(updater.checking || updater.installing)
          if updater.checking || updater.installing { ProgressView().controlSize(.small) }
          if updater.available {
            Spacer()
            Button("Download and Restart") {
              scan.cancel()
              Task { await updater.downloadAndInstall() }
            }.disabled(scan.cleanup.busy || updater.installing)
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
      Section("Görünüm") {
        Picker("Dil", selection: $language) {
          Text("Sistem").tag("system")
          Text("Türkçe").tag("tr")
          Text("English").tag("en")
          Text("Deutsch").tag("de")
          Text("Français").tag("fr")
          Text("Español").tag("es")
          Text("日本語").tag("ja")
          Text("简体中文").tag("zh-Hans")
          Text("한국어").tag("ko")
          Text("Русский").tag("ru")
        }
      }
      Section("Tarama kapsamı") {
        Toggle("Ayrıntılı taramada korumalı konumları dahil et", isOn: $protectedLocations)
        Text("Çöp, cihaz yedekleri ve uygulama kapsayıcıları için macOS erişim isteyebilir.").font(
          .caption
        ).foregroundStyle(.secondary)
        Toggle("Uygulama açıkken günlük hızlı tarama", isOn: $daily)
        Button("Gizlenen \(scan.hiddenIDs.count) öğeyi göster", action: scan.restoreHidden)
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
        .disabled(scan.cleanup.busy)
      }
      Section("Activity history") {
        Picker("Keep history", selection: Binding(
          get: { scan.historyRetention },
          set: { value in Task { await scan.setHistoryRetention(value) } }
        )) {
          Text("30 days").tag(ActivityRetention.thirtyDays)
          Text("90 days").tag(ActivityRetention.ninetyDays)
          Text("Forever").tag(ActivityRetention.forever)
        }
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
          Picker("Boş alan eşiği", selection: $low) {
            ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
          }
          Toggle("Belirgin büyüme", isOn: $growth)
          Toggle("Haftalık büyüme özeti", isOn: $weekly)
        }
      }
      if let error { Text(ReviewLanguage.text(error)).foregroundStyle(.secondary) }
      Text("Alan planında seçtiğin önbellekleri inceleyip Çöp’e taşıyabilirsin.").font(.caption).foregroundStyle(.secondary)
    }.formStyle(.grouped)
      .onChange(of: scenePhase, initial: true) { loginStatus = SMAppService.mainApp.status }
      .alert(
        proposedLocation == .menuBar ? Text("Switch to the menu bar?") : Text("Switch to the Dock?"),
        isPresented: Binding(get: { proposedLocation != nil }, set: { if !$0 { proposedLocation = nil } }),
        presenting: proposedLocation
      ) { location in
        Button("Switch") { presence.use(location) }
        Button("Vazgeç", role: .cancel) {}
      } message: { location in
        if location == .menuBar {
          Text("MacPurge will stay available in the menu bar when its Dock icon is hidden.")
        } else {
          Text("MacPurge will stay available in the Dock when its menu bar icon is hidden.")
        }
      }
      .environment(\.locale, ReviewLanguage.locale(language))
      .onChange(of: language) { _, value in ReviewLanguage.apply(value) }
  }

  private func locationToggle(_ target: AppPresence.Location) -> Binding<Bool> {
    Binding(
      get: { presence.location == .both || presence.location == target },
      set: { enabled in
        let other: AppPresence.Location = target == .dock ? .menuBar : .dock
        if enabled { presence.use(.both) }
        else if presence.location == .both { presence.use(other) }
        else { proposedLocation = other }
      }
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

struct DiskMenu: View {
  let scan: LiveScan
  let showWorkspace: () -> Void
  let showSettings: () -> Void

  var body: some View {
    Button("MacPurge’ü aç", action: showWorkspace)
    Button("Settings…", action: showSettings)
    Divider()
    if let free = scan.report?.free { Text("\(byteLabel(free)) boş alan") }
    Button("Hızlı tarama", action: scan.startQuick).disabled(scan.phase == .running)
    Divider()
    Button("Quit MacPurge") { NSApp.terminate(nil) }
  }
}

/// A single preference makes it impossible to persist a configuration with no way back in.
@MainActor @Observable final class AppPresence {
  enum Location: String {
    case dock, menuBar, both
    var hasDock: Bool { self != .menuBar }
    var hasMenu: Bool { self != .dock }

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
  let selected: Bool
  let openSettings: () -> Void

  var body: some View {
    Divider().padding(.horizontal, 10)
    List(selection: Binding<Bool?>(
      get: { selected ? true : nil },
      set: { if $0 == true { openSettings() } }
    )) {
      Label("Ayarlar", systemImage: "gearshape").tag(true)
    }
    .listStyle(.sidebar)
    .scrollDisabled(true)
    .frame(height: 44)
  }
}
