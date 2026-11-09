import AppKit
#if SWIFT_PACKAGE
import MacPurgeCore
#endif

/// SwiftUI owns the app state and window actions; AppKit distinguishes mouse buttons.
@MainActor
final class DiskStatusItem: NSObject, NSMenuDelegate {
  private var item: NSStatusItem?
  private var visibility: NSKeyValueObservation?
  private weak var scan: LiveScan?
  private var showWorkspace: (() -> Void)?
  private var showSettings: (() -> Void)?
  private var didRemove: (() -> Void)?
  private var style: DiskStatusStyle = .icon
  private let capacity = DiskCapacityMonitor()
  private weak var capacityMenuItem: NSMenuItem?

  func update(
    visible: Bool, style: DiskStatusStyle, scan: LiveScan, showWorkspace: @escaping () -> Void,
    showSettings: @escaping () -> Void, didRemove: @escaping () -> Void
  ) {
    self.scan = scan
    self.showWorkspace = showWorkspace
    self.showSettings = showSettings
    self.didRemove = didRemove
    self.style = style
    guard visible else { remove(); return }
    capacity.onUpdate = { [weak self] in self?.render() }
    capacity.start()
    guard item == nil else { render(); return }

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
    render()
  }

  private func remove() {
    capacity.stop()
    capacityMenuItem = nil
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
    capacityMenuItem = nil
  }

  private func render() {
    guard let item, let button = item.button else { return }
    let reading = DiskStatusPresentation(capacity.reading)
    item.length = style.showsFreeSpace ? NSStatusItem.variableLength : NSStatusItem.squareLength
    button.image = style.showsUsage && reading != nil ? usageRing(reading!.usedFraction)
      : NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: BuildIdentity.name)
    button.image?.isTemplate = true
    button.imagePosition = style.showsFreeSpace ? .imageLeading : .imageOnly
    button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    button.title = style.showsFreeSpace ? " " + (reading.map { byteLabel($0.free) } ?? "—") : ""
    let detail = reading.map { ReviewLanguage.format("%@ free · %lld%% used", byteLabel($0.free), Int64($0.usedPercent)) }
      ?? ReviewLanguage.text("Current disk capacity is unavailable.")
    let label = BuildIdentity.name + " · " + (capacity.reading.map { $0.name + " · " } ?? "") + detail
    button.toolTip = label
    button.setAccessibilityLabel(label)
    capacityMenuItem?.title = capacityTitle
  }

  private var capacityTitle: String {
    guard let reading = DiskStatusPresentation(capacity.reading) else {
      return ReviewLanguage.text("Current disk capacity is unavailable.")
    }
    return ReviewLanguage.format("%@ free of %@", byteLabel(reading.free), byteLabel(reading.capacity))
  }

  private func usageRing(_ fraction: Double) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
      let track = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
      track.lineWidth = 2
      NSColor.labelColor.withAlphaComponent(0.25).setStroke()
      track.stroke()
      if fraction > 0 {
        let arc = NSBezierPath()
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 7,
          startAngle: 90, endAngle: 90 - 360 * min(1, max(0, fraction)), clockwise: true)
        NSColor.labelColor.setStroke()
        arc.stroke()
      }
      return true
    }
    image.isTemplate = true
    return image
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
    let reading = NSMenuItem(title: capacityTitle, action: nil, keyEquivalent: "")
    reading.isEnabled = false
    menu.addItem(reading)
    capacityMenuItem = reading
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
