import SwiftUI
import Combine
import UserNotifications

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static private(set) var shared: AppDelegate?

    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var settingsWindow: NSWindow?
    var usageManager = UsageManager()
    var sessionMonitor = SessionMonitor()
    var statusMonitor = StatusMonitor()
    var updateInstaller = UpdateInstaller()
    var timer: Timer?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Hide dock icon - menubar only
        NSApp.setActivationPolicy(.accessory)

        MenuBarAppearance.applyMigrationDefault()

        // Present notification banners even when the app is considered active
        UNUserNotificationCenter.current().delegate = self

        setupStatusItem()
        setupPopover()
        setupWakeNotification()
        setupUsageObserver()
        startFetching()
        statusMonitor.start()

        // Request notification permission after launch completes (too early fails silently)
        if sessionMonitor.hooksInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.sessionMonitor.requestNotificationPermission()
            }
        }
    }

    func setupWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func setupUsageObserver() {
        // Auto-update status item when usage or error changes
        usageManager.$usage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        usageManager.$error
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        sessionMonitor.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    @objc func handleWake() {
        // Delay refresh after wake to allow keychain to unlock
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await usageManager.refresh()
        }
    }

    func startFetching() {
        // Initial fetch and update check
        Task {
            // If system recently booted (within 60 seconds), wait before accessing keychain
            // The keychain/login system takes time to be fully available after boot
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime < 60 {
                let delaySeconds = max(30 - uptime, 5) // Wait until ~30s after boot, minimum 5s
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }

            await usageManager.refresh()
            await usageManager.checkForUpdates()
        }

        // Refresh every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.usageManager.refresh()
            }
        }
    }
    
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "⏳"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 320)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: UsageView(manager: usageManager, sessionMonitor: sessionMonitor, statusMonitor: statusMonitor, updateInstaller: updateInstaller))
    }
    
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let attentionSessions = sessionMonitor.needsAttentionSessions
        let attentionCount = attentionSessions.count
        // One waiting session: name it, so no click is needed to know which.
        // Several: a count is the honest summary.
        let attentionLabel: String
        if attentionCount == 1, let name = attentionSessions.first?.projectName, !name.isEmpty {
            attentionLabel = name.count > 14 ? String(name.prefix(13)) + "…" : name
        } else {
            attentionLabel = "\(attentionCount)"
        }
        let bell = attentionCount > 0 ? "🔔 \(attentionLabel) " : ""
        let style = MenuBarAppearance.style
        let metric = MenuBarAppearance.metric

        if style == .emoji {
            button.image = nil
            if let usage = usageManager.usage {
                let text = metricText(usage: usage, metric: metric)
                button.title = "\(bell)\(usageManager.statusEmoji)\(text.isEmpty ? "" : " \(text)")"
            } else if usageManager.error != nil {
                button.title = "\(bell)❌"
            } else {
                button.title = "\(bell)⏳"
            }
            return
        }

        // Native / tinted: SF Symbol icon + optional text.
        // While sessions need attention, the icon becomes an orange bell.
        let maxUtil = usageManager.maxUtilization

        let styleIcon: NSImage?
        if style == .tinted {
            styleIcon = statusSymbol("chart.bar.fill", tint: tintColor(maxUtil), accessibility: "Claude usage")
        } else {
            styleIcon = statusSymbol("chart.bar.fill", tint: nil, accessibility: "Claude usage")
        }

        if attentionCount > 0,
           let bellIcon = statusSymbol("bell.badge.fill", tint: .systemOrange, accessibility: "Sessions need attention") {
            // The bell joins the style's icon rather than replacing it. A template
            // image can't be composited, so the native chart is tinted with
            // labelColor, which resolves at draw time and adapts to the menu bar.
            let chart = style == .tinted
                ? styleIcon
                : statusSymbol("chart.bar.fill", tint: .labelColor, accessibility: "Claude usage")
            if let chart = chart {
                let combined = compositeImage(bellIcon, chart)
                combined.accessibilityDescription = "Sessions need attention"
                button.image = combined
            } else {
                button.image = bellIcon
            }
        } else {
            button.image = styleIcon
        }
        button.imagePosition = .imageLeading

        var text: String
        if let usage = usageManager.usage {
            text = metricText(usage: usage, metric: metric)
        } else if usageManager.error != nil {
            text = "!"
        } else {
            text = "…"
        }
        if attentionCount > 0 {
            text = text.isEmpty ? attentionLabel : "\(attentionLabel) · \(text)"
        }
        let full = text.trimmingCharacters(in: .whitespaces)

        // Native style: color the text only when a limit is running hot
        if style == .native, maxUtil >= 70, !full.isEmpty, usageManager.usage != nil {
            let color: NSColor = maxUtil >= 90 ? .systemRed : .systemOrange
            button.attributedTitle = NSAttributedString(string: full, attributes: [
                .foregroundColor: color,
                .font: NSFont.menuBarFont(ofSize: 0),
            ])
        } else {
            button.title = full
        }
    }

    private func metricText(usage: UsageData, metric: MenuBarMetric) -> String {
        switch metric {
        case .session:
            return "\(usage.sessionPercentage)%"
        case .weekly:
            return "\(usage.weeklyPercentage)%"
        case .model:
            if let maxModel = usage.modelLimits.map(\.utilization).max() {
                return "\(Int(maxModel))%"
            }
            return "\(usage.sessionPercentage)%"
        case .spend:
            if let used = usage.extraUsageUsedCredits {
                return String(format: "$%.2f", used / 100)
            }
            return "$0"
        case .iconOnly:
            return ""
        }
    }

    private func tintColor(_ maxUtil: Double) -> NSColor {
        if maxUtil >= 90 { return .systemRed }
        if maxUtil >= 70 { return .systemYellow }
        return .systemGreen
    }

    /// SF Symbol for the status item. NSStatusBarButton ignores symbol palette
    /// configurations, so tints are baked in by rasterizing with .sourceAtop.
    private func statusSymbol(_ name: String, tint: NSColor?, accessibility: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(config) else { return nil }

        guard let tint = tint else {
            base.isTemplate = true
            return base
        }

        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.accessibilityDescription = accessibility
        return tinted
    }

    /// Two images side by side in one status item image (drawn at display time,
    /// so dynamic colors like labelColor resolve against the menu bar appearance).
    private func compositeImage(_ left: NSImage, _ right: NSImage, gap: CGFloat = 3) -> NSImage {
        let size = NSSize(
            width: left.size.width + gap + right.size.width,
            height: max(left.size.height, right.size.height)
        )
        let image = NSImage(size: size, flipped: false) { _ in
            left.draw(in: NSRect(
                x: 0, y: (size.height - left.size.height) / 2,
                width: left.size.width, height: left.size.height))
            right.draw(in: NSRect(
                x: left.size.width + gap, y: (size.height - right.size.height) / 2,
                width: right.size.width, height: right.size.height))
            return true
        }
        image.isTemplate = false
        return image
    }
    
    func openSettingsWindow() {
        popover?.performClose(nil)

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClaudeUsage Settings"
            window.contentViewController = NSHostingController(rootView: ClaudeSettingsView(sessionMonitor: sessionMonitor, statusMonitor: statusMonitor))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["session_id"] as? String
        let statusURL = userInfo["status_url"] as? String
        Task { @MainActor in
            if let sessionId {
                self.sessionMonitor.focusSession(id: sessionId)
            } else if let statusURL, let url = URL(string: statusURL) {
                NSWorkspace.shared.open(url)
            }
            completionHandler()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // Bring to front
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
