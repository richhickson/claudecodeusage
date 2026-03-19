import SwiftUI
import AppKit
import ServiceManagement

struct UsageView: View {
    @ObservedObject var manager: UsageManager
    @Environment(\.openURL) var openURL
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Usage")
                    .font(.headline)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()

                if manager.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Update available banner
            if let newVersion = manager.updateAvailable {
                Button(action: {
                    openURL(URL(string: "https://github.com/richhickson/claudecodeusage/releases/latest")!)
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update Available: v\(newVersion)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            if let error = manager.error {
                errorView(error)
            } else if let usage = manager.usage {
                usageContent(usage)
            } else {
                loadingView()
            }
            
            Divider()
            
            // Footer
            footerView()
        }
        .frame(width: 280)
    }
    
    @ViewBuilder
    func usageContent(_ usage: UsageData) -> some View {
        VStack(spacing: 16) {
            if usage.extraUsageEnabled, let limit = usage.extraUsageMonthlyLimit, let used = usage.extraUsageUsedCredits {
                // Enterprise: spend row only
                OverageRow(
                    usedDollars: used / 100,
                    limitDollars: limit / 100,
                    percentage: usage.extraUsagePercentage ?? 0
                )
            } else {
                // Non-enterprise: rate-limit rows
                UsageRow(
                    title: "Session",
                    subtitle: "5-hour window",
                    percentage: usage.sessionPercentage,
                    resetsAt: usage.sessionResetsAt,
                    color: colorForPercentage(usage.sessionPercentage)
                )

                UsageRow(
                    title: "Weekly",
                    subtitle: "7-day window",
                    percentage: usage.weeklyPercentage,
                    resetsAt: usage.weeklyResetsAt,
                    color: colorForPercentage(usage.weeklyPercentage)
                )

                if let sonnetPct = usage.sonnetPercentage {
                    UsageRow(
                        title: "Sonnet Only",
                        subtitle: "Model-specific",
                        percentage: sonnetPct,
                        resetsAt: usage.sonnetResetsAt,
                        color: colorForPercentage(sonnetPct)
                    )
                }
            }
        }
        .padding()
    }
    
    @ViewBuilder
    func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            if error.contains("Not logged in") {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                Text("Not Signed In")
                    .font(.headline)

                Text("This app uses credentials from Claude Code stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Please run `claude` in Terminal and log in first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Open Terminal & Run Claude") {
                    launchClaudeCLI()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button("Install Claude Code") {
                    openURL(URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func loadingView() -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading usage data...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func footerView() -> some View {
        VStack(spacing: 8) {
            Button(action: {
                Task { await manager.checkForUpdates() }
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Check for Updates")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.top, 8)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }
                .padding(.horizontal)

            Divider()

            HStack {
                if let lastUpdated = manager.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    Task { await manager.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(manager.isLoading)

                Button(action: {
                    openURL(URL(string: "https://claude.ai")!)
                }) {
                    Image(systemName: "globe")
                }
                .buttonStyle(.borderless)

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)

            Divider()

            Button(action: {
                openURL(URL(string: "https://x.com/richhickson")!)
            }) {
                Text("Created by @richhickson")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    func colorForPercentage(_ pct: Int) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    func launchClaudeCLI() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

struct UsageRow: View {
    let title: String
    let subtitle: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text("\(percentage)%")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
            }
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100, height: 8)
                }
            }
            .frame(height: 8)
            
            // Reset time
            if let resetsAt = resetsAt {
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Resets \(formatTimeRemaining(resetsAt))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    func formatTimeRemaining(_ date: Date) -> String {
        let now = Date()
        let diff = date.timeIntervalSince(now)
        
        if diff <= 0 { return "soon" }
        
        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        
        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "in \(days)d \(remainingHours)h"
        }
        
        return "in \(hours)h \(minutes)m"
    }
}

struct OverageRow: View {
    let usedDollars: Double
    let limitDollars: Double
    let percentage: Int

    var color: Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overage")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Extra usage this month")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("$\(String(format: "%.2f", usedDollars))")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(color)
                    Text("of $\(String(format: "%.0f", limitDollars)) limit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(min(percentage, 100)) / 100, height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

#Preview {
    UsageView(manager: UsageManager())
}
