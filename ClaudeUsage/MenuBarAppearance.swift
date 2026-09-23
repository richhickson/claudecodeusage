import AppKit

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case native   // template SF Symbol icon, monochrome; text turns orange/red on warning
    case tinted   // SF Symbol icon tinted green/yellow/red by usage level
    case emoji    // classic 🟢/🟡/🔴 indicator

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "Native"
        case .tinted: return "Tinted"
        case .emoji: return "Emoji"
        }
    }
}

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case session
    case weekly
    case model
    case spend
    case iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "Session %"
        case .weekly: return "Weekly %"
        case .model: return "Model %"
        case .spend: return "Spend"
        case .iconOnly: return "Icon only"
        }
    }
}

struct MenuBarAppearance {
    static var style: MenuBarStyle {
        get { UserDefaults.standard.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init) ?? .native }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarStyle") }
    }

    static var metric: MenuBarMetric {
        get { UserDefaults.standard.string(forKey: "menuBarMetric").flatMap(MenuBarMetric.init) ?? .session }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarMetric") }
    }

    /// One-time default: installs that predate the appearance setting keep the
    /// emoji look so nothing changes under them on update. Fresh installs get native.
    static func applyMigrationDefault() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "menuBarStyle") == nil else { return }
        let isExistingInstall = defaults.object(forKey: "hasLaunchedBefore") != nil
            || defaults.object(forKey: "lastStatusIndicator") != nil
        if isExistingInstall {
            defaults.set(MenuBarStyle.emoji.rawValue, forKey: "menuBarStyle")
        }
    }
}
