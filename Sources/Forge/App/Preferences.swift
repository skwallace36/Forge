import AppKit

/// Global editor preferences, persisted via UserDefaults.
class Preferences {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key {
        static let fontSize = "ForgeFontSize"
        static let tabWidth = "ForgeTabWidth"
        static let showMinimap = "ForgeShowMinimap"
        static let showIndentGuides = "ForgeShowIndentGuides"
        static let trimTrailingWhitespace = "ForgeTrimTrailingWhitespace"
        static let ensureTrailingNewline = "ForgeEnsureTrailingNewline"
        static let columnRuler = "ForgeColumnRuler"
    }

    // MARK: - Font

    var fontSize: CGFloat {
        get {
            let v = defaults.double(forKey: Key.fontSize)
            return v > 0 ? v : 13
        }
        set {
            defaults.set(newValue, forKey: Key.fontSize)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    // MARK: - Tab Width

    var tabWidth: Int {
        get {
            let v = defaults.integer(forKey: Key.tabWidth)
            return v > 0 ? v : 4
        }
        set {
            defaults.set(newValue, forKey: Key.tabWidth)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    // MARK: - View Options

    var showMinimap: Bool {
        get {
            if defaults.object(forKey: Key.showMinimap) == nil { return true }
            return defaults.bool(forKey: Key.showMinimap)
        }
        set {
            defaults.set(newValue, forKey: Key.showMinimap)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    var showIndentGuides: Bool {
        get {
            if defaults.object(forKey: Key.showIndentGuides) == nil { return true }
            return defaults.bool(forKey: Key.showIndentGuides)
        }
        set {
            defaults.set(newValue, forKey: Key.showIndentGuides)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    /// Column ruler position (0 = disabled, common values: 80, 100, 120)
    var columnRuler: Int {
        get { defaults.integer(forKey: Key.columnRuler) }
        set {
            defaults.set(newValue, forKey: Key.columnRuler)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    // MARK: - Save Behavior

    var trimTrailingWhitespace: Bool {
        get {
            if defaults.object(forKey: Key.trimTrailingWhitespace) == nil { return true }
            return defaults.bool(forKey: Key.trimTrailingWhitespace)
        }
        set {
            defaults.set(newValue, forKey: Key.trimTrailingWhitespace)
        }
    }

    var ensureTrailingNewline: Bool {
        get {
            if defaults.object(forKey: Key.ensureTrailingNewline) == nil { return true }
            return defaults.bool(forKey: Key.ensureTrailingNewline)
        }
        set {
            defaults.set(newValue, forKey: Key.ensureTrailingNewline)
        }
    }
}

extension Notification.Name {
    static let preferencesDidChange = Notification.Name("ForgePreferencesDidChange")
}
