#if SWIFT_PACKAGE
import MacPurgeCore
#endif
import Charts
import SwiftUI

/// Chart partitions are bounded by the volume, even if a measurement is stale.
struct DiskUsage {
    let capacity: Int64
    let free: Int64
    let safe: Int64?
    var used: Int64 { capacity - free }
    var other: Int64 { used - (safe ?? 0) }

    init(reading: VolumeReading, safeBytes: Int64?) {
        capacity = max(0, reading.bytes)
        free = min(capacity, max(0, reading.free))
        let usedBytes = capacity - free
        safe = safeBytes.map { min(usedBytes, max(0, $0)) }
    }
}

struct DiskView: View {
    let disk: VolumeReading
    let safeBytes: Int64?
    @Environment(\.colorSchemeContrast) private var contrast

    init(reading: VolumeReading, safeBytes: Int64? = nil) {
        disk = reading
        self.safeBytes = safeBytes
    }
    init(freeMB: Int, safeMB: Int) {
        disk = VolumeReading(name: "Macintosh HD", bytes: 512_000_000_000, free: Int64(freeMB) * 1_000_000)
        safeBytes = Int64(safeMB) * 1_000_000
    }

    var body: some View {
        let usage = DiskUsage(reading: disk, safeBytes: safeBytes)
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { volumeName; Spacer(minLength: 8); capacityLabel(usage) }
                VStack(alignment: .leading, spacing: 5) { volumeName; capacityLabel(usage) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    ring(usage).frame(width: 148, height: 148)
                    summary(usage).frame(minWidth: 180, idealWidth: 180, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 20) {
                    ring(usage).frame(width: 148, height: 148).frame(maxWidth: .infinity)
                    summary(usage)
                }
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
        .accessibilityElement(children: .combine)
    }

    private var volumeName: some View {
        Label(disk.name, systemImage: "internaldrive")
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1).truncationMode(.middle)
    }

    private func capacityLabel(_ usage: DiskUsage) -> some View {
        Text(ReviewLanguage.format("%@ toplam", byteLabel(usage.capacity)))
            .font(.caption.monospacedDigit()).foregroundStyle(secondaryInk)
            .fixedSize()
    }

    private func ring(_ usage: DiskUsage) -> some View {
        let segments: [(id: String, bytes: Int64, color: Color)] = [
            ("safe", usage.safe ?? 0, Ink.mint),
            ("other", usage.other, otherInk),
            ("free", usage.free, freeInk),
        ]
        return ZStack {
            Circle().stroke(.white.opacity(0.09), lineWidth: 14).padding(7)
            Chart(segments.filter { $0.bytes > 0 }, id: \.id) { segment in
                SectorMark(angle: .value("Bytes", segment.bytes), innerRadius: .ratio(0.81), angularInset: 2.5)
                    .cornerRadius(4)
                    .foregroundStyle(segment.color)
            }
            VStack(spacing: 3) {
                Text(byteLabel(usage.free))
                    .font(.system(size: 25, weight: .semibold)).tracking(-0.8)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(ReviewLanguage.text("Boş alan"))
                    .font(.caption).foregroundStyle(secondaryInk)
            }.padding(.horizontal, 21)
        }
        .accessibilityHidden(true)
    }

    private func summary(_ usage: DiskUsage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(usage.safe.map(byteLabel) ?? "—")
                    .font(.system(size: 32, weight: .semibold)).tracking(-1)
                    .monospacedDigit().foregroundStyle(Ink.mint)
                Text(ReviewLanguage.text("güvenli temizlenebilir alan"))
                    .font(.callout).foregroundStyle(secondaryInk)
            }
            VStack(spacing: 8) {
                amountRow("Güvenli", amount: usage.safe.map(byteLabel) ?? "—", color: Ink.mint)
                amountRow(usage.safe == nil ? "Kullanılan alan" : "Diğer kullanım",
                    amount: byteLabel(usage.other), color: otherInk)
                amountRow("Boş alan", amount: byteLabel(usage.free), color: freeInk)
            }
            Text(ReviewLanguage.text(usage.safe == nil
                ? "Güvenli alan tarama ve kontroller tamamlandığında gösterilir."
                : "Temizlemeden önce dosyaları ve etkilerini incele."))
                .font(.caption).foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func amountRow(_ title: String, amount: String, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(ReviewLanguage.text(title)).foregroundStyle(secondaryInk)
            Spacer(minLength: 12)
            Text(amount).fontWeight(.medium).monospacedDigit()
        }.font(.caption)
    }

    private var secondaryInk: Color { .white.opacity(contrast == .increased ? 1 : 0.76) }
    private var otherInk: Color { Color(red: 0.38, green: 0.62, blue: 0.59) }
    private var freeInk: Color { Color(red: 0.82, green: 0.88, blue: 0.86) }
}
