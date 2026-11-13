import Foundation
import Security

struct ModelLimit {
    let name: String
    let utilization: Double
    let resetsAt: Date?

    var percentage: Int { Int(utilization) }
}

struct UsageData {
    /// Ultra-plan verified accounts have no 5-hour limit; the API then omits
    /// `five_hour` entirely and the Session card is hidden (issue #17)
    var hasSessionLimit: Bool = true
    let sessionUtilization: Double
    let sessionResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?
    let sonnetUtilization: Double?
    let sonnetResetsAt: Date?
    let modelLimits: [ModelLimit]
    let extraUsageEnabled: Bool
    let extraUsageMonthlyLimit: Double?
    let extraUsageUsedCredits: Double?

    var sessionPercentage: Int { Int(sessionUtilization) }
    var weeklyPercentage: Int { Int(weeklyUtilization) }
    var sonnetPercentage: Int? { sonnetUtilization.map { Int($0) } }
    var extraUsagePercentage: Int? {
        guard extraUsageEnabled, let limit = extraUsageMonthlyLimit, let used = extraUsageUsedCredits, limit > 0 else { return nil }
        return Int((used / limit) * 100)
    }
}

/// One Claude Code login found in the Keychain. Each CLAUDE_CONFIG_DIR keeps
/// its own entry (see ClaudeConfigManager.keychainServices), so a machine can
/// hold several profiles at once.
struct ClaudeProfile: Identifiable {
    let service: String        // Keychain service name
    var label: String          // account email once known, else a fallback
    var usage: UsageData?
    var error: String?
    var id: String { service }

}

/// A Claude credential store can contain MCP logins without a Claude account.
/// nil means a valid store that should not appear in the account selector.
enum ClaudeCredentialParser {
    static func accessToken(from data: Data) throws -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw KeychainError.invalidCredentialFormat
        }
        guard let account = json["claudeAiOauth"] else { return nil }
        guard let oauth = account as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainError.missingOAuthToken(availableKeys: "claudeAiOauth")
        }
        return token
    }
}

/// One usage reading, recorded on every successful poll (every 5 minutes)
struct UsageSnapshot: Codable {
    let ts: Date
    let session: Double
    let weekly: Double
    let model: Double?   // highest model-scoped limit at the time
}

/// One day's peaks, kept long after the raw snapshots are pruned.
/// Feeds the History window's 7/30/90/365-day charts.
struct DailyUsageRollup: Codable {
    let day: Date        // start of day
    var peakSession: Double
    var peakWeekly: Double
    var peakModel: Double?
}

struct ProfileUsageHistory: Codable {
    var snapshots: [UsageSnapshot] = []
    var rollups: [DailyUsageRollup] = []
}

/// Local usage history, 30 days per profile, in Application Support.
/// Powers the sparklines, burn-rate forecast and weekly-peaks summary
/// (issue #16). Everything stays on this machine.
@MainActor
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()
    static let retentionDays = 30.0        // raw 5-minute snapshots
    static let rollupRetentionDays = 400.0 // daily peaks, for the 1y view

    private var data: [String: ProfileUsageHistory] = [:]
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage-history.json")
        if let raw = try? Data(contentsOf: fileURL) {
            data = Self.decodeHistory(from: raw)
        }
    }

    /// Test seam: in-memory store, never touches the real history file
    init(seed: [String: [UsageSnapshot]]) {
        data = seed.mapValues { ProfileUsageHistory(snapshots: $0) }
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("claudeusage-test-history.json")
    }

    /// Current format, migrating v1.17's plain snapshot-array format in place
    nonisolated static func decodeHistory(from raw: Data) -> [String: ProfileUsageHistory] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let current = try? decoder.decode([String: ProfileUsageHistory].self, from: raw) {
            return current
        }
        if let legacy = try? decoder.decode([String: [UsageSnapshot]].self, from: raw) {
            return legacy.mapValues { snapshots in
                var history = ProfileUsageHistory(snapshots: snapshots)
                history.rollups = Self.rollups(from: snapshots)
                return history
            }
        }
        return [:]
    }

    nonisolated private static func rollups(from snapshots: [UsageSnapshot]) -> [DailyUsageRollup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: snapshots) { calendar.startOfDay(for: $0.ts) }
        return byDay.map { day, snaps in
            DailyUsageRollup(day: day,
                             peakSession: snaps.map(\.session).max() ?? 0,
                             peakWeekly: snaps.map(\.weekly).max() ?? 0,
                             peakModel: snaps.compactMap(\.model).max())
        }.sorted { $0.day < $1.day }
    }

    func record(service: String, usage: UsageData) {
        var history = data[service] ?? ProfileUsageHistory()
        let model = usage.modelLimits.map(\.utilization).max()
        history.snapshots.append(UsageSnapshot(ts: Date(),
                                               session: usage.sessionUtilization,
                                               weekly: usage.weeklyUtilization,
                                               model: model))
        history.snapshots.removeAll { $0.ts < Date().addingTimeInterval(-Self.retentionDays * 86_400) }

        // Fold this reading into today's rollup, which outlives the snapshots
        let today = Calendar.current.startOfDay(for: Date())
        if let index = history.rollups.firstIndex(where: { $0.day == today }) {
            history.rollups[index].peakSession = max(history.rollups[index].peakSession, usage.sessionUtilization)
            history.rollups[index].peakWeekly = max(history.rollups[index].peakWeekly, usage.weeklyUtilization)
            history.rollups[index].peakModel = [history.rollups[index].peakModel, model].compactMap { $0 }.max()
        } else {
            history.rollups.append(DailyUsageRollup(day: today,
                                                    peakSession: usage.sessionUtilization,
                                                    peakWeekly: usage.weeklyUtilization,
                                                    peakModel: model))
            history.rollups.sort { $0.day < $1.day }
        }
        history.rollups.removeAll { $0.day < Date().addingTimeInterval(-Self.rollupRetentionDays * 86_400) }
        data[service] = history

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let out = try? encoder.encode(data) {
            try? out.write(to: fileURL, options: .atomic)
        }
    }

    /// Daily peaks for the History window, oldest first
    func dailyRollups(service: String, days: Int) -> [DailyUsageRollup] {
        let cutoff = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86_400)
        return (data[service]?.rollups ?? []).filter { $0.day >= cutoff }
    }

    /// Values for a sparkline covering the last `hours`, downsampled for drawing
    func series(service: String, hours: Double, keyPath: KeyPath<UsageSnapshot, Double>, maxPoints: Int = 160) -> [Double] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let values = (data[service]?.snapshots ?? []).filter { $0.ts > cutoff }.map { $0[keyPath: keyPath] }
        guard values.count > maxPoints else { return values }
        let step = Double(values.count) / Double(maxPoints)
        return (0..<maxPoints).map { values[Int(Double($0) * step)] }
    }

    /// "On pace to hit 100% Thu 19:00" — only when the recent burn rate
    /// actually crosses 100% before the weekly reset
    func weeklyForecast(service: String, current: UsageData) -> String? {
        guard let resetsAt = current.weeklyResetsAt else { return nil }
        let recent = (data[service]?.snapshots ?? []).filter { $0.ts > Date().addingTimeInterval(-86_400) }

        // Use only the run since the last reset (a drop of >5 points means reset)
        var run: [UsageSnapshot] = []
        for snapshot in recent {
            if let last = run.last, snapshot.weekly < last.weekly - 5 { run = [] }
            run.append(snapshot)
        }
        guard let first = run.first, let last = run.last else { return nil }
        let elapsed = last.ts.timeIntervalSince(first.ts)
        guard elapsed >= 3 * 3600 else { return nil }   // need 3h+ of signal

        let ratePerSecond = (last.weekly - first.weekly) / elapsed
        guard ratePerSecond > 0 else { return nil }
        let projected = last.weekly + ratePerSecond * resetsAt.timeIntervalSince(last.ts)
        guard projected >= 100 else { return nil }

        let hitDate = last.ts.addingTimeInterval((100 - last.weekly) / ratePerSecond)
        let when = hitDate.formatted(Date.FormatStyle().weekday(.abbreviated).hour(.defaultDigits(amPM: .abbreviated)))
        return "On pace to hit 100% \(when)"
    }

    /// "Past 4 weeks peaked at 62% avg" — the upgrade/downgrade answer.
    /// Appears once at least two full past weeks of history exist.
    func weeklyPeaks(service: String) -> String? {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
        let byWeek = Dictionary(grouping: data[service]?.snapshots ?? []) {
            calendar.dateInterval(of: .weekOfYear, for: $0.ts)?.start ?? $0.ts
        }
        let pastPeaks = byWeek.filter { $0.key != thisWeek }
            .mapValues { $0.map(\.weekly).max() ?? 0 }
            .sorted { $0.key > $1.key }
            .prefix(4)
        guard pastPeaks.count >= 2 else { return nil }
        let average = pastPeaks.map(\.value).reduce(0, +) / Double(pastPeaks.count)
        return String(format: "Past %d weeks peaked at %.0f%% avg", pastPeaks.count, average)
    }
}

@MainActor
class UsageManager: ObservableObject {
    @Published var usage: UsageData?
    @Published var error: String?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var updateAvailable: String?
    @Published var updateDownloadURL: URL?

    /// All Claude Code logins found in the Keychain, active config dir's first.
    /// With a single profile the app behaves exactly as before.
    @Published var profiles: [ClaudeProfile] = []
    @Published private(set) var selectedProfileService: String? =
        UserDefaults.standard.string(forKey: "selectedProfileService")

    /// Email labels already resolved this run, keyed by Keychain service
    private var profileLabels: [String: String] = [:]

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    static let githubRepo = "richhickson/claudecodeusage"
    static let claudeCodeVersion: String = {
        // Detect installed Claude Code version for User-Agent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                // Output is like "2.1.69 (Claude Code)" - extract version number
                let version = output.split(separator: " ").first.map(String.init) ?? output
                if !version.isEmpty { return version }
            }
        } catch {}
        return "2.1.0"
    }()

    // Configured URLSession with timeouts
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// Menu-bar colour and percentage both describe the selected account.
    var maxUtilization: Double {
        guard let usage else { return 0 }
        let model = usage.modelLimits.map(\.utilization).max() ?? 0
        return max(usage.sessionUtilization, usage.weeklyUtilization, model)
    }

    var statusEmoji: String {
        guard usage != nil else { return "❓" }
        if maxUtilization >= 90 { return "🔴" }
        if maxUtilization >= 70 { return "🟡" }
        return "🟢"
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let preferred = ClaudeConfigManager.keychainServices
        let services = await Task.detached { Self.discoverKeychainServices(preferred: preferred) }.value

        var newProfiles: [ClaudeProfile] = []
        for service in services {
            var profile = ClaudeProfile(service: service,
                                        label: profileLabels[service] ?? Self.fallbackLabel(service))
            do {
                guard let token = try await getClaudeCodeTokenWithRetry(service: service) else {
                    // MCP-only stores remain untouched in Keychain.
                    continue
                }
                profile.usage = try await fetchUsageWithRetry(token: token)
                if profileLabels[service] == nil,
                   let email = await fetchProfileEmail(token: token) {
                    profileLabels[service] = email
                    profile.label = email
                }
            } catch let keychainError as KeychainError {
                profile.error = keychainError.localizedDescription
            } catch {
                profile.error = error.localizedDescription
            }
            if let fetched = profile.usage {
                UsageHistoryStore.shared.record(service: service, usage: fetched)
            }
            newProfiles.append(profile)
        }

        profiles = newProfiles
        if selectedProfileService == nil || !newProfiles.contains(where: { $0.service == selectedProfileService }) {
            selectedProfileService = newProfiles.first?.service
        }
        applySelection()
        lastUpdated = Date()
    }

    // MARK: History (issue #16) — all for the selected profile

    /// Session sparkline: last 24 hours
    var sessionHistory: [Double] {
        guard let service = selectedProfileService else { return [] }
        return UsageHistoryStore.shared.series(service: service, hours: 24, keyPath: \.session)
    }

    /// Weekly sparkline: last 7 days
    var weeklyHistory: [Double] {
        guard let service = selectedProfileService else { return [] }
        return UsageHistoryStore.shared.series(service: service, hours: 7 * 24, keyPath: \.weekly)
    }

    var weeklyForecast: String? {
        guard let service = selectedProfileService, let usage else { return nil }
        return UsageHistoryStore.shared.weeklyForecast(service: service, current: usage)
    }

    var weeklyPeaks: String? {
        guard let service = selectedProfileService else { return nil }
        return UsageHistoryStore.shared.weeklyPeaks(service: service)
    }

    /// Switch the popover and menu bar to another profile (no refetch needed)
    func selectProfile(_ service: String) {
        guard profiles.contains(where: { $0.service == service }) else { return }
        selectedProfileService = service
        UserDefaults.standard.set(service, forKey: "selectedProfileService")
        applySelection()
    }

    private func applySelection() {
        let selected = profiles.first { $0.service == selectedProfileService }
        usage = selected?.usage
        error = selected?.error ?? (profiles.isEmpty ? KeychainError.notLoggedIn.localizedDescription : nil)
    }

    /// A successful MCP-only read ends retries without creating an error profile.
    private func getClaudeCodeTokenWithRetry(service: String) async throws -> String? {
        for attempt in 0...5 {
            do {
                return try getClaudeCodeToken(service: service)
            } catch let error as KeychainError where error.isRetryable && attempt < 5 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw KeychainError.notLoggedIn
    }

    /// Usage fetch with retry on 429/5xx (exponential backoff) and network errors
    private func fetchUsageWithRetry(token: String, retriesRemaining: Int = 5, backoffSeconds: UInt64 = 2) async throws -> UsageData {
        do {
            return try await fetchUsage(token: token)
        } catch let usageError as UsageError where retriesRemaining > 0 && usageError.isRetryable {
            try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
            return try await fetchUsageWithRetry(token: token, retriesRemaining: retriesRemaining - 1, backoffSeconds: backoffSeconds * 2)
        } catch let urlError as URLError where retriesRemaining > 0 && urlError.isRetryable {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds for network
            return try await fetchUsageWithRetry(token: token, retriesRemaining: retriesRemaining - 1, backoffSeconds: backoffSeconds)
        }
    }

    /// Scan the Keychain for every Claude Code login. `dump-keychain` lists item
    /// attributes only (never secrets), so it triggers no ACL prompt.
    nonisolated private static func discoverKeychainServices(preferred: [String]) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
            "/usr/bin/security dump-keychain 2>/dev/null | /usr/bin/grep -o '\"svce\"<blob>=\"Claude Code[^\"]*\"'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        var found = Set<String>()
        do {
            try process.run()
            // Read before waitUntilExit so a large dump can't deadlock the pipe
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.split(separator: "\n") {
                    guard let eq = line.range(of: "=\"") else { continue }
                    let name = String(line[eq.upperBound...].dropLast())
                    // "Claude Code-credentials" or "Claude Code-credentials-<8hex>"
                    if name.contains("-credentials") { found.insert(name) }
                }
            }
        } catch {}

        // Active config dir's entry first, then the rest alphabetically
        var ordered: [String] = []
        for service in preferred where found.contains(service) {
            ordered.append(service)
            found.remove(service)
        }
        ordered.append(contentsOf: found.sorted())
        // Scan found nothing (dump unavailable?) — static list keeps the old path
        return ordered.isEmpty ? preferred : ordered
    }

    private static func fallbackLabel(_ service: String) -> String {
        if service == "Claude Code-credentials" { return "Default" }
        let suffix = service.replacingOccurrences(of: "Claude Code-credentials-", with: "")
        return "Profile \(suffix.prefix(8))"
    }

    /// Account email for a profile tab label, from /api/oauth/profile
    private func fetchProfileEmail(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any] else { return nil }
        return account["email"] as? String
    }

    /// Read only this service: a failed named login must never use another
    /// profile's token through the legacy global fallback.
    private func getClaudeCodeToken(service: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw KeychainError.unexpectedError(status: -1)
        }
        // Drain before waiting so a large credential store cannot fill the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 44 { throw KeychainError.notLoggedIn }
            throw KeychainError.securityCommandFailed("security exited with status \(process.terminationStatus)")
        }
        return try ClaudeCredentialParser.accessToken(from: data)
    }

    private func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
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

        return Self.parseUsage(json)
    }

    /// Parse the /api/oauth/usage response. A missing `five_hour` means the
    /// account has no 5-hour limit (Ultra verified accounts, issue #17), not 0%.
    nonisolated static func parseUsage(_ json: [String: Any]) -> UsageData {
        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]
        // Try new field name first, fall back to legacy
        let sonnet = json["seven_day_sonnet"] as? [String: Any] ?? json["sonnet_only"] as? [String: Any]
        let extraUsage = json["extra_usage"] as? [String: Any]

        // Model-scoped limits (e.g. Fable/Opus weekly caps) come from the `limits` array
        var modelLimits: [ModelLimit] = []
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String,
                      let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
                modelLimits.append(ModelLimit(
                    name: name,
                    utilization: percent,
                    resetsAt: parseDate(limit["resets_at"] as? String)
                ))
            }
        }

        return UsageData(
            hasSessionLimit: fiveHour != nil,
            sessionUtilization: fiveHour?["utilization"] as? Double ?? 0,
            sessionResetsAt: parseDate(fiveHour?["resets_at"] as? String),
            weeklyUtilization: sevenDay?["utilization"] as? Double ?? 0,
            weeklyResetsAt: parseDate(sevenDay?["resets_at"] as? String),
            sonnetUtilization: sonnet?["utilization"] as? Double,
            sonnetResetsAt: parseDate(sonnet?["resets_at"] as? String),
            modelLimits: modelLimits,
            extraUsageEnabled: extraUsage?["is_enabled"] as? Bool ?? false,
            extraUsageMonthlyLimit: extraUsage?["monthly_limit"] as? Double,
            extraUsageUsedCredits: extraUsage?["used_credits"] as? Double
        )
    }

    nonisolated private static func parseDate(_ string: String?) -> Date? {
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
                    // Zip asset URL for in-app update
                    if let assets = json["assets"] as? [[String: Any]],
                       let zip = assets.first(where: { ($0["name"] as? String) == "ClaudeUsage.zip" }),
                       let urlString = zip["browser_download_url"] as? String {
                        updateDownloadURL = URL(string: urlString)
                    }
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
            if code == 429 {
                return "Rate limited by API. Will retry automatically."
            }
            return "API error (code: \(code))"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .apiError(let code):
            return code == 429 || code == 500 || code == 502 || code == 503
        case .invalidResponse:
            return false
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
