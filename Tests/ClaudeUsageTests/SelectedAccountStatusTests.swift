import XCTest
@testable import ClaudeUsage

final class SelectedAccountStatusTests: XCTestCase {
    private func usage(session: Double = 1, weekly: Double = 0, model: Double = 0) -> UsageData {
        UsageData(sessionUtilization: session, sessionResetsAt: nil,
                  weeklyUtilization: weekly, weeklyResetsAt: nil,
                  sonnetUtilization: nil, sonnetResetsAt: nil,
                  modelLimits: [ModelLimit(name: "Model", utilization: model, resetsAt: nil)],
                  extraUsageEnabled: false, extraUsageMonthlyLimit: nil, extraUsageUsedCredits: nil)
    }

    @MainActor
    func testOtherAccountsDoNotChangeSelectedAccountColour() async {
        let manager = UsageManager()
        manager.profiles = [ClaudeProfile(service: "low", label: "Low", usage: usage()),
                            ClaudeProfile(service: "high", label: "High", usage: usage(session: 100))]
        manager.usage = usage()
        XCTAssertEqual(manager.maxUtilization, 1)
        XCTAssertEqual(manager.statusEmoji, "🟢")
        manager.usage = usage(session: 100)
        XCTAssertEqual(manager.maxUtilization, 100)
        XCTAssertEqual(manager.statusEmoji, "🔴")
        manager.usage = nil
        XCTAssertEqual(manager.maxUtilization, 0)
        XCTAssertEqual(manager.statusEmoji, "❓")
    }

    @MainActor
    func testSelectedAccountWeeklyAndModelLimitsStillAffectColour() async {
        let manager = UsageManager()
        manager.usage = usage(weekly: 95)
        XCTAssertEqual(manager.maxUtilization, 95)
        XCTAssertEqual(manager.statusEmoji, "🔴")
        manager.usage = usage(model: 85)
        XCTAssertEqual(manager.maxUtilization, 85)
        XCTAssertEqual(manager.statusEmoji, "🟡")
    }
}
