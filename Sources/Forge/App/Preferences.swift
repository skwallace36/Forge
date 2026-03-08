import AppKit

/// Global editor preferences, persisted via UserDefaults.
class Preferences {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key {
        static let fontName = "ForgeFontName"
        static let fontSize = "ForgeFontSize"
        static let tabWidth = "ForgeTabWidth"
        static let showMinimap = "ForgeShowMinimap"
        static let showIndentGuides = "ForgeShowIndentGuides"
        static let showInvisibles = "ForgeShowInvisibles"
        static let trimTrailingWhitespace = "ForgeTrimTrailingWhitespace"
        static let ensureTrailingNewline = "ForgeEnsureTrailingNewline"
        static let columnRuler = "ForgeColumnRuler"
        static let wordWrap = "ForgeWordWrap"
        static let bracketPairColorization = "ForgeBracketPairColorization"
        static let stickyScroll = "ForgeStickyScroll"
        static let inlineDiagnostics = "ForgeInlineDiagnostics"
        static let hoverTooltips = "ForgeHoverTooltips"
        static let inlineBlame = "ForgeInlineBlame"
    }

    // MARK: - Font

    /// The font family name (nil = system monospace)
    var fontName: String? {
        get { defaults.string(forKey: Key.fontName) }
        set {
            defaults.set(newValue, forKey: Key.fontName)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    /// Returns the editor font at the given size
    func editorFont(size: CGFloat? = nil) -> NSFont {
        let sz = size ?? fontSize
        if let name = fontName, let font = NSFont(name: name, size: sz) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: sz, weight: .regular)
    }

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

    var showInvisibles: Bool {
        get { defaults.bool(forKey: Key.showInvisibles) }
        set {
            defaults.set(newValue, forKey: Key.showInvisibles)
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

    var wordWrap: Bool {
        get { defaults.bool(forKey: Key.wordWrap) }
        set {
            defaults.set(newValue, forKey: Key.wordWrap)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    var bracketPairColorization: Bool {
        get {
            if defaults.object(forKey: Key.bracketPairColorization) == nil { return true }
            return defaults.bool(forKey: Key.bracketPairColorization)
        }
        set {
            defaults.set(newValue, forKey: Key.bracketPairColorization)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    var stickyScroll: Bool {
        get {
            if defaults.object(forKey: Key.stickyScroll) == nil { return true }
            return defaults.bool(forKey: Key.stickyScroll)
        }
        set {
            defaults.set(newValue, forKey: Key.stickyScroll)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    var inlineDiagnostics: Bool {
        get {
            if defaults.object(forKey: Key.inlineDiagnostics) == nil { return true }
            return defaults.bool(forKey: Key.inlineDiagnostics)
        }
        set {
            defaults.set(newValue, forKey: Key.inlineDiagnostics)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    var hoverTooltips: Bool {
        get {
            if defaults.object(forKey: Key.hoverTooltips) == nil { return true }
            return defaults.bool(forKey: Key.hoverTooltips)
        }
        set {
            defaults.set(newValue, forKey: Key.hoverTooltips)
            NotificationCenter.default.post(name: .preferencesDidChange, object: nil)
        }
    }

    var inlineBlame: Bool {
        get {
            if defaults.object(forKey: Key.inlineBlame) == nil { return true }
            return defaults.bool(forKey: Key.inlineBlame)
        }
        set {
            defaults.set(newValue, forKey: Key.inlineBlame)
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
