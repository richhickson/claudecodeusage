import XCTest
@testable import ClaudeUsage

final class UsageHistoryTests: XCTestCase {
    private let account = "someone@example.com"
    private let service = "Claude Code-credentials"

    private func usage(weekly: Double, resetsIn: TimeInterval) -> UsageData {
        UsageData(sessionUtilization: 10, sessionResetsAt: nil,
                  weeklyUtilization: weekly, weeklyResetsAt: Date().addingTimeInterval(resetsIn),
                  sonnetUtilization: nil, sonnetResetsAt: nil,
                  modelLimits: [],
                  extraUsageEnabled: false, extraUsageMonthlyLimit: nil, extraUsageUsedCredits: nil)
    }

    /// Ascending snapshots ending now, `hours` long, from `from` to `to` percent
    private func ramp(hours: Double, from: Double, to: Double) -> [UsageSnapshot] {
        let count = Int(hours * 12)   // one per 5 minutes
        return (0...count).map { i in
            UsageSnapshot(ts: Date().addingTimeInterval((-hours * 3600) + Double(i) * 300),
                          session: 10,
                          weekly: from + (to - from) * Double(i) / Double(count),
                          model: nil)
        }
    }

    @MainActor
    func testForecastFiresWhenPaceCrossesLimitBeforeReset() {
        // 30% burned in 6h, 48h to reset: projects far past 100%
        let store = UsageHistoryStore(seed: [account: ramp(hours: 6, from: 0, to: 30)])
        let text = store.weeklyForecast(account: account, current: usage(weekly: 30, resetsIn: 48 * 3600))
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.hasPrefix("On pace to hit 100%"))
    }

    @MainActor
    func testNoForecastWhenPaceStaysUnderLimit() {
        // 5% in 6h, reset in 12h: projects ~40%
        let store = UsageHistoryStore(seed: [account: ramp(hours: 6, from: 25, to: 30)])
        XCTAssertNil(store.weeklyForecast(account: account, current: usage(weekly: 30, resetsIn: 12 * 3600)))
    }

    @MainActor
    func testNoForecastFromUnderThreeHoursOfSignal() {
        let store = UsageHistoryStore(seed: [account: ramp(hours: 2, from: 0, to: 40)])
        XCTAssertNil(store.weeklyForecast(account: account, current: usage(weekly: 40, resetsIn: 48 * 3600)))
    }

    @MainActor
    func testForecastIgnoresDataFromBeforeAWeeklyReset() {
        // High values, a reset (drop), then a shallow climb: only the climb counts
        var snaps = ramp(hours: 20, from: 50, to: 90).map {
            UsageSnapshot(ts: $0.ts.addingTimeInterval(-4 * 3600), session: 10, weekly: $0.weekly, model: nil)
        }
        snaps.append(contentsOf: ramp(hours: 4, from: 0, to: 2))
        let store = UsageHistoryStore(seed: [account: snaps])
        XCTAssertNil(store.weeklyForecast(account: account, current: usage(weekly: 2, resetsIn: 7 * 86_400)))
    }

    @MainActor
    func testWeeklyPeaksNeedsTwoFullPastWeeks() {
        let now = Date()
        func snap(daysAgo: Double, weekly: Double) -> UsageSnapshot {
            UsageSnapshot(ts: now.addingTimeInterval(-daysAgo * 86_400), session: 0, weekly: weekly, model: nil)
        }
        // Only this week: no summary
        let thin = UsageHistoryStore(seed: [account: [snap(daysAgo: 0.5, weekly: 40)]])
        XCTAssertNil(thin.weeklyPeaks(account: account))

        // Two past weeks peaking at 60 and 80: average 70
        let store = UsageHistoryStore(seed: [account: [
            snap(daysAgo: 8, weekly: 60), snap(daysAgo: 9, weekly: 20),
            snap(daysAgo: 15, weekly: 80), snap(daysAgo: 16, weekly: 10),
            snap(daysAgo: 0.5, weekly: 40),
        ]])
        let text = store.weeklyPeaks(account: account)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("70%"), "expected 70% avg in: \(text!)")
    }

    @MainActor
    func testRecordFoldsReadingsIntoTodaysRollup() {
        let store = UsageHistoryStore(seed: [:])
        store.record(account: account, usage: usage(weekly: 50, resetsIn: 86_400))
        store.record(account: account, usage: usage(weekly: 70, resetsIn: 86_400))
        store.record(account: account, usage: usage(weekly: 60, resetsIn: 86_400))
        let rollups = store.dailyRollups(account: account, days: 7)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].peakWeekly, 70)
    }

    func testLegacyV117FormatMigratesWithRollups() throws {
        // v1.17 stored a plain {service: [snapshot]} dictionary
        let legacy = "{\"\(service)\": [{\"ts\": \(Date().timeIntervalSince1970 - 3600), \"session\": 20, \"weekly\": 45}, {\"ts\": \(Date().timeIntervalSince1970), \"session\": 30, \"weekly\": 55}]}"
        let decoded = UsageHistoryStore.decodeHistory(from: Data(legacy.utf8))
        XCTAssertEqual(decoded[service]?.snapshots.count, 2)
        XCTAssertEqual(decoded[service]?.rollups.map(\.peakWeekly).max(), 55)
    }

    @MainActor
    func testItemHistoryMovesToItsAccountOnce() {
        // Kept per Keychain item before: the item's readings join its account's
        // in time order, and the item keeps none, so a second move adds nothing
        let now = Date()
        func snap(minutesAgo: Double, weekly: Double) -> UsageSnapshot {
            UsageSnapshot(ts: now.addingTimeInterval(-minutesAgo * 60), session: 0, weekly: weekly, model: nil)
        }
        let store = UsageHistoryStore(seed: [
            service: [snap(minutesAgo: 120, weekly: 10), snap(minutesAgo: 30, weekly: 30)],
            account: [snap(minutesAgo: 60, weekly: 20)],
        ])
        store.adoptItemHistory(service: service, account: account)
        XCTAssertEqual(store.series(account: account, hours: 3, keyPath: \.weekly), [10, 20, 30])
        XCTAssertEqual(store.series(account: service, hours: 3, keyPath: \.weekly), [])
        store.adoptItemHistory(service: service, account: account)
        XCTAssertEqual(store.series(account: account, hours: 3, keyPath: \.weekly), [10, 20, 30])
    }

    @MainActor
    func testMovedRollupsKeepEachDaysHigherPeak() {
        let store = UsageHistoryStore(seed: [:])
        store.record(account: service, usage: usage(weekly: 70, resetsIn: 86_400))   // as per-item history was kept
        store.record(account: account, usage: usage(weekly: 40, resetsIn: 86_400))
        store.adoptItemHistory(service: service, account: account)
        let rollups = store.dailyRollups(account: account, days: 7)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].peakWeekly, 70)
    }

    @MainActor
    func testSeriesDownsamplesLongHistories() {
        let store = UsageHistoryStore(seed: [account: ramp(hours: 24 * 7, from: 0, to: 100)])
        let series = store.series(account: account, hours: 24 * 7, keyPath: \.weekly)
        XCTAssertEqual(series.count, 160)
        XCTAssertLessThan(series.first!, series.last!)
    }
}
