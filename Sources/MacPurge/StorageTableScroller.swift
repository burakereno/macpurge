import AppKit
import SwiftUI

extension View {
  /// Give the native scroller the full viewport while insetting the table and its header.
  func storageTableScroller(contentInset: CGFloat) -> some View {
    background {
      StorageTableScroller(contentInset: contentInset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

private struct StorageTableScroller: NSViewRepresentable {
  let contentInset: CGFloat

  func makeNSView(context: Context) -> Probe { Probe() }

  func updateNSView(_ view: Probe, context: Context) {
    view.contentInset = contentInset
    view.blendsRowsIntoBackground = context.environment.colorScheme == .dark
    view.schedule()
  }

  static func dismantleNSView(_ view: Probe, coordinator: ()) {
    view.detach()
  }

  final class Probe: NSView {
    var contentInset: CGFloat = 0
    var blendsRowsIntoBackground = false
    private weak var tableScrollView: NSScrollView?
    private var originalLayout: (content: NSEdgeInsets, automatic: Bool)?
    private var scrollObservers: [NSObjectProtocol] = []
    private var postedBoundsChanges = false
    private weak var verticalScroller: NSScroller?
    private var scrollerObserver: NSObjectProtocol?
    private var postedFrameChanges = false
    private var pending: Task<Void, Never>?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { detach() } else { schedule() }
    }

    override func layout() {
      super.layout()
      schedule()
    }

    func schedule() {
      guard pending == nil, window != nil else { return }
      pending = Task { @MainActor [weak self] in
        guard !Task.isCancelled, let self else { return }
        defer { self.pending = nil }
        self.applyInsets()
      }
    }

    private func applyInsets() {
      guard !bounds.isEmpty, let window else { return }
      let viewport = convert(bounds, to: nil)
      var ancestor = superview
      while let container = ancestor {
        if let scroll = matchingTable(in: container, viewport: viewport) {
          if tableScrollView !== scroll {
            restoreInsets()
            tableScrollView = scroll
            originalLayout = (scroll.contentInsets, scroll.automaticallyAdjustsContentInsets)
            observeScrolling(in: scroll)
          }
          let frame = scroll.convert(scroll.bounds, to: nil)
          let leading = viewport.minX - frame.minX + contentInset
          var insets = scroll.contentInsets
          if scroll.automaticallyAdjustsContentInsets { scroll.automaticallyAdjustsContentInsets = false }
          if insets.left != leading || insets.right != contentInset {
            insets.left = leading
            insets.right = contentInset
            scroll.contentInsets = insets
          }
          alignScroller(in: scroll)
          updateRowBackgrounds(in: scroll, blend: blendsRowsIntoBackground)
          return
        }
        if container === window.contentView { break }
        ancestor = container.superview
      }
    }

    private func observeScrolling(in scroll: NSScrollView) {
      let clip = scroll.contentView
      postedBoundsChanges = clip.postsBoundsChangedNotifications
      clip.postsBoundsChangedNotifications = true
      let events: [(Notification.Name, NSView)] = [
        (NSView.boundsDidChangeNotification, clip),
        (NSScrollView.didLiveScrollNotification, scroll),
        (NSScrollView.didEndLiveScrollNotification, scroll),
      ]
      scrollObservers = events.map { name, source in
        NotificationCenter.default.addObserver(forName: name, object: source, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.schedule() }
        }
      }
    }

    private func updateRowBackgrounds(in scroll: NSScrollView, blend: Bool) {
      guard let table = scroll.documentView as? NSTableView,
        table.usesAlternatingRowBackgroundColors else { return }
      let colors = NSColor.alternatingContentBackgroundColors
      table.enumerateAvailableRowViews { row, index in
        guard index >= 0 else { return }
        let color = blend && index.isMultiple(of: 2)
          ? WorkspaceDetailSurface.darkBackground : colors[index % colors.count]
        if row.backgroundColor != color { row.backgroundColor = color }
      }
    }

    private func alignScroller(in scroll: NSScrollView) {
      guard let scroller = scroll.verticalScroller, scroller.superview === scroll else { return }
      if verticalScroller !== scroller {
        stopObservingScroller()
        verticalScroller = scroller
        postedFrameChanges = scroller.postsFrameChangedNotifications
        scroller.postsFrameChangedNotifications = true
        // SwiftUI's native table tiles the scroller again when its rows change.
        scrollerObserver = NotificationCenter.default.addObserver(
          forName: NSView.frameDidChangeNotification, object: scroller, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.schedule() }
        }
      }
      let x = scroll.bounds.maxX - scroller.frame.width
      if abs(scroller.frame.minX - x) > 0.5 {
        scroller.setFrameOrigin(NSPoint(x: x, y: scroller.frame.minY))
      }
    }

    private func stopObservingScroller() {
      if let scrollerObserver { NotificationCenter.default.removeObserver(scrollerObserver) }
      scrollerObserver = nil
      verticalScroller?.postsFrameChangedNotifications = postedFrameChanges
      verticalScroller = nil
    }

    // The native table can extend under the sidebar. Match the visible viewport edges.
    private func matchingTable(in view: NSView, viewport: CGRect) -> NSScrollView? {
      if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
        let frame = scroll.convert(scroll.bounds, to: nil)
        return frame.minX <= viewport.minX + 1 && abs(frame.maxX - viewport.maxX) < 1
          && abs(frame.minY - viewport.minY) < 1 && abs(frame.maxY - viewport.maxY) < 1
          ? scroll : nil
      }
      for child in view.subviews {
        if let scroll = matchingTable(in: child, viewport: viewport) { return scroll }
      }
      return nil
    }

    private func restoreInsets() {
      stopObservingScroller()
      for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
      scrollObservers.removeAll()
      if let scroll = tableScrollView, let originalLayout {
        scroll.contentView.postsBoundsChangedNotifications = postedBoundsChanges
        updateRowBackgrounds(in: scroll, blend: false)
        scroll.contentInsets = originalLayout.content
        scroll.automaticallyAdjustsContentInsets = originalLayout.automatic
        scroll.tile()
      }
      tableScrollView = nil
      originalLayout = nil
    }

    func detach() {
      pending?.cancel()
      pending = nil
      restoreInsets()
    }
  }
}
