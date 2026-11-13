import XCTest
@testable import ClaudeUsage

final class UsageParsingTests: XCTestCase {
    func testMissingFiveHourMeansNoSessionLimit() {
        // Ultra verified accounts: the API omits five_hour entirely (issue #17)
        let json: [String: Any] = [
            "seven_day": ["utilization": 42.0, "resets_at": "2026-11-15T10:00:00Z"],
        ]
        let usage = UsageManager.parseUsage(json)
        XCTAssertFalse(usage.hasSessionLimit)
        XCTAssertEqual(usage.sessionUtilization, 0)
        XCTAssertEqual(usage.weeklyUtilization, 42)
    }

    func testPresentFiveHourMeansSessionLimit() {
        let json: [String: Any] = [
            "five_hour": ["utilization": 17.0],
            "seven_day": ["utilization": 42.0],
        ]
        let usage = UsageManager.parseUsage(json)
        XCTAssertTrue(usage.hasSessionLimit)
        XCTAssertEqual(usage.sessionUtilization, 17)
    }

    func testFiveHourAtZeroPercentIsStillALimit() {
        // 0% utilization is real data, not a missing limit
        let json: [String: Any] = [
            "five_hour": ["utilization": 0.0],
            "seven_day": ["utilization": 5.0],
        ]
        XCTAssertTrue(UsageManager.parseUsage(json).hasSessionLimit)
    }

    func testModelLimitsAndExtraUsageParse() {
        let json: [String: Any] = [
            "five_hour": ["utilization": 1.0],
            "seven_day": ["utilization": 2.0],
            "limits": [[
                "kind": "weekly_scoped",
                "percent": 23.0,
                "scope": ["model": ["display_name": "Fable"]],
            ]],
            "extra_usage": ["is_enabled": true, "monthly_limit": 10000.0, "used_credits": 2500.0],
        ]
        let usage = UsageManager.parseUsage(json)
        XCTAssertEqual(usage.modelLimits.first?.name, "Fable")
        XCTAssertEqual(usage.modelLimits.first?.utilization, 23)
        XCTAssertEqual(usage.extraUsagePercentage, 25)
    }
}
