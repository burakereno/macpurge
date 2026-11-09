import SwiftUI

enum Ink {
    static let sea = Color(red: 0.12, green: 0.53, blue: 0.46)
    static let sky = Color(red: 0.30, green: 0.44, blue: 0.76)
    static let gold = Color(red: 0.72, green: 0.48, blue: 0.17)
    static let mint = Color(red: 0.63, green: 0.94, blue: 0.79)
}

struct SidebarLabel: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let title: LocalizedStringKey
    let symbol: String
    let selected: Bool

    init(_ title: LocalizedStringKey, symbol: String, selected: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title).fontWeight(selected ? .semibold : .regular)
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .background { SidebarSelectionAppearance().accessibilityHidden(true).allowsHitTesting(false) }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .labelColor).opacity(selected ? (contrast == .increased ? 0.18 : 0.09) : 0))
                .padding(.horizontal, 10)
        )
    }
}

// Keep the native list selection and keyboard navigation. SwiftUI draws its neutral fill.
private struct SidebarSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.hideSystemHighlight() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hideSystemHighlight()
        }

        func hideSystemHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSOutlineView {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 39, height: 39)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}

@MainActor
struct LayerMark: View {
    private static let image: NSImage = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon.icns"
        if let url = Bundle.main.url(forResource: name, withExtension: nil),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

enum SurfaceCorners {
    static let radius: CGFloat = 15
    static let rowInset: CGFloat = 4
}

enum ListCardLayout {
    static let spacing: CGFloat = 12
    static let detailSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 15
}

extension View {
    func detailCardSurface(highlighted: Bool, trailingInset: CGFloat = 0) -> some View {
        background {
            RoundedRectangle(cornerRadius: SurfaceCorners.radius, style: .continuous)
                .fill(.primary.opacity(highlighted ? 0.09 : 0.055))
                .padding(.trailing, trailingInset)
                .allowsHitTesting(false)
        }
    }

    func listCardSurface(hovered: Bool, pressed: Bool = false, trailingInset: CGFloat = 0) -> some View {
        let shape = RoundedRectangle(cornerRadius: SurfaceCorners.radius, style: .continuous)
        let fill = Color.primary.opacity(pressed ? 0.10 : hovered ? 0.075 : 0.025)
        let border = Color.primary.opacity(pressed ? 0.27 : hovered ? 0.22 : 0.10)
        return background {
            shape.fill(fill).padding(.trailing, trailingInset).allowsHitTesting(false)
        }
        .overlay {
            shape.strokeBorder(border).padding(.trailing, trailingInset)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SurfaceCorners.radius, style: .continuous)
        content
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.09)) }
    }
}

struct WorkspaceDetailSurface: ViewModifier {
    static let darkBackground = NSColor(srgbRed: 25 / 255, green: 25 / 255, blue: 25 / 255, alpha: 1)

    @Environment(\.colorScheme) private var scheme

    static func background(in scheme: ColorScheme) -> Color {
        Color(nsColor: scheme == .dark ? darkBackground : .windowBackgroundColor)
    }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(scheme == .dark ? .hidden : .automatic)
            .background {
                (scheme == .dark ? Self.background(in: scheme) : .clear)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
    }
}

enum WorkspaceLayout {
    static let contentInset: CGFloat = 20
    static let headerVerticalInset: CGFloat = 14
    static let listBarVerticalInset: CGFloat = 8
}

enum WorkspaceListLayout {
    case standard, overview

    var cardSpacing: CGFloat {
        self == .standard ? ListCardLayout.detailSpacing : ListCardLayout.spacing
    }
}

extension EnvironmentValues {
    @Entry var workspaceListLayout = WorkspaceListLayout.overview
}

struct WorkspaceListBar<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceLayout.contentInset)
            .padding(.vertical, WorkspaceLayout.listBarVerticalInset)
            .background(WorkspaceDetailSurface.background(in: scheme))
    }
}

extension View {
    func workspaceListControls<Controls: View>(@ViewBuilder _ controls: () -> Controls) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            WorkspaceListBar(content: controls)
        }
    }
}

struct WorkspacePage<Header: View, Content: View>: View {
    var overviewLayout = false
    @ViewBuilder let header: Header
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { viewport in
            let inset = WorkspaceLayout.contentInset
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                content(inset)
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
        .environment(\.workspaceListLayout, overviewLayout ? .overview : .standard)
    }
}

struct Page<Header: View, Controls: View, Content: View>: View {
    let overviewLayout: Bool
    let contentBottomInset: CGFloat
    @ViewBuilder let header: Header
    @ViewBuilder let controls: Controls
    @ViewBuilder let content: Content

    init(overviewLayout: Bool = false, contentBottomInset: CGFloat = WorkspaceLayout.contentInset,
        @ViewBuilder header: () -> Header,
        @ViewBuilder controls: () -> Controls, @ViewBuilder content: () -> Content
    ) {
        self.overviewLayout = overviewLayout
        self.contentBottomInset = contentBottomInset
        self.header = header()
        self.controls = controls()
        self.content = content()
    }

    var body: some View {
        WorkspacePage(overviewLayout: overviewLayout) {
            header
        } content: { inset in
            VStack(spacing: 0) {
                if !overviewLayout { Divider() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, inset)
                        .padding(.top, overviewLayout ? 0 : inset)
                        .padding(.bottom, overviewLayout ? 0 : contentBottomInset)
                }
                .safeAreaInset(edge: .top, spacing: 0) { controls }
                .padding(.vertical, overviewLayout ? inset : 0)
            }
        }
    }
}

extension Page where Controls == EmptyView {
    init(overviewLayout: Bool = false, @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.init(overviewLayout: overviewLayout, header: header, controls: { EmptyView() }, content: content)
    }
}

struct WorkspaceBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(ReviewLanguage.text(title), systemImage: "chevron.backward")
        }
        .workspaceButton(.secondary)
        .keyboardShortcut("[", modifiers: .command)
    }
}

enum WorkspaceButtonKind {
    case primary, secondary, destructive
}

enum WorkspaceControlLayout {
    static let height: CGFloat = 28

    static var toolbarSize: ControlSize {
        if #available(macOS 26, *) { return .extraLarge }
        return .large
    }

    static var toolbarHeight: CGFloat {
        toolbarSize == .extraLarge ? 36 : height
    }
}

extension View {
    func workspaceButton(_ kind: WorkspaceButtonKind = .primary, controlSize: ControlSize = .large,
        borderShape: ButtonBorderShape = .capsule
    ) -> some View {
        workspaceButtonSurface(kind)
            .buttonBorderShape(borderShape)
            .controlSize(controlSize)
    }

    @ViewBuilder private func workspaceButtonSurface(_ kind: WorkspaceButtonKind) -> some View {
        if kind == .secondary {
            if #available(macOS 26, *) {
                buttonStyle(.glass).tint(nil)
            } else {
                buttonStyle(.bordered).tint(nil)
            }
        } else {
            let tint = kind == .destructive ? Color.red : Ink.sea
            if #available(macOS 26, *) {
                buttonStyle(.glassProminent).tint(tint)
            } else {
                buttonStyle(.borderedProminent).tint(tint)
            }
        }
    }
}

struct WorkspacePicker<Choice: Hashable>: View {
    enum Appearance { case flat, button }

    let label: LocalizedStringKey
    let choices: [Choice]
    @Binding var selection: Choice
    var width: CGFloat? = nil
    var appearance: Appearance = .flat
    let title: (Choice) -> Text

    var body: some View {
        let selectedTitle = title(selection)
        let menu = Menu {
            Picker(label, selection: $selection) {
                ForEach(choices, id: \.self) { choice in
                    title(choice).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            switch appearance {
            case .flat:
                selectedTitle.lineLimit(1)
                    .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
            case .button:
                HStack(spacing: 8) {
                    selectedTitle.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(height: WorkspaceControlLayout.height)
                .contentShape(.capsule)
            }
        }
        .menuStyle(.button)

        Group {
            switch appearance {
            case .flat:
                menu.buttonStyle(.borderless)
                    .tint(nil)
                    .padding(.horizontal, 14)
                    .frame(width: width)
                    .frame(minHeight: WorkspaceControlLayout.height)
                    .background(.primary.opacity(0.08), in: .capsule)
            case .button:
                let button = menu.menuIndicator(.hidden)
                if #available(macOS 26, *) {
                    button.buttonStyle(.plain).tint(nil)
                        .glassEffect(.regular.interactive(), in: .capsule)
                } else {
                    button.buttonStyle(.plain).tint(nil)
                        .background(.primary.opacity(0.08), in: .capsule)
                }
            }
        }
        .accessibilityLabel(Text(label))
        .accessibilityValue(selectedTitle)
    }
}

struct WorkspaceTabs<Choice: Hashable>: View {
    let label: LocalizedStringKey
    let choices: [Choice]
    @Binding var selection: Choice
    let title: (Choice) -> Text
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var focused: Choice?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    selection = choice
                    focused = choice
                } label: {
                    title(choice)
                }
                    .workspaceButton(selection == choice ? .primary : .secondary)
                    .accessibilityAddTraits(selection == choice ? .isSelected : [])
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused, equals: choice)
                    .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                        guard let index = choices.firstIndex(of: choice) else { return .ignored }
                        let forwards = (press.key == .rightArrow) == (layoutDirection == .leftToRight)
                        let next = index + (forwards ? 1 : -1)
                        if choices.indices.contains(next) {
                            selection = choices[next]
                            focused = choices[next]
                        }
                        return .handled
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct WorkspaceEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let description: String
    var note: String? = nil
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Ink.sea)
                .frame(width: 58, height: 58)
                .background(Ink.sea.opacity(0.13), in: .rect(cornerRadius: 16))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(ReviewLanguage.text(title)).font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(ReviewLanguage.text(description)).font(.callout).foregroundStyle(.secondary)
                if let note { Text(ReviewLanguage.text(note)).font(.caption).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    @Entry var workspaceHeaderControls: WorkspaceHeaderControls = .none
}

enum WorkspaceHeaderControls: View {
    case none
    case scan(LiveScan)
    case demo(WorkspaceDemoMenu)

    var body: some View {
        switch self {
        case .none: EmptyView()
        case .scan(let scan): WorkspaceScanControls(scan: scan)
        case .demo(let menu): menu
        }
    }
}

struct WorkspaceHeadingRow<Accessory: View>: View {
    @Environment(\.workspaceHeaderControls) private var controls
    let title: Text
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            title
                .font(.system(size: 34, weight: .bold)).tracking(-1.2)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
            if #available(macOS 15, *) {
                Spacer(minLength: 0).frame(height: WorkspaceControlLayout.toolbarHeight)
                    .contentShape(Rectangle()).gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            } else {
                Spacer(minLength: 0)
            }
            controls
            accessory
        }
        .padding(.vertical, WorkspaceLayout.contentInset)
    }
}

struct PageTitle<Actions: View>: View {
    @Environment(\.workspaceListLayout) private var listLayout
    let title: Text
    @ViewBuilder let actions: Actions

    init(title: Text, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    init(title: String, @ViewBuilder actions: () -> Actions) {
        self.init(title: Text(ReviewLanguage.text(title)), actions: actions)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            WorkspaceHeadingRow(title: title) { EmptyView() }
            if Actions.self != EmptyView.self {
                actions
                    .padding(.bottom, listLayout == .standard ? WorkspaceLayout.headerVerticalInset : 0)
            }
        }
    }
}

extension PageTitle where Actions == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct SectionHead: View {
    let title: String
    var note: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ReviewLanguage.text(title)).font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            if let note { Text(ReviewLanguage.text(note)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct ActionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let description: String
    let amount: String
    let action: () -> Void
    var body: some View {
        InventoryDisclosure(isExpanded: .constant(false), selectable: [], selected: .constant([]),
            busy: false, activate: action) {
            EmptyView()
        } label: {
            InventoryGroupHeader(title: title, symbol: symbol, tint: tint, amount: amount,
                subtitle: ReviewLanguage.text(description)) { EmptyView() }
        } accessory: { EmptyView() }

    }
}

struct Note: View {
    let symbol: String
    let text: String
    var body: some View {
        Label { Text(ReviewLanguage.text(text)).fixedSize(horizontal: false, vertical: true) }
            icon: { Image(systemName: symbol) }
            .font(.callout).foregroundStyle(.secondary)
    }
}

struct MainAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(ReviewLanguage.text(title), systemImage: symbol) }
            .workspaceButton()
    }
}
