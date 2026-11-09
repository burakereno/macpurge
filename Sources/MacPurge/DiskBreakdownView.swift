import SwiftUI

#if SWIFT_PACKAGE
import MacPurgeCore
#endif

struct DiskBreakdownView: View {
    let disk: VolumeReading
    let breakdown: DiskBreakdown
    var updating = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 28) {
                    usedSummary
                    Spacer(minLength: 8)
                    metrics
                }
                VStack(alignment: .leading, spacing: 18) {
                    usedSummary
                    metrics
                }
            }
            capacityBar
            DiskLegendLayout(horizontalSpacing: 20, verticalSpacing: 10) {
                ForEach(breakdown.categories.prefix(6)) { category in
                    legend(title: ReviewLanguage.text(category.group.diskLegendTitleKey), amount: category.label,
                        color: category.group.diskColor)
                        .help(categoryHelp(category))
                }
                if breakdown.other > 0 {
                    legend(title: ReviewLanguage.text("Diğer disk kullanımı"),
                        amount: byteLabel(breakdown.other), color: otherColor)
                        .help(ReviewLanguage.text("Sistem verileri, tarama kapsamı dışındaki dosyalar ve ölçülemeyen alan. Temizlenebilir alan olarak değerlendirilmez."))
                }
            }
            if updating || breakdown.categories.isEmpty || breakdown.hasOverlappingReadings {
                Text(ReviewLanguage.text(statusText))
                    .font(.caption).foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [Color(red: 0.06, green: 0.17, blue: 0.18),
                Color(red: 0.09, green: 0.29, blue: 0.27)],
                startPoint: .bottomLeading, endPoint: .topTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var usedSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(disk.name, systemImage: "internaldrive")
                .font(.callout).foregroundStyle(secondaryInk)
                .lineLimit(1).truncationMode(.middle)
                .help(disk.name)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(byteLabel(breakdown.usage.used))
                    .font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                    .monospacedDigit()
                Text(ReviewLanguage.format("/ %@ kullanılıyor", byteLabel(breakdown.usage.capacity)))
                    .font(.callout).foregroundStyle(secondaryInk)
            }.fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 28) {
            metric("Boş alan", amount: byteLabel(breakdown.usage.free),
                help: "Diskte şu anda kullanılabilir olan alan.")
            metric("Güvenli temizlenebilir", amount: breakdown.usage.safe.map(byteLabel) ?? "—",
                help: "Taralı alanlar, doğrulanmış güvenli öğeler Çöp’e taşınıp Çöp boşaltıldıktan sonra geri kazanılabilecek tahmini alandır. Harici sabit bağlantılar dahil değildir.",
                tint: Ink.mint, striped: true)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func metric(_ title: String, amount: String, help: String, tint: Color = .white,
                        striped: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text(ReviewLanguage.text(title))
                Image(systemName: "info.circle").imageScale(.small).accessibilityHidden(true)
            }.font(.caption).foregroundStyle(secondaryInk)
            HStack(spacing: 7) {
                Text(amount).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                if striped {
                    RecoverableStripes().stroke(stripeColor, lineWidth: 1.5)
                        .background(.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .frame(width: 12, height: 12).accessibilityHidden(true)
                }
            }
        }
        .help(ReviewLanguage.text(help))
        .accessibilityElement(children: .combine)
        .accessibilityHint(ReviewLanguage.text(help))
    }

    private var capacityBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(breakdown.categories) { category in
                    Rectangle().fill(category.group.diskColor)
                        .overlay(alignment: .trailing) {
                            if category.safeBytes > 0 {
                                RecoverableStripes().stroke(stripeColor, lineWidth: 1.5)
                                    .frame(width: geometry.size.width * breakdown.fraction(for: category)
                                        * Double(category.safeBytes) / Double(category.bytes))
                                    .clipped()
                            }
                        }
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.22))
                                .frame(width: 1.5)
                        }
                        .frame(width: geometry.size.width * breakdown.fraction(for: category))
                        .help(categoryHelp(category))
                }
                if breakdown.other > 0 {
                    Rectangle().fill(otherColor)
                        .frame(width: geometry.size.width * breakdown.fraction(breakdown.other))
                        .help(ReviewLanguage.text("Diğer disk kullanımı") + " · " + byteLabel(breakdown.other))
                }
                Rectangle().fill(freeColor)
                    .frame(width: geometry.size.width * breakdown.fraction(breakdown.usage.free))
                    .help(ReviewLanguage.text("Boş alan") + " · " + byteLabel(breakdown.usage.free))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(freeColor)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.16)) }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    private func legend(title: String, amount: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .overlay { Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                .accessibilityHidden(true)
            Text(title).foregroundStyle(secondaryInk)
            Text(amount).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func categoryHelp(_ category: DiskBreakdown.Category) -> String {
        var text = ReviewLanguage.text(category.group.titleKey) + " · " + category.label
        if breakdown.usage.safe != nil {
            text += "\n" + ReviewLanguage.text("Güvenli temizlenebilir") + ": " + byteLabel(category.safeBytes)
        }
        if category.lowerBound {
            text += "\n" + ReviewLanguage.text("Yalnızca okunabilen dosyalar dahil.")
        }
        return text
    }

    private var statusText: String {
        if breakdown.hasOverlappingReadings {
            return "Kategori ölçümleri disk kullanımını aşıyor; grafik oranları mevcut kullanılan alana sığdırıldı."
        }
        if updating {
            return "Tarama sürüyor. Kategori ölçümleri tamamlandıkça güncellenir; güvenli alan kontrollerden sonra gösterilir."
        }
        return "Kategori dağılımı henüz ölçülmedi. Diğer disk kullanımı temizlenebilir alan anlamına gelmez."
    }

    private var secondaryInk: Color { .white.opacity(contrast == .increased ? 1 : 0.76) }
    private var otherColor: Color { .white.opacity(contrast == .increased ? 0.5 : 0.3) }
    private var freeColor: Color { .white.opacity(contrast == .increased ? 0.18 : 0.1) }
    private var stripeColor: Color { .white.opacity(contrast == .increased ? 1 : 0.85) }
}

private struct RecoverableStripes: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for x in stride(from: -rect.height, through: rect.width, by: 6) {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            }
        }
    }
}

/// Wrap the visible legend entries at their natural widths.
private struct DiskLegendLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, point) in layout.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}

private extension ScanGroup {
    var diskLegendTitleKey: String {
        switch self {
        case .apps: "Uygulama verileri"
        case .models: "AI modelleri"
        case .packages: "Paketler"
        case .logs: "Günlükler"
        case .tools: "Geliştirici araçları"
        case .simulators: "Simülatörler"
        default: titleKey
        }
    }

    var diskColor: Color {
        switch self {
        case .appCaches: .mint
        case .apps: .blue
        case .packages: .yellow
        case .xcode: .orange
        case .tools: .purple
        case .docker: .teal
        case .simulators: .indigo
        case .projects: .cyan
        case .logs: .brown
        case .runtimes: Color(red: 0.58, green: 0.46, blue: 0.92)
        case .models: .pink
        case .temp: Color(red: 0.80, green: 0.62, blue: 0.28)
        case .machines: Color(red: 0.28, green: 0.57, blue: 0.79)
        case .trash: .red
        case .backups: .green
        case .shared: Color(red: 0.53, green: 0.67, blue: 0.47)
        case .android: Color(red: 0.45, green: 0.72, blue: 0.28)
        case .system: .gray
        case .other: Color(red: 0.56, green: 0.49, blue: 0.42)
        case .snapshots: Color(red: 0.77, green: 0.43, blue: 0.64)
        case .downloads: .mint
        }
    }
}
