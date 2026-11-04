import SwiftUI

enum Ink {
    static let sea = Color(red: 0.12, green: 0.53, blue: 0.46)
    static let sky = Color(red: 0.30, green: 0.44, blue: 0.76)
    static let gold = Color(red: 0.72, green: 0.48, blue: 0.17)
    static let mint = Color(red: 0.63, green: 0.94, blue: 0.79)
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

struct LayerMark: View {
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<3 {
                let y = CGFloat(i) * 0.19 + 0.12
                var p = Path()
                for (j, vertex) in [(0.12, y + 0.15), (0.51, y), (0.88, y + 0.15), (0.49, y + 0.31)].enumerated() {
                    let point = CGPoint(x: vertex.0 * size.width, y: vertex.1 * size.height)
                    if j == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
                p.closeSubpath()
                ctx.fill(p, with: .color([Ink.mint, Color(red: 0.33, green: 0.79, blue: 0.67), Ink.sea][i]))
            }
        }
        .accessibilityHidden(true)
    }
}

enum SurfaceCorners {
    static let radius: CGFloat = 15
    static let rowInset: CGFloat = 4
    static let rowRadius = radius - rowInset
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

struct Page<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 23) { content }
                    .frame(maxWidth: 890, alignment: .leading)
                    .padding(.horizontal, geometry.size.width < 650 ? 22 : 38)
                    .padding(.top, 17).padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct PageTitle: View {
    let kicker: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(ReviewLanguage.text(kicker).uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.55).foregroundStyle(.secondary)
            Text(ReviewLanguage.text(title)).font(.system(size: 34, weight: .bold)).tracking(-1.2)
                .accessibilityAddTraits(.isHeader)
            Text(ReviewLanguage.text(subtitle)).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
        if #available(macOS 26, *) {
            Button(action: action) { Label(ReviewLanguage.text(title), systemImage: symbol) }
                .buttonStyle(.glassProminent).tint(Ink.sea).controlSize(.large)
        } else {
            Button(action: action) { Label(ReviewLanguage.text(title), systemImage: symbol) }
                .buttonStyle(.borderedProminent).tint(Ink.sea).controlSize(.large)
        }
    }
}
