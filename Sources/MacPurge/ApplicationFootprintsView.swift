import AppKit
import SwiftUI

/// The catalog remains available during scans and uses the latest storage measurements.
struct InstalledApplicationCards: View {
  @Environment(\.workspaceListLayout) private var layout
  let apps: [ApplicationInventory.Installed]
  let footprints: [ApplicationFootprint]
  let contentInset: CGFloat
  let open: (ApplicationInventory.Installed) -> Void
  @FocusState private var focusedApp: String?

  var body: some View {
    let measurements = Dictionary(footprints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let rows = apps.sorted { lhs, rhs in
      let left = total(measurements[lhs.id]) ?? -1
      let right = total(measurements[rhs.id]) ?? -1
      if left != right { return left > right }
      let order = lhs.identity.name.localizedStandardCompare(rhs.identity.name)
      return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: layout.cardSpacing) {
          ForEach(rows) { app in
            let footprint = measurements[app.id]
            InstalledApplicationCard(app: app, footprint: footprint, total: total(footprint),
              focused: focusedApp == app.id) { open(app) }
              .focusable()
              .focusEffectDisabled()
              .focused($focusedApp, equals: app.id)
              .onKeyPress(.return) { open(app); return .handled }
              .contextMenu {
                Button("Show application files") { open(app) }
                Button("Finder’da aç") {
                  NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.id)])
                }
              }
          }
        }
        .padding(.horizontal, contentInset)
      }
      .contentMargins(.top, contentInset, for: .scrollContent)
      .onKeyPress(keys: [.upArrow, .downArrow]) { press in
        guard let focusedApp, let index = rows.firstIndex(where: { $0.id == focusedApp }) else { return .ignored }
        let next = index + (press.key == .downArrow ? 1 : -1)
        guard rows.indices.contains(next) else { return .handled }
        let id = rows[next].id
        proxy.scrollTo(id)
        self.focusedApp = id
        return .handled
      }
    }
  }

  private func total(_ footprint: ApplicationFootprint?) -> Int64? {
    guard let footprint, footprint.bundleBytes != nil || footprint.dataBytes != nil else { return nil }
    return footprint.measuredBytes
  }
}

private struct InstalledApplicationCard: View {
  let app: ApplicationInventory.Installed
  let footprint: ApplicationFootprint?
  let total: Int64?
  let focused: Bool
  let open: () -> Void
  @State private var hovered = false
  @State private var icon: NSImage?
  @ScaledMetric(relativeTo: .body) private var iconSize = 28

  var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        Group {
          if let icon {
            Image(nsImage: icon).resizable().renderingMode(.original).scaledToFit()
          } else {
            Image(systemName: "macwindow").font(.system(size: 22)).foregroundStyle(.secondary)
          }
        }
        .frame(width: iconSize, height: iconSize)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text(app.identity.name).font(.headline).lineLimit(1).truncationMode(.middle)
            if let reason = ApplicationUninstall.protectedReason(app.identity) {
              Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
                .help(ReviewLanguage.text(reason)).accessibilityLabel(ReviewLanguage.text(reason))
            }
            if let version = app.version {
              Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          Text(app.id).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          if let footprint {
            let bundle = footprint.bundleBytes.map(byteLabel) ?? "—"
            let data = footprint.dataBytes.map(byteLabel) ?? "—"
            Text("\(Text("App bundle")) \(bundle) · \(Text("Recognized data")) \(data)")
              .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        let amount = total.map { (footprint?.complete == false ? "≥ " : "") + byteLabel($0) } ?? "—"
        InventoryAmount(text: amount, prominent: true)
        Image(systemName: "chevron.forward").font(.callout).foregroundStyle(.secondary)
          .frame(width: InventoryLayout.actionWidth)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, ListCardLayout.horizontalPadding)
      .padding(.vertical, ListCardLayout.verticalPadding)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .detailCardSurface(highlighted: hovered || focused)
    .onHover { hovered = $0 }
    .accessibilityHint(Text("Show application files"))
    .help(app.id)
    .task(id: app.id) { icon = NSWorkspace.shared.icon(forFile: app.id) }
  }
}
