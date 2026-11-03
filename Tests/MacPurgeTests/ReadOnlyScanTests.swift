import Darwin
import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct ReadOnlyScanTests {
    private func withFixture(_ run: (URL) async throws -> Void) async throws {
        let base = URL(fileURLWithPath: "/private/tmp").appending(path: "MacPurge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await run(base)
    }

    @Test func measuresAllocatedBlocksOnceAndPreservesSelectedTree() async throws {
        try await withFixture { base in
            let root = base.appending(path: "Project")
            let build = root.appending(path: ".build")
            let external = base.appending(path: "external")
            let fm = FileManager.default
            try fm.createDirectory(at: build, withIntermediateDirectories: true)
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            let payload = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0) })
            let file = build.appending(path: "output")
            try payload.write(to: file)
            try fm.linkItem(at: file, to: root.appending(path: "another-name"))
            try payload.write(to: external.appending(path: "private"))
            let sym = root.appending(path: "outside")
            try fm.createSymbolicLink(at: sym, withDestinationURL: external)
            let sparse = root.appending(path: "sparse")
            try Data([1]).write(to: sparse)
            let handle = try FileHandle(forWritingTo: sparse)
            try handle.truncate(atOffset: 32_000_000)
            try handle.close()
            func allocation(_ url: URL) throws -> Int64 {
                var st = stat()
                try #require(lstat(url.path, &st) == 0)
                return Int64(st.st_blocks) * 512
            }
            let expected = try allocation(file) + allocation(sparse)
            let outputBytes = try allocation(file)
            let before = try fm.subpathsOfDirectory(atPath: root.path).sorted()
            let result = try await StorageMeter.measure(.init(group: .projects, title: "Project", url: root))
            #expect(result.state == .complete)
            #expect(result.bytes == expected && result.bytes < 32_000_000)
            #expect(result.outputBytes == outputBytes)
            #expect(result.files == 2)
            #expect(try Data(contentsOf: file) == payload)
            #expect(try fm.subpathsOfDirectory(atPath: root.path).sorted() == before)
            #expect(try fm.destinationOfSymbolicLink(atPath: sym.path) == external.path)
        }
    }

    @Test func separatesEmptyMissingAndUnavailableAndRejectsLinkedRoots() async throws {
        try await withFixture { base in
            let empty = base.appending(path: "empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let alias = base.appending(path: "alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: empty)
            let measured = try await StorageMeter.measure(.init(group: .projects, title: "", url: empty))
            #expect(measured.state == .complete && measured.bytes == 0)
            let missing = base.appending(path: "missing")
            let noCache = try await StorageMeter.measure(.init(group: .packages, title: "", url: missing))
            #expect(noCache.state == .absent)
            let offline = try await StorageMeter.measure(.init(group: .projects, title: "", url: missing))
            #expect(!offline.measured && offline.state != .absent)
            let linked = try await StorageMeter.measure(.init(group: .projects, title: "", url: alias))
            #expect(!linked.measured)
        }
    }

    @Test func deduplicatesHardLinksAcrossSiblingCacheRoots() async throws {
        try await withFixture { base in
            let dirs = ["one", "two"].map { base.appending(path: $0) }
            for dir in dirs { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            let file = dirs[0].appending(path: "file")
            try Data(repeating: 12, count: 16384).write(to: file)
            try FileManager.default.linkItem(at: file, to: dirs[1].appending(path: "alias"))
            var sizes: [RootSize] = []
            for dir in dirs {
                sizes.append(try await StorageMeter.measure(.init(group: .packages, title: "", url: dir)))
            }
            #expect(sizes[0].bytes > 0 && sizes[0].bytes == sizes[1].bytes)
            var group = GroupSize()
            for (dir, size) in zip(dirs, sizes) {
                try group.include(size, for: .init(group: .packages, title: "", url: dir))
            }
            #expect(group.bytes == sizes[0].bytes)
        }
    }

    @Test func sharedBytesBelongToReviewInEitherScanOrder() async throws {
        try await withFixture { base in
            let fm = FileManager.default
            let safe = ScanRoot(group: .packages, title: "npm", url: base.appending(path: "npm"), profile: .npmCache)
            let review = ScanRoot(group: .packages, title: "store", url: base.appending(path: "store"), profile: .sharedDependencies)
            for root in [safe, review] {
                try fm.createDirectory(at: root.url, withIntermediateDirectories: true)
            }
            func write(_ url: URL) throws -> Int64 {
                try Data(repeating: 9, count: 16384).write(to: url)
                var info = stat()
                try #require(lstat(url.path, &info) == 0 && info.st_blocks > 0)
                return Int64(info.st_blocks) * 512
            }
            let independent = try write(safe.url.appending(path: "local"))
            let shared = try write(review.url.appending(path: "shared"))
            try fm.linkItem(at: review.url.appending(path: "shared"), to: safe.url.appending(path: "alias"))
            for (first, next) in [(safe, review), (review, safe)] {
                let pass = try await StorageMeter.scan([first], onStart: { _ in }, onFinish: { _,_,_ in })
                let result = try await StorageMeter.scan([next], startingWith: pass, onStart: { _ in }, onFinish: { _,_,_ in })
                let split = try #require(result[.packages]?.breakdown)
                #expect(split.safe == independent && split.review == shared)
                #expect(split.total == independent + shared)
            }
        }
    }

    @Test func cancelledWorkerStopsEvenForAnEmptyRoot() async throws {
        try await withFixture { base in
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await StorageMeter.measure(.init(group: .projects, title: "", url: base))
            }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    @Test func deniedSubfolderProducesAPartialMeasurement() async throws {
        guard geteuid() != 0 else { return }
        try await withFixture { base in
            let denied = base.appending(path: "denied")
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
            try Data(repeating: 8, count: 4096).write(to: base.appending(path: "visible"))
            try #require(chmod(denied.path, 0) == 0)
            defer { _ = chmod(denied.path, 0o700) }
            let result = try await StorageMeter.measure(.init(group: .projects, title: "", url: base))
            #expect(result.state == .partial && result.missed == 1 && result.files == 1)
            let unreadable = try await StorageMeter.measure(.init(group: .projects, title: "", url: denied))
            #expect(unreadable.state == .unavailable("Erişim izni yok"))
        }
    }

    @Test func simulatorCacheAndDeviceDataPartitionTheSameFootprint() async throws {
        try await withFixture { base in
            let fm = FileManager.default
            let root = base.appending(path: UUID().uuidString)
            let app = "data/Containers/Data/Application/\(UUID().uuidString)"
            func file(_ relative: String) throws -> (URL, Int64) {
                let url = root.appending(path: relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 17, count: 8192).write(to: url)
                var info = stat()
                try #require(lstat(url.path, &info) == 0)
                return (url, Int64(info.st_blocks) * 512)
            }
            let cachePaths = ["data/Library/Caches/device", "data/tmp/session", app + "/Library/Caches/cache", app + "/tmp/temp"]
            let cache = try cachePaths.map(file)
            // A second name in the cache must not inflate the cache total.
            try fm.linkItem(at: cache[0].0, to: root.appending(path: "data/tmp/alias"))
            let reviewPaths = [app + "/Documents/Caches/personal", app + "/Documents/tmp/personal",
                               "data/Containers/Data/Application/not-a-uuid/Library/Caches/unknown", "data/Library/Preferences/settings"]
            let review = try reviewPaths.map(file)
            // A cache link backed by personal data belongs to Review regardless of visit order.
            try fm.linkItem(at: review[0].0, to: root.appending(path: "data/tmp/shared"))
            let mixed = try file("data/tmp/external-link")
            try fm.linkItem(at: mixed.0, to: base.appending(path: "outside"))
            try fm.createSymbolicLink(at: root.appending(path: "data/tmp/symlink"), withDestinationURL: base)
            let row = try await StorageMeter.measure(ScanRoot(group: .simulators, title: "", url: root))
            let expectedCache = cache.reduce(Int64(0)) { $0 + $1.1 }
            let expectedData = review.reduce(mixed.1) { $0 + $1.1 }
            #expect(expectedCache > 0 && expectedData > 0)
            #expect(row.state == .complete && row.simulatorCacheBytes == expectedCache)
            #expect(row.simulatorDataBytes == expectedData && row.bytes == expectedCache + expectedData)
            let device = SimulatorDevice(id: UUID(), name: "Test device", runtime: nil)
            let deviceRoot = ScanRoot(group: .simulators, title: device.name, url: root, device: device)
            var complete = GroupSize()
            try complete.include(row, for: deviceRoot)
            #expect(complete.breakdown?.safe == expectedCache && complete.breakdown?.review == expectedData)
            var partialRow = row
            partialRow.state = .partial
            var partial = GroupSize()
            try partial.include(partialRow, for: deviceRoot)
            #expect(partial.breakdown?.safe == 0 && partial.breakdown?.review == expectedCache + expectedData)
            #expect(StorageProfile.simulatorCache.assessment(for: row.state)?.level == .safe)
            #expect(StorageProfile.simulatorData.assessment(for: row.state)?.level == .review)
            #expect(StorageProfile.simulatorCache.assessment(for: .partial)?.level == .review)
            #expect(StorageProfile.simulatorCache.assessment(for: .unavailable("Erişim izni yok")) == nil)
        }
    }

    @Test func simulatorDiscoveryReadsOnlyLocalUUIDDirectoriesAndKeepsNamesakes() async throws {
        try await withFixture { base in
            let fm = FileManager.default
            let ids = [UUID(), UUID(), UUID()]
            for (i, id) in ids.enumerated() {
                let directory = base.appending(path: id.uuidString)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                if i < 2 {
                    let plist = try PropertyListSerialization.data(fromPropertyList:
                        ["name": "Test Phone", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-\(i)"], format: .binary, options: 0)
                    try plist.write(to: directory.appending(path: "device.plist"))
                }
            }
            try fm.createDirectory(at: base.appending(path: "Caches"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: base.appending(path: UUID().uuidString), withDestinationURL: base)
            let inventory = try await SimulatorInventory.discover(in: base)
            #expect(inventory.note == nil && inventory.roots.count == 3)
            #expect(Set(inventory.roots.compactMap { $0.device?.id }) == Set(ids))
            #expect(inventory.roots.filter { $0.title == "Test Phone" }.count == 2)
            #expect(inventory.roots.contains { $0.title == "Adsız simülatör" })
            #expect(inventory.roots.contains { $0.device?.detail.hasPrefix("iOS 27.1") == true })
            let absent = try await SimulatorInventory.discover(in: base.appending(path: "absent"))
            #expect(absent.roots.isEmpty && absent.note == nil)
        }
    }
}
