import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// The shared geometry for every content list. Keep screen-specific spacing out of callers.
enum InventoryLayout {
  static let horizontalPadding: CGFloat = 7
  static let verticalPadding: CGFloat = 12
  static let selectionWidth: CGFloat = 18
  static let disclosureWidth: CGFloat = 12
  static let actionWidth: CGFloat = 26
  static let controlSpacing: CGFloat = 6
  static let detailIndent: CGFloat = 32
  static let nestedIndent: CGFloat = 29
}

struct InventoryList<Item, ID: Hashable, Row: View>: View {
  let id: KeyPath<Item, ID>
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  init(_ items: [Item], id: KeyPath<Item, ID>, @ViewBuilder row: @escaping (Item) -> Row) {
    self.id = id
    self.items = items
    self.row = row
  }

  var body: some View {
    Surface {
      // Rows inset their hover vertically; the enclosing list supplies the horizontal inset.
      InventoryRows(items, id: id, row: row).padding(.horizontal, SurfaceCorners.rowInset)
    }
  }
}

extension InventoryList where Item: Identifiable, ID == Item.ID {
  init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
    self.init(items, id: \.id, row: row)
  }
}

/// Nested rows use the same spacing and separators without another enclosing card.
struct InventoryRows<Item, ID: Hashable, Row: View>: View {
  let items: [Item]
  let id: KeyPath<Item, ID>
  @ViewBuilder let row: (Item) -> Row

  init(_ items: [Item], id: KeyPath<Item, ID>, @ViewBuilder row: @escaping (Item) -> Row) {
    self.items = items
    self.id = id
    self.row = row
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(items, id: id) { item in
        row(item)
        if item[keyPath: id] != items.last?[keyPath: id] {
          InventorySeparator()
        }
      }
    }
  }
}

struct InventorySeparator: View {
  var body: some View { Divider() }
}

extension InventoryRows where Item: Identifiable, ID == Item.ID {
  init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
    self.init(items, id: \.id, row: row)
  }
}

struct InventoryAmount: View {
  let text: String
  var prominent = false
  @ScaledMetric(relativeTo: .headline) private var width: CGFloat = 108

  var body: some View {
    Text(text).font(prominent ? .headline : .body).monospacedDigit()
      .lineLimit(1).minimumScaleFactor(0.8)
      .frame(width: width, alignment: .trailing)
  }
}

struct InventoryGroupHeader<Badges: View>: View {
  let title: String
  let symbol: String
  let tint: Color
  let amount: String
  var subtitle: String? = nil
  var delta: Int64? = nil
  @ViewBuilder let badges: Badges

  var body: some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      HStack(spacing: 11) {
        Image(systemName: symbol)
          .font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
          .frame(width: 22).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
          if let subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(subtitle)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 6) { badges }.fixedSize()
      if let delta { SizeChange(bytes: delta) }
      InventoryAmount(text: amount, prominent: true)
      Color.clear.frame(width: InventoryLayout.actionWidth).accessibilityHidden(true)
    }
  }
}

struct DisclosureRowStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    return configuration.label.background {
      InventoryHover(active: isHovered, pressed: configuration.isPressed)
    }
  }
}

private struct InventoryHover: View {
  let active: Bool
  var pressed = false

  var body: some View {
    RoundedRectangle(cornerRadius: SurfaceCorners.rowRadius, style: .continuous)
      .fill(Color.primary.opacity(pressed ? 0.08 : active ? 0.05 : 0))
      .padding(.vertical, SurfaceCorners.rowInset)
  }
}

struct InventoryDisclosure<Content: View, RowLabel: View, Accessory: View>: View {
  @Binding var isExpanded: Bool
  let selectable: [ReportItem]
  @Binding var selected: Set<String>
  let busy: Bool
  var selectionHelp = "Kategorideki taşınabilir öğeleri seç"
  var activate: (() -> Void)? = nil
  var selection: Binding<Bool>? = nil
  @ViewBuilder let content: () -> Content
  @ViewBuilder let label: RowLabel
  @ViewBuilder let accessory: Accessory
  @State private var hovering = false
  @FocusState private var focused: Bool
  private var hasSelectionControl: Bool { selection != nil || !selectable.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        focused = true
        if let activate { activate() } else { isExpanded.toggle() }
      } label: {
        HStack(spacing: InventoryLayout.controlSpacing) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovering || focused ? .primary : .secondary)
            .frame(width: 12).accessibilityHidden(true)
          label
        }
        .padding(.leading, hasSelectionControl ? 27 : InventoryLayout.horizontalPadding)
        .padding(.trailing, InventoryLayout.horizontalPadding)
        .padding(.vertical, InventoryLayout.verticalPadding)
        .padding(.trailing, InventoryLayout.actionWidth + InventoryLayout.controlSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(DisclosureRowStyle(isHovered: hovering))
      .focusable()
      .focusEffectDisabled()
      .focused($focused)
      .onKeyPress(.rightArrow) {
        if let activate { activate() } else { isExpanded = true }
        return .handled
      }
      .onKeyPress(.leftArrow) {
        isExpanded = false
        return .handled
      }
      .accessibilityRepresentation {
        if let activate {
          Button(action: activate) { label.accessibilityElement(children: .combine) }
        } else {
          DisclosureGroup(isExpanded: $isExpanded) {
            EmptyView()
          } label: {
            label.accessibilityElement(children: .combine)
          }
        }
      }
      .overlay(alignment: .leading) {
        if let selection {
          Toggle(ReviewLanguage.text(selectionHelp), isOn: selection)
            .toggleStyle(.checkbox).labelsHidden().controlSize(.small)
            .help(ReviewLanguage.text(selectionHelp)).disabled(busy).padding(.leading, 7)
        } else if !selectable.isEmpty {
          Toggle(
            sources: selectable.map { item in
              Binding(
                get: { selected.contains(item.id) },
                set: { on in
                  if on { selected.insert(item.id) } else { selected.remove(item.id) }
                })
            }, isOn: \.self
          ) { Text(ReviewLanguage.text(selectionHelp)) }
          .toggleStyle(.checkbox).labelsHidden().controlSize(.small)
          .help(ReviewLanguage.text(selectionHelp))
          .disabled(busy).padding(.leading, 7)
        }
      }
      .overlay(alignment: .trailing) { accessory.padding(.trailing, InventoryLayout.horizontalPadding) }
      .onHover { hovering = $0 }
      if isExpanded {
        content().padding(.leading, InventoryLayout.nestedIndent)
      }
    }
  }
}

/// Keep the action columns in place while the pointer moves between the label and its buttons.
struct InventoryRow: View {
  let scan: LiveScan
  let item: ReportItem?
  let title: String
  let amount: String
  let location: URL?
  @Binding var selected: Set<String>
  var expanded: Bool?
  var toggleDetails: (() -> Void)?
  // A project row stages its selection in the plan; other inventory rows offer a move preview.
  var inPlan: Bool? = nil
  var caption: String? = nil
  var delta: Int64? = nil
  var removeFromPlan: (() -> Void)? = nil
  var onlyPath: URL? = nil
  @State private var showsPath = false
  private var isExpanded: Bool? { expanded ?? (location == nil ? nil : showsPath) }
  @State private var hovering = false
  @FocusState private var folderFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      controls
      if toggleDetails == nil, showsPath, let location {
        Text(location.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
          .textSelection(.enabled).padding(.leading, InventoryLayout.detailIndent)
          .padding(.vertical, InventoryLayout.verticalPadding)
      }
    }
  }

  private var controls: some View {
    let decision = scan.action(for: item)
    let state = decision.availability
    return HStack(spacing: InventoryLayout.controlSpacing) {
      Group {
        if state == .ready {
          Toggle(
          isOn: Binding(
            get: { item.map { selected.contains($0.id) } ?? false },
            set: { on in
              guard let item, state == .ready else { return }
              if on { selected.insert(item.id) } else { selected.remove(item.id) }
            })
          ) { Text(title) }
          .toggleStyle(.checkbox).labelsHidden().controlSize(.small)
          .disabled(scan.cleanup.busy || inPlan == true)
        } else { Color.clear.accessibilityHidden(true) }
      }.frame(width: InventoryLayout.selectionWidth)
      if isExpanded != nil {
        Button(action: toggleDetails ?? { showsPath.toggle() }) { rowLabel(decision) }
          .buttonStyle(.plain).focusEffectDisabled()
          .accessibilityLabel(title).accessibilityValue(
            ReviewLanguage.text(isExpanded == true ? "Açık" : "Kapalı"))
      } else {
        rowLabel(decision)
      }

      Button {
        openLocation()
      } label: {
        Image(systemName: "folder").frame(width: InventoryLayout.actionWidth, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain).focused($folderFocused)
      .opacity(location != nil && (hovering || folderFocused) ? 1 : 0)
      .disabled(location == nil)
      .accessibilityLabel(ReviewLanguage.text("Finder’da aç") + " · " + title)
      .help("Finder’da aç")
      Group {
        if inPlan == true {
          Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            .help("Planda")
        } else if inPlan == nil, let item {
          ItemTrashButton(scan: scan, item: item, onlyPath: onlyPath)
        } else { Color.clear.accessibilityHidden(true) }
      }.frame(width: InventoryLayout.actionWidth)
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, InventoryLayout.horizontalPadding)
    .padding(.vertical, InventoryLayout.verticalPadding)
    .background { InventoryHover(active: hovering) }
    .contentShape(Rectangle()).onHover { hovering = $0 }
    .contextMenu {
      if location != nil { Button("Finder’da aç", action: openLocation) }
      if let removeFromPlan { Button("Plandan çıkar", action: removeFromPlan) }
      if let item, let operation = decision.permanentOperation {
        Button(operation.title + "…") { scan.cleanup.reviewPermanentCleanup(item, scan: scan) }
          .disabled(scan.cleanup.busy)
      } else if inPlan == nil, let item, state == .ready {
        Button("Çöp’e taşı…") { scan.cleanup.prepare([item], scan: scan, onlyPath: onlyPath, explicit: true) }
          .disabled(scan.cleanup.busy)
      }
    }
  }

  private func rowLabel(_ decision: CleanupAction) -> some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      Group {
        if let isExpanded {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        } else { Color.clear.accessibilityHidden(true) }
      }.frame(width: InventoryLayout.disclosureWidth)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
          ActionBadge(action: decision, item: item)
        }
        if let caption = caption ?? decision.availability.explanation
          ?? item.map({ scan.actionDescription($0) })
        {
          Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(caption)
        }
      }
      Spacer(minLength: 4)
      if let delta { SizeChange(bytes: delta) }
      InventoryAmount(text: amount)
    }.frame(maxWidth: .infinity, minHeight: 30).contentShape(Rectangle())
  }

  private func openLocation() {
    guard let location else { return }
    InventoryLocation.open(location)
  }
}

enum InventoryLocation {
  static func open(_ location: URL) {
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) else {
      return
    }
    if directory.boolValue,
      let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
    {
      NSWorkspace.shared.open(
        [location], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration(),
        completionHandler: nil)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([location])
    }
  }
}

/// Informational rows and receipt actions keep the same slots as cleanable file rows.
struct InventoryReadout: View {
  let title: String
  let amount: String
  var symbol = "folder"
  var tint: Color = Ink.sea
  var subtitle: String? = nil
  var location: URL? = nil
  var actionSymbol = ""
  var actionHelp = ""
  var action: (() -> Void)? = nil
  var disabled = false
  @State private var hovering = false
  @FocusState private var folderFocused: Bool

  var body: some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      Image(systemName: symbol).foregroundStyle(tint).frame(width: 22).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle).help(title)
        if let subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(subtitle)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      InventoryAmount(text: amount)
      Button {
        if let location { InventoryLocation.open(location) }
      } label: {
        Image(systemName: "folder").frame(width: InventoryLayout.actionWidth, height: 26)
      }
      .buttonStyle(.plain).focused($folderFocused).disabled(location == nil)
      .opacity(location != nil && (hovering || folderFocused) ? 1 : 0)
      .help("Finder’da aç")
      .accessibilityLabel(ReviewLanguage.text("Finder’da aç") + " · " + title)
      Group {
        if let action {
          Button(action: action) { Image(systemName: actionSymbol) }
            .buttonStyle(.plain).help(ReviewLanguage.text(actionHelp)).disabled(disabled)
            .accessibilityLabel(ReviewLanguage.text(actionHelp) + " · " + title)
        } else { Color.clear.accessibilityHidden(true) }
      }.frame(width: InventoryLayout.actionWidth, height: 26)
    }
    .frame(minHeight: 30)
    .foregroundStyle(.primary)
    .padding(.horizontal, InventoryLayout.horizontalPadding)
    .padding(.vertical, InventoryLayout.verticalPadding)
    .background { InventoryHover(active: hovering) }
    .onHover { hovering = $0 }
  }
}

/// Overview, Storage, Projects and the plan expand the same measured-folder details.
struct InventoryMeasuredRow: View {
  let scan: LiveScan
  let item: ReportItem
  @Binding var selected: Set<String>
  var root: ScanRoot? = nil
  var amount: String? = nil
  var delta: Int64? = nil
  var title: String? = nil
  var inPlan: Bool? = nil
  var caption: String? = nil
  var removeFromPlan: (() -> Void)? = nil
  var onlyPath: URL? = nil
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      InventoryRow(
        scan: scan, item: item, title: title ?? item.actionTitle,
        amount: amount ?? item.bytes.map { (item.status == "partial" ? "≥ " : "") + byteLabel($0) } ?? "—",
        location: item.estimated ? nil : URL(fileURLWithPath: item.path),
        selected: $selected, expanded: expanded,
        toggleDetails: { expanded.toggle() }, inPlan: inPlan, caption: caption, delta: delta,
        removeFromPlan: removeFromPlan, onlyPath: onlyPath)
      if expanded {
        InventoryItemDetails(item: item, result: root.flatMap { scan.results[$0.id] })
          .padding(.leading, InventoryLayout.nestedIndent)
      }
    }
    .onKeyPress(.rightArrow) { expanded = true; return .handled }
    .onKeyPress(.leftArrow) { expanded = false; return .handled }
  }
}

struct InventoryItemDetails: View {
  let item: ReportItem
  var result: RootSize? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(item.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        .textSelection(.enabled).padding(.leading, InventoryLayout.detailIndent)
        .padding(.vertical, InventoryLayout.verticalPadding)
      if let usage = item.runtimeUsage {
        RuntimeDetails(usage: usage)
      } else {
        if let age = item.age { FileAgeView(age: age, partial: !item.complete) }
        if let result, result.measured {
          Text("\(result.files) dosya ölçüldü").font(.caption).foregroundStyle(.secondary)
            .padding(.leading, InventoryLayout.detailIndent).padding(.vertical, 4)
          if result.state == .partial {
            Text("\(result.missed) girdi okunamadı. Gösterilen boyut alt sınırdır.")
              .font(.caption).foregroundStyle(.secondary)
              .padding(.leading, InventoryLayout.detailIndent).padding(.vertical, 4)
          }
          if item.category == ScanGroup.projects.rawValue {
            InventoryReadout(title: ReviewLanguage.text("Bilinen çıktı klasörleri"),
              amount: byteLabel(result.outputBytes), symbol: "hammer")
          }
        }
        if let date = item.modified {
          InventoryReadout(title: ReviewLanguage.text("Son dosya değişikliği"),
            amount: date.reviewDate(date: .abbreviated, time: .omitted), symbol: "clock")
          if !item.parts.isEmpty { InventorySeparator() }
        }
        let parts = item.parts.sorted {
          $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        InventoryRows(parts, id: \.key) { part in
          InventoryReadout(title: ReviewLanguage.text(part.key), amount: byteLabel(part.value),
            symbol: result.map { $0.detailDirectories[part.key] == nil ? "doc" : "folder" } ?? "folder")
        }
      }
    }
  }
}

struct ActionBadge: View {
  let action: CleanupAction
  var item: ReportItem? = nil
  var body: some View {
    if let risk = action.safety(for: item) {
      SafetyBadge(level: risk)
    } else {
      Text(ReviewLanguage.text(action.statusKey))
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }
  }
}
