#if SWIFT_PACKAGE
import MacPurgeCore
#endif
import Foundation

/// Display-only values: category totals already account for duplicate files in the scan.
struct DiskBreakdown {
    struct Category: Identifiable {
        let group: ScanGroup
        let bytes: Int64
        let lowerBound: Bool
        let safeBytes: Int64
        var id: String { group.rawValue }
        var label: String { (lowerBound ? "≥ " : "") + byteLabel(bytes) }
    }

    let usage: DiskUsage
    let categories: [Category]
    let other: Int64
    let measuredBytes: Double
    var hasOverlappingReadings: Bool { measuredBytes > Double(usage.used) }

    init(reading: VolumeReading, sizes: [ScanGroup: CategorySize],
         safeBytes: Int64?, safeByGroup: [ScanGroup: Int64]) {
        usage = DiskUsage(reading: reading, safeBytes: safeBytes)
        categories = sizes.compactMap { group, size in
            guard case .bytes(let bytes, let lowerBound) = size, bytes > 0 else { return nil }
            return Category(group: group, bytes: bytes, lowerBound: lowerBound,
                safeBytes: safeBytes == nil ? 0 : min(bytes, max(0, safeByGroup[group] ?? 0)))
        }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        measuredBytes = categories.reduce(0) { $0 + Double($1.bytes) }
        other = measuredBytes >= Double(usage.used) ? 0 : usage.used - Int64(measuredBytes)
    }

    /// Stale readings can exceed current usage. Scale the plot, keeping measured labels intact.
    func fraction(for category: Category) -> Double {
        guard usage.capacity > 0, measuredBytes > 0 else { return 0 }
        return Double(category.bytes) / max(Double(usage.used), measuredBytes)
            * Double(usage.used) / Double(usage.capacity)
    }

    func fraction(_ bytes: Int64) -> Double {
        usage.capacity > 0 ? Double(bytes) / Double(usage.capacity) : 0
    }

    static func sizes(in report: ScanReport?, pending: Set<ScanGroup>,
                      volumeDevice: Int32?) -> [ScanGroup: CategorySize] {
        var sizes = Dictionary(uniqueKeysWithValues: ScanGroup.allCases.map {
            ($0, CategorySize.read($0, in: report, pending: pending))
        })
        // Selected projects and their large-folder details may be on external disks.
        // The other roots are restricted to the startup volume group by ScanVolumes.
        if let volumeDevice, let report {
            for group in [ScanGroup.projects, .other] {
                guard case .bytes(let bytes, _) = sizes[group] else { continue }
                let external = report.items.filter {
                    $0.category == group.rawValue && $0.volume != nil
                        && $0.volume != volumeDevice && ($0.bytes ?? 0) > 0
                }
                if !external.isEmpty {
                    let local = external.reduce(max(0, bytes)) { max(0, $0 - min($0, $1.bytes ?? 0)) }
                    // Row sums may include shared hard links, so retain a lower bound.
                    sizes[group] = .bytes(local, lowerBound: true)
                }
            }
        }
        return sizes
    }
}
