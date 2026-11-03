import XCTest
@testable import ClaudeUsage

final class ClaudeCredentialParserTests: XCTestCase {
    func testMCPOnlyStoreIsNotAnAccountAndIsUnchanged() throws {
        let data = Data(#"{"mcpOAuth":{"conflabd":{"accessToken":"MCP_SECRET"}}}"#.utf8)
        let original = data
        XCTAssertNil(try ClaudeCredentialParser.accessToken(from: data))
        XCTAssertEqual(data, original)
    }

    func testAccountAndMCPInSameStoreReturnsOnlyAccountToken() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"ACCOUNT"},"mcpOAuth":{"conflabd":{"accessToken":"MCP_SECRET"}}}"#.utf8)
        XCTAssertEqual(try ClaudeCredentialParser.accessToken(from: data), "ACCOUNT")
    }

    func testEmptyOrUnrelatedStoreIsNotAnAccount() throws {
        for json in ["{}", #"{"mcpOAuth":{}}"#, #"{"otherMetadata":true}"#] {
            XCTAssertNil(try ClaudeCredentialParser.accessToken(from: Data(json.utf8)))
        }
    }

    func testMalformedAccountRemainsAnErrorRatherThanBeingHidden() {
        for json in [#"{"claudeAiOauth":null}"#, #"{"claudeAiOauth":{}}"#,
                     #"{"claudeAiOauth":{"accessToken":""}}"#,
                     #"{"claudeAiOauth":{"accessToken":"  "}}"#,
                     #"{"claudeAiOauth":{"accessToken":42}}"#] {
            XCTAssertThrowsError(try ClaudeCredentialParser.accessToken(from: Data(json.utf8)))
        }
    }

    func testInvalidJSONDoesNotDiscloseCredentialContents() {
        XCTAssertThrowsError(try ClaudeCredentialParser.accessToken(from: Data("PRIVATE_SECRET".utf8))) { error in
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_SECRET"))
        }
    }
}
