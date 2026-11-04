import Testing

@testable import MacPurge
@testable import MacPurgeCore

struct DiskViewTests {
    @Test func partitionsMatchPhysicalCapacity() {
        let usage = DiskUsage(reading: .init(name: "Disk", bytes: 500, free: 120), safeBytes: 35)
        #expect(usage.safe == 35)
        #expect(usage.other == 345)
        #expect((usage.safe ?? 0) + usage.other + usage.free == usage.capacity)
    }

    @Test func pendingAndMeasuredZeroRemainDistinct() {
        let disk = VolumeReading(name: "Disk", bytes: 500, free: 120)
        let pending = DiskUsage(reading: disk, safeBytes: nil)
        let finished = DiskUsage(reading: disk, safeBytes: 0)
        #expect(pending.safe == nil && pending.other == 380)
        #expect(finished.safe == 0 && finished.other == 380)
    }

    @Test func staleCandidatesCannotExceedUsedSpace() {
        let usage = DiskUsage(reading: .init(name: "Disk", bytes: 500, free: 450), safeBytes: 100)
        #expect(usage.safe == 50 && usage.other == 0 && usage.free == 450)
    }

    @Test func invalidReadingsProduceNonnegativePartitions() {
        let empty = DiskUsage(reading: .init(name: "Disk", bytes: 0, free: 1), safeBytes: 1)
        #expect(empty.capacity == 0 && empty.free == 0 && empty.safe == 0 && empty.other == 0)
        let negative = DiskUsage(reading: .init(name: "Disk", bytes: -1, free: -2), safeBytes: -3)
        #expect(negative.capacity == 0 && negative.free == 0 && negative.safe == 0)
        let overfull = DiskUsage(reading: .init(name: "Disk", bytes: 500, free: 600), safeBytes: 50)
        #expect(overfull.free == 500 && overfull.used == 0 && overfull.safe == 0)
    }
}
