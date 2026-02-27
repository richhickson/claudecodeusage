import Foundation
import Security

struct UsageData {
    let sessionUtilization: Double
    let sessionResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?
    let sonnetUtilization: Double?
    let sonnetResetsAt: Date?
    let extraUsage: ExtraUsageData?

    var sessionPercentage: Int { Int(sessionUtilization) }
    var weeklyPercentage: Int { Int(weeklyUtilization) }
    var sonnetPercentage: Int? { sonnetUtilization.map { Int($0) } }
}

struct ExtraUsageData {
    let isEnabled: Bool
    let monthlyLimitCents: Double
    let usedCreditsCents: Double
    let utilization: Double

    var percentage: Int { Int(utilization) }
    var formattedUsed: String { String(format: "$%.2f", usedCreditsCents / 100) }
    var formattedLimit: String { String(format: "$%.0f", monthlyLimitCents / 100) }
}

@MainActor
class UsageManager: ObservableObject {
    @Published var usage: UsageData?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var updateAvailable: String?

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    static let githubRepo = "richhickson/claudecodeusage"

    // Configured URLSession with timeouts
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    var statusEmoji: String {
        guard let usage = usage else { return "❓" }
        let maxUtil = max(usage.sessionUtilization, usage.weeklyUtilization)
        if maxUtil >= 90 { return "🔴" }
        if maxUtil >= 70 { return "🟡" }
        return "🟢"
    }

    func refresh() async {
        await refreshWithRetry(retriesRemaining: 3)
    }

    private func refreshWithRetry(retriesRemaining: Int) async {
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            let token = try await getAccessToken()
            let data = try await fetchUsage(token: token)
            usage = data
            lastUpdated = Date()
        } catch let keychainError as KeychainError {
            // Retry on keychain errors that may resolve after unlock
            if retriesRemaining > 0 && keychainError.isRetryable {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1)
                return
            }
            self.error = keychainError.localizedDescription
        } catch let urlError as URLError {
            // Retry on network errors (common after wake from sleep)
            if retriesRemaining > 0 && urlError.isRetryable {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds for network
                await refreshWithRetry(retriesRemaining: retriesRemaining - 1)
                return
            }
            self.error = urlError.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func getAccessToken() async throws -> String {
        // Get token from Claude Code's keychain via security CLI
        return try getClaudeCodeToken()
    }

    /// Get token from Claude Code's credentials file or keychain
    private func getClaudeCodeToken() throws -> String {
        // 1. Try ~/.claude/.credentials.json first (always has complete JSON)
        if let token = try? getTokenFromCredentialsFile() {
            return token
        }

        // 2. Try keychain with regex extraction (handles truncated JSON)
        if let token = try? getTokenFromKeychain() {
            return token
        }

        // 3. Try alternate keychain entry
        if let token = try? getAccessTokenFromAlternateKeychain() {
            return token
        }

        throw KeychainError.notLoggedIn
    }

    /// Read token from ~/.claude/.credentials.json
    private func getTokenFromCredentialsFile() throws -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let credPath = homeDir.appendingPathComponent(".claude/.credentials.json")

        let data = try Data(contentsOf: credPath)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            throw KeychainError.invalidCredentialFormat
        }
        return accessToken
    }

    /// Get token from keychain using regex (handles truncated JSON from large credentials)
    private func getTokenFromKeychain() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KeychainError.unexpectedError(status: -1)
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? ""
            if errorString.contains("could not be found") {
                throw KeychainError.notLoggedIn
            }
            throw KeychainError.securityCommandFailed(errorString.isEmpty ? "Exit code \(process.terminationStatus)" : errorString)
        }

        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            throw KeychainError.notLoggedIn
        }

        // Try full JSON parse first
        if let jsonData = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let accessToken = oauth["accessToken"] as? String {
            return accessToken
        }

        // JSON may be truncated (keychain stores large credentials incompletely).
        // Extract token with regex since accessToken is near the start.
        if let range = output.range(of: #""accessToken"\s*:\s*"([^"]+)""#, options: .regularExpression),
           let tokenRange = output[range].range(of: #"(?<=")[^"]+(?="[^"]*$)"#, options: .regularExpression) {
            return String(output[tokenRange])
        }

        throw KeychainError.invalidCredentialFormat
    }

    /// Fallback: Check for "Claude Code" keychain entry (alternate storage location)
    private func getAccessTokenFromAlternateKeychain() throws -> String {
        // Use security CLI which is already in the keychain ACL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw KeychainError.notLoggedIn
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0,
              let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jsonString.isEmpty,
              let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            throw KeychainError.notLoggedIn
        }

        return accessToken
    }

    private func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeUsage/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw UsageError.apiError(statusCode: httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }

        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]
        let sonnetOnly = json["sonnet_only"] as? [String: Any]

        var extraUsage: ExtraUsageData? = nil
        if let extra = json["extra_usage"] as? [String: Any],
           let isEnabled = extra["is_enabled"] as? Bool, isEnabled {
            extraUsage = ExtraUsageData(
                isEnabled: isEnabled,
                monthlyLimitCents: extra["monthly_limit"] as? Double ?? 0,
                usedCreditsCents: extra["used_credits"] as? Double ?? 0,
                utilization: extra["utilization"] as? Double ?? 0
            )
        }

        return UsageData(
            sessionUtilization: fiveHour?["utilization"] as? Double ?? 0,
            sessionResetsAt: parseDate(fiveHour?["resets_at"] as? String),
            weeklyUtilization: sevenDay?["utilization"] as? Double ?? 0,
            weeklyResetsAt: parseDate(sevenDay?["resets_at"] as? String),
            sonnetUtilization: sonnetOnly?["utilization"] as? Double,
            sonnetResetsAt: parseDate(sonnetOnly?["resets_at"] as? String),
            extraUsage: extraUsage
        )
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    func checkForUpdates() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsage/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await urlSession.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                if isNewerVersion(latestVersion, than: Self.currentVersion) {
                    updateAvailable = latestVersion
                }
            }
        } catch {
            // Silently fail - update check is not critical
        }
    }

    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}

enum KeychainError: LocalizedError {
    case notLoggedIn
    case accessDenied
    case interactionNotAllowed
    case invalidData
    case invalidCredentialFormat
    case unexpectedError(status: OSStatus)
    case securityCommandFailed(String)
    case missingOAuthToken(availableKeys: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to Claude Code"
        case .accessDenied:
            return "Keychain access denied. Please allow access in System Settings."
        case .interactionNotAllowed:
            return "Keychain interaction not allowed. Try unlocking your Mac."
        case .invalidData:
            return "Could not read Keychain data"
        case .invalidCredentialFormat:
            return "Invalid credential format in keychain"
        case .unexpectedError(let status):
            return "Keychain error (code: \(status))"
        case .securityCommandFailed(let error):
            return "Keychain access failed: \(error.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .missingOAuthToken(let keys):
            return "No OAuth token in keychain. Found keys: \(keys). Try 'claude' to re-login."
        }
    }

    /// Errors that may resolve after the keychain unlocks (post-sleep/lock/boot)
    var isRetryable: Bool {
        switch self {
        case .notLoggedIn, .invalidCredentialFormat, .invalidData, .interactionNotAllowed, .securityCommandFailed:
            // notLoggedIn is retryable because keychain may not be accessible immediately after boot
            return true
        case .accessDenied, .unexpectedError, .missingOAuthToken:
            return false
        }
    }
}

enum UsageError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code):
            if code == 401 {
                return "Authentication expired. Run 'claude' to re-authenticate."
            }
            return "API error (code: \(code))"
        }
    }
}

extension URLError {
    /// Network errors that may resolve after wake from sleep
    var isRetryable: Bool {
        switch self.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .timedOut,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
