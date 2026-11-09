import Foundation
import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct DiskBreakdownTests {
    private let disk = VolumeReading(name: "Disk", bytes: 1_000, free: 200)

    @Test func measuredCategoriesAndRemainderFillTheVolume() {
        let model = DiskBreakdown(reading: disk,
            sizes: [.apps: .bytes(300, lowerBound: false), .xcode: .bytes(100, lowerBound: true),
                .packages: .waiting, .temp: .unavailable, .models: .outsideScope],
            safeBytes: 40, safeByGroup: [.xcode: 40])
        #expect(model.categories.map(\.group) == [.apps, .xcode])
        #expect(model.categories.last?.lowerBound == true)
        #expect(model.other == 400)
        #expect(model.categories.last?.safeBytes == 40)
        let total = model.categories.reduce(0) { $0 + model.fraction(for: $1) }
            + model.fraction(model.other) + model.fraction(model.usage.free)
        #expect(abs(total - 1) < 0.000001)
    }

    @Test func categoriesSortBeforeRenderingWithStableTies() {
        let model = DiskBreakdown(reading: disk,
            sizes: [.apps: .bytes(100, lowerBound: false), .docker: .bytes(100, lowerBound: false),
                .xcode: .bytes(200, lowerBound: false), .temp: .bytes(0, lowerBound: false)],
            safeBytes: 0, safeByGroup: [:])
        #expect(model.categories.map(\.group) == [.xcode, .docker, .apps])
        #expect(model.usage.safe == 0)
    }

    @Test func pendingCleanupDoesNotPlotUnverifiedStripes() {
        let model = DiskBreakdown(reading: disk,
            sizes: [.xcode: .bytes(100, lowerBound: false)],
            safeBytes: nil, safeByGroup: [.xcode: 90])
        #expect(model.usage.safe == nil)
        #expect(model.categories.first?.safeBytes == 0)
        #expect(model.other == 700)
    }

    @Test func staleReadingsKeepMeasuredLabelsAndBoundThePlot() {
        let model = DiskBreakdown(reading: disk,
            sizes: [.apps: .bytes(900, lowerBound: false), .xcode: .bytes(300, lowerBound: false)],
            safeBytes: 400, safeByGroup: [.xcode: 400, .apps: -1])
        #expect(model.hasOverlappingReadings)
        #expect(model.categories.map(\.bytes) == [900, 300])
        #expect(model.categories.map(\.safeBytes) == [0, 300])
        #expect(model.other == 0)
        #expect(abs(model.categories.reduce(0) { $0 + model.fraction(for: $1) } - 0.8) < 0.000001)
    }

    @Test func missingAndExtremeMeasurementsStayFinite() {
        let empty = DiskBreakdown(reading: .init(name: "Disk", bytes: -1, free: -2),
            sizes: [.xcode: .bytes(-3, lowerBound: false)], safeBytes: nil, safeByGroup: [:])
        #expect(empty.categories.isEmpty && empty.other == 0)
        #expect(empty.fraction(0) == 0)
        let huge = DiskBreakdown(reading: .init(name: "Disk", bytes: .max, free: 0),
            sizes: [.apps: .bytes(.max, lowerBound: false), .xcode: .bytes(.max, lowerBound: false)],
            safeBytes: 0, safeByGroup: [:])
        #expect(huge.other == 0)
        #expect(huge.categories.allSatisfy { huge.fraction(for: $0).isFinite })
    }

    @Test func externalProjectMeasurementsDoNotFillTheStartupDisk() {
        func project(_ id: String, bytes: Int64, volume: Int32, group: ScanGroup = .projects) -> ReportItem {
            .init(id: id, name: id, category: group.rawValue,
                path: "/" + id, bytes: bytes, status: "complete", safety: nil,
                reason: "", basis: "allocated", eligibleBytes: 0,
                modified: nil, parts: [:], volume: volume)
        }
        let report = ScanReport(id: UUID(), date: .now, extended: true, free: 200,
            capacity: 1_000, items: [project("local", bytes: 100, volume: 1),
                project("external", bytes: 500, volume: 2),
                project("large-external-folder", bytes: 200, volume: 2, group: .other)],
            groups: [ScanGroup.projects.rawValue: 600, ScanGroup.other.rawValue: 200])
        let sizes = DiskBreakdown.sizes(in: report, pending: [], volumeDevice: 1)
        #expect(sizes[.projects] == .bytes(100, lowerBound: true))
        #expect(sizes[.other] == .bytes(0, lowerBound: true))
        #expect(DiskBreakdown.sizes(in: nil, pending: [.apps], volumeDevice: 1)[.apps] == .waiting)
    }
}
