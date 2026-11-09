import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct DiskCapacityMonitorTests {
  actor Reader {
    var calls = 0
    var succeeds = true
    var free: Int64 = 250
    func read(_ url: URL) -> VolumeReading? {
      calls += 1
      return succeeds ? VolumeReading(name: "Fixture", bytes: 1000, free: free) : nil
    }
    func fail() { succeeds = false }
    func change() { free = 100 }
  }

  @Test func presentationBoundsUsageAndPreferencesStayOptIn() {
    #expect(DiskStatusPresentation(nil) == nil)
    #expect(DiskStatusPresentation(.init(name: "bad", bytes: 0, free: 1)) == nil)
    let usage = DiskStatusPresentation(.init(name: "fixture", bytes: 1000, free: 250))
    #expect(usage?.usedFraction == 0.75 && usage?.usedPercent == 75)
    #expect(DiskStatusPresentation(.init(name: "fixture", bytes: 1000, free: -1))?.usedPercent == 100)
    #expect(DiskStatusPresentation(.init(name: "fixture", bytes: 1000, free: 2000))?.usedPercent == 0)
    #expect(!DiskStatusStyle.icon.showsFreeSpace && !DiskStatusStyle.icon.showsUsage)
    #expect(DiskStatusStyle.freeSpace.showsFreeSpace && !DiskStatusStyle.freeSpace.showsUsage)
    #expect(DiskStatusStyle.usage.showsUsage && !DiskStatusStyle.usage.showsFreeSpace)
    #expect(DiskStatusStyle.freeSpaceAndUsage.showsFreeSpace && DiskStatusStyle.freeSpaceAndUsage.showsUsage)
  }

  @MainActor @Test func refreshReadsOnlyInjectedCapacityAndClearsFailedReadings() async {
    let reader = Reader()
    let monitor = DiskCapacityMonitor(home: URL(fileURLWithPath: "/not-enumerated"), read: { await reader.read($0) })
    var updates = 0
    monitor.onUpdate = { updates += 1 }
    await monitor.refresh()
    #expect(monitor.reading?.free == 250 && monitor.measuredAt != nil && updates == 1)
    await reader.fail()
    await monitor.refresh()
    #expect(monitor.reading == nil && monitor.measuredAt == nil && updates == 2)
    #expect(await reader.calls == 2)
  }

  @MainActor @Test func repeatedStartCreatesOneReaderAndStopCancelsPolling() async throws {
    let reader = Reader()
    let monitor = DiskCapacityMonitor(home: URL(fileURLWithPath: "/not-enumerated"), interval: .seconds(30), read: { await reader.read($0) })
    monitor.start(); monitor.start()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while monitor.reading == nil && ContinuousClock.now < deadline { await Task.yield() }
    #expect(monitor.isRunning && monitor.reading?.free == 250)
    #expect(await reader.calls == 1)
    monitor.stop()
    #expect(!monitor.isRunning && monitor.reading == nil && monitor.measuredAt == nil)
    try await Task.sleep(for: .milliseconds(5))
    #expect(await reader.calls == 1)
  }

  @MainActor @Test func pollingPublishesFreshCapacityWithoutAnInventoryScan() async {
    let reader = Reader()
    let monitor = DiskCapacityMonitor(home: URL(fileURLWithPath: "/not-enumerated"), interval: .milliseconds(5), read: { await reader.read($0) })
    monitor.start()
    defer { monitor.stop() }
    await reader.change()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      let calls = await reader.calls
      if monitor.reading?.free == 100 && calls >= 2 { break }
      await Task.yield()
    }
    #expect(monitor.reading?.free == 100)
    #expect(await reader.calls >= 2)
  }
}
