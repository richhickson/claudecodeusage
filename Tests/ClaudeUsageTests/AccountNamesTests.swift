import XCTest
@testable import ClaudeUsage

final class AccountNamesTests: XCTestCase {
    private let service = "Claude Code-credentials-1a2b3c4d"

    func testEmailHoldsForTheTokenItWasResolvedWith() {
        var names = AccountNames()
        XCTAssertNil(names.email(service: service, token: "token-a"))
        names.remember(service: service, token: "token-a", email: "a@example.com")
        XCTAssertEqual(names.email(service: service, token: "token-a"), "a@example.com")
    }

    func testNewTokenInTheSameItemIsResolvedAgain() {
        // eg /login as another account in the same config dir
        var names = AccountNames()
        names.remember(service: service, token: "token-a", email: "a@example.com")
        XCTAssertNil(names.email(service: service, token: "token-b"))
        XCTAssertEqual(names.lastEmail(service: service), "a@example.com")   // shown only while unreadable
        names.remember(service: service, token: "token-b", email: "b@example.com")
        XCTAssertEqual(names.email(service: service, token: "token-b"), "b@example.com")
    }
}
