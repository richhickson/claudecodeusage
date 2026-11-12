import XCTest
@testable import ClaudeUsage

final class UsageHistoryTests: XCTestCase {
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
        let store = UsageHistoryStore(seed: [service: ramp(hours: 6, from: 0, to: 30)])
        let text = store.weeklyForecast(service: service, current: usage(weekly: 30, resetsIn: 48 * 3600))
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.hasPrefix("On pace to hit 100%"))
    }

    @MainActor
    func testNoForecastWhenPaceStaysUnderLimit() {
        // 5% in 6h, reset in 12h: projects ~40%
        let store = UsageHistoryStore(seed: [service: ramp(hours: 6, from: 25, to: 30)])
        XCTAssertNil(store.weeklyForecast(service: service, current: usage(weekly: 30, resetsIn: 12 * 3600)))
    }

    @MainActor
    func testNoForecastFromUnderThreeHoursOfSignal() {
        let store = UsageHistoryStore(seed: [service: ramp(hours: 2, from: 0, to: 40)])
        XCTAssertNil(store.weeklyForecast(service: service, current: usage(weekly: 40, resetsIn: 48 * 3600)))
    }

    @MainActor
    func testForecastIgnoresDataFromBeforeAWeeklyReset() {
        // High values, a reset (drop), then a shallow climb: only the climb counts
        var snaps = ramp(hours: 20, from: 50, to: 90).map {
            UsageSnapshot(ts: $0.ts.addingTimeInterval(-4 * 3600), session: 10, weekly: $0.weekly, model: nil)
        }
        snaps.append(contentsOf: ramp(hours: 4, from: 0, to: 2))
        let store = UsageHistoryStore(seed: [service: snaps])
        XCTAssertNil(store.weeklyForecast(service: service, current: usage(weekly: 2, resetsIn: 7 * 86_400)))
    }

    @MainActor
    func testWeeklyPeaksNeedsTwoFullPastWeeks() {
        let now = Date()
        func snap(daysAgo: Double, weekly: Double) -> UsageSnapshot {
            UsageSnapshot(ts: now.addingTimeInterval(-daysAgo * 86_400), session: 0, weekly: weekly, model: nil)
        }
        // Only this week: no summary
        let thin = UsageHistoryStore(seed: [service: [snap(daysAgo: 0.5, weekly: 40)]])
        XCTAssertNil(thin.weeklyPeaks(service: service))

        // Two past weeks peaking at 60 and 80: average 70
        let store = UsageHistoryStore(seed: [service: [
            snap(daysAgo: 8, weekly: 60), snap(daysAgo: 9, weekly: 20),
            snap(daysAgo: 15, weekly: 80), snap(daysAgo: 16, weekly: 10),
            snap(daysAgo: 0.5, weekly: 40),
        ]])
        let text = store.weeklyPeaks(service: service)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("70%"), "expected 70% avg in: \(text!)")
    }

    @MainActor
    func testRecordFoldsReadingsIntoTodaysRollup() {
        let store = UsageHistoryStore(seed: [:])
        store.record(service: service, usage: usage(weekly: 50, resetsIn: 86_400))
        store.record(service: service, usage: usage(weekly: 70, resetsIn: 86_400))
        store.record(service: service, usage: usage(weekly: 60, resetsIn: 86_400))
        let rollups = store.dailyRollups(service: service, days: 7)
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
    func testSeriesDownsamplesLongHistories() {
        let store = UsageHistoryStore(seed: [service: ramp(hours: 24 * 7, from: 0, to: 100)])
        let series = store.series(service: service, hours: 24 * 7, keyPath: \.weekly)
        XCTAssertEqual(series.count, 160)
        XCTAssertLessThan(series.first!, series.last!)
    }
}
