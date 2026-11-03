import AppKit
import ServiceManagement
import SwiftUI

struct ControlSettings: View {
  let scan: LiveScan
  @AppStorage("showsDiskMenu") private var showMenu = false
  @AppStorage("scanProtectedLocations") private var protectedLocations = false
  @AppStorage("alertsEnabled") private var alerts = false
  @AppStorage("lowSpaceGB") private var low = 10
  @AppStorage("weeklySummary") private var weekly = false
  @AppStorage("growthAlerts") private var growth = false
  @AppStorage("scheduledScan") private var daily = false
  @AppStorage("reviewLanguage") private var language = "tr"
  @State private var error: String?
  @State private var login = SMAppService.mainApp.status == .enabled
  var body: some View {
    Form {
      Section("Görünüm") {
        Toggle("Menü çubuğunda boş alanı göster", isOn: $showMenu)
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
        Toggle(
          "Girişte aç",
          isOn: Binding(
            get: { login },
            set: { value in
              Task {
                do {
                  if value {
                    try SMAppService.mainApp.register()
                  } else {
                    try await SMAppService.mainApp.unregister()
                  }
                  login = SMAppService.mainApp.status == .enabled
                } catch { self.error = error.localizedDescription }
              }
            }))
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
      if let error { Text(error).foregroundStyle(.secondary) }
      Section("Paket denetimi") {
        Button("Yerel MacPurge paketini doğrula…") {
          let panel = NSOpenPanel()
          panel.allowedContentTypes = [.applicationBundle]
          panel.canChooseDirectories = false
          panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
              do { error = try await PayloadVerification.inspect(url) } catch {
                self.error = error.localizedDescription
              }
            }
          }
        }
      }
      Text("Alan planında seçtiğin önbellekleri inceleyip Çöp’e taşıyabilirsin.").font(.caption).foregroundStyle(.secondary)
    }.formStyle(.grouped).frame(width: 480, height: 520)
      .environment(\.locale, ReviewLanguage.locale(language))
      .onChange(of: language) { _, value in ReviewLanguage.apply(value) }
  }
}

enum ReviewLanguage {
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
  static func text(_ key: String) -> String {
    let choice = UserDefaults.standard.string(forKey: "reviewLanguage") ?? "tr"
    let code = choice == "system" ? Bundle.main.preferredLocalizations.first ?? "tr" : choice
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

struct DiskMenu: View {
  let scan: LiveScan
  @Environment(\.openWindow) private var open
  var body: some View {
    if let free = scan.report?.free { Text("\(byteLabel(free)) boş alan") }
    Button("MacPurge’ü aç") {
      open(id: "workspace")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button("Hızlı tarama", action: scan.startQuick).disabled(scan.phase == .running)
    SettingsLink { Text("Ayarlar") }
  }
}
