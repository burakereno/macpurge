import SwiftUI

#if SWIFT_PACKAGE
  import MacPurgeCore
#endif

/// The shared geometry for every content list. Keep screen-specific spacing out of callers.
enum InventoryLayout {
  static let horizontalPadding = ListCardLayout.horizontalPadding
  static let verticalPadding = ListCardLayout.verticalPadding
  static let detailVerticalPadding: CGFloat = 12
  static let selectionWidth: CGFloat = 18
  static let disclosureWidth: CGFloat = 12
  static let actionWidth: CGFloat = 26
  static let controlSpacing: CGFloat = 6
  static let detailIndent: CGFloat = 32
  static let nestedIndent: CGFloat = 29
}

enum InventorySelection {
  case none, mixed, all

  init(eligible: Set<String>, selected: Set<String>) {
    if eligible.isDisjoint(with: selected) { self = .none }
    else if eligible.isSubset(of: selected) { self = .all }
    else { self = .mixed }
  }

  var label: String {
    switch self {
    case .none: "Not selected"
    case .mixed: "Partially selected"
    case .all: "Selected"
    }
  }

  var mark: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4)
        .fill(self == .none ? Color.primary.opacity(0.12) : Ink.sea)
      if self != .none {
        Image(systemName: self == .all ? "checkmark" : "minus")
          .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
      }
    }
    .frame(width: 16, height: 16)
    .frame(width: InventoryLayout.selectionWidth)
    .accessibilityHidden(true)
  }
}

struct DetailCardIcon: View {
  let symbol: String
  var path: String? = nil
  @State private var icon: NSImage?

  var body: some View {
    Group {
      if let icon { Image(nsImage: icon).resizable().scaledToFit() }
      else { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary) }
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
    .task(id: path) { icon = path.map { NSWorkspace.shared.icon(forFile: $0) } }
  }
}

private extension EnvironmentValues {
  @Entry var inventoryRowFrames: Bool = false
  @Entry var inventoryCardTrailingInset: CGFloat = 0
  @Entry var inventoryBorderlessCards = false
}

struct InventoryList<Item, ID: Hashable, Row: View>: View {
  @Environment(\.workspaceListLayout) private var layout
  let id: KeyPath<Item, ID>
  let items: [Item]
  let borderless: Bool
  @ViewBuilder let row: (Item) -> Row

  init(_ items: [Item], id: KeyPath<Item, ID>, borderless: Bool = false, @ViewBuilder row: @escaping (Item) -> Row) {
    self.id = id
    self.items = items
    self.borderless = borderless
    self.row = row
  }

  var body: some View {
    InventoryRows(items, id: id, row: row)
      .environment(\.inventoryRowFrames, true)
      .environment(\.inventoryBorderlessCards, borderless)
      .padding(.vertical, layout == .overview ? SurfaceCorners.rowInset : 0)
  }
}

extension InventoryList where Item: Identifiable, ID == Item.ID {
  init(_ items: [Item], borderless: Bool = false, @ViewBuilder row: @escaping (Item) -> Row) {
    self.init(items, id: \.id, borderless: borderless, row: row)
  }
}

/// Nested rows inherit their enclosing list or detail layout.
struct InventoryRows<Item, ID: Hashable, Row: View>: View {
  let items: [Item]
  let id: KeyPath<Item, ID>
  @ViewBuilder let row: (Item) -> Row
  @Environment(\.inventoryRowFrames) private var framed
  @Environment(\.workspaceListLayout) private var layout

  init(_ items: [Item], id: KeyPath<Item, ID>, @ViewBuilder row: @escaping (Item) -> Row) {
    self.items = items
    self.id = id
    self.row = row
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: framed && layout == .standard ? layout.cardSpacing : 0) {
      ForEach(items, id: id) { item in
        row(item)
        if !framed, item[keyPath: id] != items.last?[keyPath: id] {
          InventorySeparator()
        }
      }
    }
  }
}

struct InventorySeparator: View {
  @Environment(\.inventoryRowFrames) private var framed
  var body: some View {
    if !framed { Divider() }
  }
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
  var icon: NSImage? = nil
  @ViewBuilder let badges: Badges

  var body: some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      HStack(spacing: 11) {
        Group {
          if let icon { Image(nsImage: icon).resizable().scaledToFit() }
          else { Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint) }
        }.frame(width: 22, height: 22).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
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

extension View {
  /// A composite row can limit its hover to the header.
  func inventoryRowCard(hovered: Bool? = nil, isExpanded: Bool = false) -> some View {
    modifier(InventoryRowCard(hovered: hovered, isExpanded: isExpanded))
  }

  /// Information inside a card uses separators instead of additional cards.
  func inventoryRowDetails() -> some View { environment(\.inventoryRowFrames, false) }

  /// Inset the nested frames without moving the shared trailing amount and action columns.
  func inventoryNestedCards() -> some View {
    modifier(InventoryNestedCards())
  }
}

private struct InventoryNestedCards: ViewModifier {
  @Environment(\.workspaceListLayout) private var layout

  func body(content: Content) -> some View {
    let inset = layout.cardSpacing / 2
    content.padding(.leading, InventoryLayout.nestedIndent)
      .padding(.bottom, inset)
      .transformEnvironment(\.inventoryCardTrailingInset) { $0 += inset }
  }
}

private struct InventoryRowCard: ViewModifier {
  let hovered: Bool?
  let isExpanded: Bool
  @Environment(\.inventoryRowFrames) private var framed
  @Environment(\.inventoryBorderlessCards) private var borderless
  @Environment(\.inventoryCardTrailingInset) private var trailingInset
  @Environment(\.workspaceListLayout) private var layout
  @State private var pointerInside = false

  func body(content: Content) -> some View {
    if framed {
      let highlighted = !isExpanded && (hovered ?? pointerInside)
      let card = Group {
        if borderless {
          content.detailCardSurface(highlighted: highlighted, trailingInset: trailingInset)
        } else {
          content.listCardSurface(hovered: highlighted, trailingInset: trailingInset)
        }
      }
      Group {
        if hovered == nil {
          card.contentShape(Rectangle()).onHover { pointerInside = $0 }
        } else {
          card
        }
      }
      .padding(.vertical, layout == .overview ? layout.cardSpacing / 2 : 0)
    } else {
      content
    }
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
            .foregroundStyle((!isExpanded && hovering) || focused ? .primary : .secondary)
            .frame(width: 12).accessibilityHidden(true)
          label
        }
        .padding(.leading, InventoryLayout.horizontalPadding
          + (hasSelectionControl ? InventoryLayout.selectionWidth + InventoryLayout.controlSpacing : 0))
        .padding(.trailing, InventoryLayout.horizontalPadding)
        .padding(.vertical, InventoryLayout.verticalPadding)
        .padding(.trailing, InventoryLayout.actionWidth + InventoryLayout.controlSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
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
          .help(ReviewLanguage.text(selectionHelp)).disabled(busy)
          .frame(width: InventoryLayout.selectionWidth)
          .padding(.leading, InventoryLayout.horizontalPadding)
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
          .disabled(busy)
          .frame(width: InventoryLayout.selectionWidth)
          .padding(.leading, InventoryLayout.horizontalPadding)
        }
      }
      .overlay(alignment: .trailing) { accessory.padding(.trailing, InventoryLayout.horizontalPadding) }
      .onHover { hovering = $0 }
      .inventoryRowDetails()
      if isExpanded {
        content().inventoryNestedCards()
      }
    }
    .inventoryRowCard(hovered: hovering, isExpanded: isExpanded)
  }
}

/// Keep the action columns in place while the pointer moves between the label and its buttons.
struct InventoryRow: View {
  struct FileSelection {
    let id: String
    let action: CleanupAction
    let symbol: String
    var iconPath: String? = nil
    var required = false
  }

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
  var fileSelection: FileSelection? = nil
  @State private var showsPath = false
  private var isExpanded: Bool? { expanded ?? (location == nil || fileSelection != nil ? nil : showsPath) }
  @State private var hovering = false
  @FocusState private var folderFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      controls
      if toggleDetails == nil, showsPath, let location {
        Text(location.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
          .textSelection(.enabled).padding(.leading, InventoryLayout.detailIndent)
          .padding(.vertical, InventoryLayout.detailVerticalPadding)
      }
    }
    .inventoryRowDetails()
    .inventoryRowCard(isExpanded: isExpanded == true)
  }

  private var controls: some View {
    let decision = fileSelection?.action ?? scan.action(for: item)
    let state = decision.availability
    return Group {
      if let fileSelection {
        fileControls(fileSelection, decision: decision)
      } else {
        inventoryControls(decision)
      }
    }
    .foregroundStyle(.primary)
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

  private func inventoryControls(_ decision: CleanupAction) -> some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      Group {
        if decision.availability == .ready, let id = item?.id {
          Toggle(isOn: selection(for: id)) { Text(title) }
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

      folderAction
      trailingAction(decision)
    }
    .padding(.horizontal, InventoryLayout.horizontalPadding)
    .padding(.vertical, InventoryLayout.verticalPadding)
  }

  private func fileControls(_ file: FileSelection, decision: CleanupAction) -> some View {
    let mark: InventorySelection = selected.contains(file.id) ? .all : .none
    let ready = decision.availability == .ready
    let label = HStack(spacing: 12) {
      if ready { mark.mark }
      else { Color.clear.frame(width: InventoryLayout.selectionWidth).accessibilityHidden(true) }
      DetailCardIcon(symbol: file.symbol, path: file.iconPath)
      rowLabel(decision)
    }
    .padding(.leading, InventoryLayout.horizontalPadding)
    .padding(.trailing, InventoryLayout.horizontalPadding + 2 * (InventoryLayout.actionWidth + InventoryLayout.controlSpacing))
    .padding(.vertical, InventoryLayout.verticalPadding)
    .contentShape(Rectangle())

    return Group {
      if ready {
        Button { selection(for: file.id).wrappedValue.toggle() } label: { label }
          .buttonStyle(.plain)
          .focusEffectDisabled()
          .disabled(file.required || scan.cleanup.busy || inPlan == true)
          .accessibilityValue(ReviewLanguage.text(mark.label))
          .accessibilityHint(Text("Toggle selection"))
      } else {
        label
      }
    }
    .overlay(alignment: .trailing) {
      HStack(spacing: InventoryLayout.controlSpacing) {
        folderAction
        trailingAction(decision)
      }
      .padding(.trailing, InventoryLayout.horizontalPadding)
    }
  }

  private func selection(for id: String) -> Binding<Bool> {
    Binding(get: { selected.contains(id) }, set: { on in
      if on { selected.insert(id) } else { selected.remove(id) }
    })
  }

  private var folderAction: some View {
    Button(action: openLocation) {
      Image(systemName: "folder").frame(width: InventoryLayout.actionWidth, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).focused($folderFocused)
    .opacity(location != nil && (hovering || folderFocused) ? 1 : 0)
    .disabled(location == nil)
    .accessibilityLabel(ReviewLanguage.text("Finder’da aç") + " · " + title)
    .help("Finder’da aç")
  }

  private func trailingAction(_ decision: CleanupAction) -> some View {
    Group {
      if inPlan == true {
        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
          .help("Planda")
      } else if inPlan == nil, let item {
        ItemTrashButton(scan: scan, item: item, onlyPath: onlyPath)
      } else if fileSelection != nil, let reason = decision.availability.explanation {
        RowMoveButton(title: title, reason: reason, busy: false) {}
      } else { Color.clear.allowsHitTesting(false).accessibilityHidden(true) }
    }
    .frame(width: InventoryLayout.actionWidth)
  }

  private func rowLabel(_ decision: CleanupAction) -> some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      if fileSelection == nil {
        Group {
          if let isExpanded {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
              .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
          } else { Color.clear.accessibilityHidden(true) }
        }.frame(width: InventoryLayout.disclosureWidth)
      }
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
          if fileSelection == nil { ActionBadge(action: decision, item: item) }
        }
        if let caption = caption ?? decision.availability.explanation
          ?? item.map({ scan.actionDescription($0) })
        {
          Text(caption).font(.caption).foregroundStyle(.secondary)
            .lineLimit(2).help(caption)
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
  @Environment(\.inventoryRowFrames) private var framed
  @State private var hovering = false
  @FocusState private var folderFocused: Bool

  var body: some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      Image(systemName: symbol).foregroundStyle(tint).frame(width: 22).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: framed ? 5 : 3) {
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
    .padding(.vertical, framed ? InventoryLayout.verticalPadding : InventoryLayout.detailVerticalPadding)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .inventoryRowCard(hovered: hovering)
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
    .inventoryRowDetails()
    .inventoryRowCard(isExpanded: expanded)
    .onKeyPress(.rightArrow) { expanded = true; return .handled }
    .onKeyPress(.leftArrow) { expanded = false; return .handled }
  }
}

struct InventoryItemDetails: View {
  let item: ReportItem
  var result: RootSize? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      InventoryExplanationView(item: item)
      Text(item.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        .textSelection(.enabled).padding(.leading, InventoryLayout.detailIndent)
        .padding(.vertical, InventoryLayout.detailVerticalPadding)
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
    if case .inUse(let reason) = action.availability {
      Text(ReviewLanguage.text("Kullanımda"))
        .font(.caption.weight(.medium)).foregroundStyle(.secondary).help(reason)
    } else if let risk = action.safety(for: item) {
      SafetyBadge(level: risk)
    } else {
      Text(ReviewLanguage.text(action.statusKey))
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }
  }
}
