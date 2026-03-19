import XCTest

// These tests mirror the logic in UsageData and UsageManager without importing
// the app module (which is an executable target and cannot be @testable imported).
// They exist to pin the expected behaviour of the enterprise display changes.

// MARK: - Minimal replicas of app types

private struct UsageData {
    let sessionUtilization: Double
    let weeklyUtilization: Double
    let extraUsageEnabled: Bool
    let extraUsageMonthlyLimit: Double?
    let extraUsageUsedCredits: Double?

    var sessionPercentage: Int { Int(sessionUtilization) }

    var extraUsagePercentage: Int? {
        guard extraUsageEnabled,
              let limit = extraUsageMonthlyLimit,
              let used = extraUsageUsedCredits,
              limit > 0 else { return nil }
        return Int((used / limit) * 100)
    }
}

private func statusEmoji(for usage: UsageData) -> String {
    let util: Double
    if usage.extraUsageEnabled, let pct = usage.extraUsagePercentage {
        util = Double(pct)
    } else {
        util = max(usage.sessionUtilization, usage.weeklyUtilization)
    }
    if util >= 90 { return "🔴" }
    if util >= 70 { return "🟡" }
    return "🟢"
}

private func menubarLabel(for usage: UsageData, emoji: String) -> String {
    if usage.extraUsageEnabled, let used = usage.extraUsageUsedCredits {
        return "\(emoji) $\(String(format: "%.0f", used / 100))"
    }
    return "\(emoji) \(usage.sessionPercentage)%"
}

// MARK: - Tests

final class EnterpriseDisplayTests: XCTestCase {

    // MARK: extraUsagePercentage

    func testExtraUsagePercentage_typicalSpend_calculatesCorrectly() {
        // $14.03 spent of $100 limit (stored as cents)
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 1_403)
        XCTAssertEqual(usage.extraUsagePercentage, 14)
    }

    func testExtraUsagePercentage_fullLimit_returns100() {
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 10_000)
        XCTAssertEqual(usage.extraUsagePercentage, 100)
    }

    func testExtraUsagePercentage_noSpend_returnsZero() {
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 0)
        XCTAssertEqual(usage.extraUsagePercentage, 0)
    }

    func testExtraUsagePercentage_whenDisabled_returnsNil() {
        let usage = UsageData(sessionUtilization: 50, weeklyUtilization: 50,
                              extraUsageEnabled: false,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 1_403)
        XCTAssertNil(usage.extraUsagePercentage)
    }

    func testExtraUsagePercentage_zeroLimit_returnsNil() {
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 0,
                              extraUsageUsedCredits: 1_403)
        XCTAssertNil(usage.extraUsagePercentage)
    }

    func testExtraUsagePercentage_missingLimit_returnsNil() {
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: nil,
                              extraUsageUsedCredits: 1_403)
        XCTAssertNil(usage.extraUsagePercentage)
    }

    // MARK: statusEmoji — enterprise path

    func testStatusEmoji_enterprise_lowUsage_isGreen() {
        // 14% of limit
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 1_403)
        XCTAssertEqual(statusEmoji(for: usage), "🟢")
    }

    func testStatusEmoji_enterprise_mediumUsage_isYellow() {
        // 75% of limit
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 7_500)
        XCTAssertEqual(statusEmoji(for: usage), "🟡")
    }

    func testStatusEmoji_enterprise_highUsage_isRed() {
        // 95% of limit
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 9_500)
        XCTAssertEqual(statusEmoji(for: usage), "🔴")
    }

    func testStatusEmoji_enterprise_ignoresSessionWeeklyUtilization() {
        // Session/weekly are maxed out, but overage spend is only 1% — should be green
        let usage = UsageData(sessionUtilization: 95, weeklyUtilization: 95,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 100)
        XCTAssertEqual(statusEmoji(for: usage), "🟢")
    }

    // MARK: statusEmoji — non-enterprise path

    func testStatusEmoji_nonEnterprise_usesSessionWeeklyMax() {
        let usage = UsageData(sessionUtilization: 85, weeklyUtilization: 60,
                              extraUsageEnabled: false,
                              extraUsageMonthlyLimit: nil,
                              extraUsageUsedCredits: nil)
        XCTAssertEqual(statusEmoji(for: usage), "🟡") // max is 85%
    }

    func testStatusEmoji_nonEnterprise_highUsage_isRed() {
        let usage = UsageData(sessionUtilization: 92, weeklyUtilization: 50,
                              extraUsageEnabled: false,
                              extraUsageMonthlyLimit: nil,
                              extraUsageUsedCredits: nil)
        XCTAssertEqual(statusEmoji(for: usage), "🔴")
    }

    // MARK: Menubar label

    func testMenubarLabel_enterprise_showsDollarAmount() {
        // $14.03 → rounded to $14 in menubar
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 1_403)
        XCTAssertEqual(menubarLabel(for: usage, emoji: "🟢"), "🟢 $14")
    }

    func testMenubarLabel_enterprise_roundsToNearestDollar() {
        // $14.99 → $15
        let usage = UsageData(sessionUtilization: 0, weeklyUtilization: 0,
                              extraUsageEnabled: true,
                              extraUsageMonthlyLimit: 10_000,
                              extraUsageUsedCredits: 1_499)
        XCTAssertEqual(menubarLabel(for: usage, emoji: "🟡"), "🟡 $15")
    }

    func testMenubarLabel_nonEnterprise_showsSessionPercentage() {
        let usage = UsageData(sessionUtilization: 45, weeklyUtilization: 30,
                              extraUsageEnabled: false,
                              extraUsageMonthlyLimit: nil,
                              extraUsageUsedCredits: nil)
        XCTAssertEqual(menubarLabel(for: usage, emoji: "🟢"), "🟢 45%")
    }
}
