import Foundation
import Testing
@testable import MacPurge

struct AppPresenceTests {
  @MainActor @Test func changingVisibilityAlwaysLeavesAnIconAvailable() {
    let locations: [AppPresence.Location] = [.dock, .menuBar, .both]
    for location in locations {
      for target: AppPresence.Location in [.dock, .menuBar] {
        for visible in [false, true] {
          let result = location.setting(target, visible: visible)
          #expect(result.hasDock || result.hasMenu)
          if location == target && !visible {
            #expect(!location.canHide(target))
            #expect(result == location)
          }
        }
      }
    }
    #expect(AppPresence.Location.both.setting(.dock, visible: false) == .menuBar)
    #expect(AppPresence.Location.both.setting(.menuBar, visible: false) == .dock)
    #expect(AppPresence.Location.dock.setting(.menuBar, visible: true) == .both)
    #expect(AppPresence.Location.menuBar.setting(.dock, visible: true) == .both)
  }

  @MainActor @Test func missingOrInvalidPreferencesFallBackToReachableIcons() throws {
    let suite = "macpurge-presence-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AppPresence.Location.saved(in: defaults) == .dock)
    defaults.set("neither", forKey: "appIconLocation")
    #expect(AppPresence.Location.saved(in: defaults) == .dock)
    defaults.set(true, forKey: "showsDiskMenu")
    #expect(AppPresence.Location.saved(in: defaults) == .both)
    defaults.set("menuBar", forKey: "appIconLocation")
    #expect(AppPresence.Location.saved(in: defaults) == .menuBar)
  }
}
