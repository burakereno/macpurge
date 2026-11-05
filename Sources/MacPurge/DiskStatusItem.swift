import AppKit

/// SwiftUI owns the app state and window actions; AppKit distinguishes mouse buttons.
@MainActor
final class DiskStatusItem: NSObject, NSMenuDelegate {
  private var item: NSStatusItem?
  private var visibility: NSKeyValueObservation?
  private weak var scan: LiveScan?
  private var showWorkspace: (() -> Void)?
  private var showSettings: (() -> Void)?
  private var didRemove: (() -> Void)?

  func update(
    visible: Bool, scan: LiveScan, showWorkspace: @escaping () -> Void,
    showSettings: @escaping () -> Void, didRemove: @escaping () -> Void
  ) {
    self.scan = scan
    self.showWorkspace = showWorkspace
    self.showSettings = showSettings
    self.didRemove = didRemove
    guard visible else { remove(); return }
    guard item == nil else { return }

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item = statusItem
    statusItem.behavior = .removalAllowed
    statusItem.autosaveName = "MacPurgeStatusItem"
    statusItem.isVisible = true
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: BuildIdentity.name)
      button.image?.isTemplate = true
      button.toolTip = BuildIdentity.name
      button.setAccessibilityLabel(BuildIdentity.name)
      button.target = self
      button.action = #selector(clicked)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    visibility = statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, change in
      guard change.newValue == false else { return }
      Task { @MainActor [weak self] in
        guard let self, self.item?.isVisible == false else { return }
        self.remove()
        self.didRemove?()
      }
    }
  }

  private func remove() {
    visibility?.invalidate()
    visibility = nil
    if let item { NSStatusBar.system.removeStatusItem(item) }
    item = nil
  }

  @objc private func clicked() {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      guard let item, let button = item.button else { return }
      let menu = makeMenu()
      menu.delegate = self
      item.menu = menu
      button.performClick(nil)
    } else {
      showWorkspace?()
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    item?.menu = nil
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu(title: BuildIdentity.name)
    menu.autoenablesItems = false
    func add(_ key: String, action: Selector) -> NSMenuItem {
      let entry = NSMenuItem(title: ReviewLanguage.text(key), action: action, keyEquivalent: "")
      entry.target = self
      menu.addItem(entry)
      return entry
    }
    _ = add("MacPurge’ü aç", action: #selector(openWorkspace))
    _ = add("Settings…", action: #selector(openSettings))
    menu.addItem(.separator())
    if let free = scan?.report?.free {
      let reading = NSMenuItem(title: ReviewLanguage.format("%@ boş alan", byteLabel(free)), action: nil, keyEquivalent: "")
      reading.isEnabled = false
      menu.addItem(reading)
    }
    add("Hızlı tarama", action: #selector(quickScan)).isEnabled = scan?.phase != .running
    menu.addItem(.separator())
    _ = add("Quit MacPurge", action: #selector(quit))
    return menu
  }

  @objc private func openWorkspace() { showWorkspace?() }
  @objc private func openSettings() { showSettings?() }
  @objc private func quickScan() { scan?.startQuick() }
  @objc private func quit() { NSApp.terminate(nil) }
}
