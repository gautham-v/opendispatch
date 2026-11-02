import Foundation

/// A key pressed with ⌘, ⌥ or ⌃ (and maybe ⇧): what the menus and the iPad's key commands respond to.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// Named keys, stored by these names; anything else is one lowercase character.
    public enum Named {
        public static let left = "left", right = "right", up = "up", down = "down"
        public static let home = "home", end = "end", pageUp = "pageUp", pageDown = "pageDown"
        static let glyphs = [left: "←", right: "→", up: "↑", down: "↓", home: "Home", end: "End", pageUp: "Page Up", pageDown: "Page Down"]
    }

    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = Named.glyphs[key] != nil ? key : key.lowercased()
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// The caps as macOS orders them: ⌃ ⌥ ⇧ ⌘, then the key.
    public var caps: [String] {
        var out: [String] = []
        if control { out.append("⌃") }
        if option { out.append("⌥") }
        if shift { out.append("⇧") }
        if command { out.append("⌘") }
        out.append(Named.glyphs[key] ?? key.uppercased())
        return out
    }

    public var text: String { caps.joined() }

    /// Taken by macOS or by text editing, whatever the app wants.
    public var isReserved: Bool { Self.reserved.contains(self) }

    private static let reserved: Set<KeyCombo> = [
        KeyCombo("q"), KeyCombo("q", option: true), KeyCombo("q", control: true),
        KeyCombo("h"), KeyCombo("h", option: true), KeyCombo("m"), KeyCombo("`"),
        KeyCombo("a"), KeyCombo("c"), KeyCombo("v"), KeyCombo("x"), KeyCombo("z"), KeyCombo("z", shift: true),
        KeyCombo("f", control: true),
    ]
}

/// What an action responds to. `key` is a single key pressed alone (with Shift at most), which only works
/// outside text fields; on a chord action it is the key after g. `combo` is a key with ⌘, ⌥ or ⌃.
public struct ShortcutBinding: Codable, Hashable, Sendable {
    public var key: String?
    public var combo: KeyCombo?

    public init(key: String? = nil, combo: KeyCombo? = nil) {
        self.key = key
        self.combo = combo
    }
}

public enum ShortcutSlot: String, Sendable {
    case key, combo
}

/// Every action a shortcut can be given. Raw values are stored in the settings, so they stay put.
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case nextItem, previousItem, openOriginal, toggleSaved, toggleRead, markAllRead, reloadArticle, copyMarkdown, listen, popOutVideo
    case viewAll, viewArticles, viewPosts, viewVideo, viewPodcasts, viewSaved, viewHighlights, viewHistory
    case nextTab, previousTab, newTab, openLink, closeTab, reopenTab, pinTab, back, forward, split, moveTabLeft, moveTabRight
    case search, filterSources, refresh, addSource, sidebar, fullScreen, settings, showShortcuts

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .nextItem: "Next item"
        case .previousItem: "Previous item"
        case .openOriginal: "Open original in the browser"
        case .toggleSaved: "Save or unsave"
        case .toggleRead: "Mark as read or unread"
        case .markAllRead: "Mark all as read"
        case .reloadArticle: "Reload the article"
        case .copyMarkdown: "Copy the article as Markdown"
        case .listen: "Listen to the article, pause or resume"
        case .popOutVideo: "Pop out the video, or bring it back"
        case .viewAll: "All"
        case .viewArticles: "Articles"
        case .viewPosts: "Posts"
        case .viewVideo: "Video"
        case .viewPodcasts: "Podcasts"
        case .viewSaved: "Saved"
        case .viewHighlights: "Highlights"
        case .viewHistory: "History"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .newTab: "New tab"
        case .openLink: "Open a link in a new tab"
        case .closeTab: "Close the tab"
        case .reopenTab: "Reopen the last closed tab"
        case .pinTab: "Pin or unpin the tab"
        case .back: "Back"
        case .forward: "Forward"
        case .split: "Split view on or off"
        case .moveTabLeft: "Move the tab to the left pane"
        case .moveTabRight: "Move the tab to the right pane, or split to the right"
        case .search: "Search"
        case .filterSources: "Filter sources in the sidebar"
        case .refresh: "Refresh feeds"
        case .addSource: "Add a source"
        case .sidebar: "Show or hide the sidebar"
        case .fullScreen: "Full-screen reader"
        case .settings: "Settings"
        case .showShortcuts: "Show these shortcuts"
        }
    }

    public var defaultBinding: ShortcutBinding {
        switch self {
        case .nextItem: ShortcutBinding(key: "j")
        case .previousItem: ShortcutBinding(key: "k")
        case .openOriginal: ShortcutBinding(key: "o")
        case .toggleSaved: ShortcutBinding(key: "s")
        case .toggleRead: ShortcutBinding(key: "m")
        case .markAllRead, .pinTab, .viewArticles, .viewPosts, .viewHighlights: ShortcutBinding()
        case .reloadArticle: ShortcutBinding(combo: KeyCombo("r", shift: true))
        case .copyMarkdown: ShortcutBinding(combo: KeyCombo("c", shift: true))
        case .listen: ShortcutBinding(combo: KeyCombo("l", shift: true))
        case .popOutVideo: ShortcutBinding(key: "i")
        case .viewAll: ShortcutBinding(key: "a")
        case .viewVideo: ShortcutBinding(key: "v")
        case .viewPodcasts: ShortcutBinding(key: "p")
        case .viewSaved: ShortcutBinding(key: "s")
        case .viewHistory: ShortcutBinding(key: "h")
        case .nextTab: ShortcutBinding(combo: KeyCombo("]", shift: true))
        case .previousTab: ShortcutBinding(combo: KeyCombo("[", shift: true))
        case .newTab: ShortcutBinding(combo: KeyCombo("t"))
        case .openLink: ShortcutBinding(combo: KeyCombo("l"))
        case .closeTab: ShortcutBinding(combo: KeyCombo("w"))
        case .reopenTab: ShortcutBinding(combo: KeyCombo("t", shift: true))
        case .back: ShortcutBinding(combo: KeyCombo("["))
        case .forward: ShortcutBinding(combo: KeyCombo("]"))
        case .split: ShortcutBinding(combo: KeyCombo("s", option: true))
        case .moveTabLeft: ShortcutBinding(combo: KeyCombo(KeyCombo.Named.left, control: true))
        case .moveTabRight: ShortcutBinding(combo: KeyCombo(KeyCombo.Named.right, control: true))
        case .search: ShortcutBinding(key: "/", combo: KeyCombo("f"))
        case .filterSources: ShortcutBinding(combo: KeyCombo("k"))
        case .refresh: ShortcutBinding(key: "r", combo: KeyCombo("r"))
        case .addSource: ShortcutBinding(combo: KeyCombo("n"))
        case .sidebar: ShortcutBinding(combo: KeyCombo("\\"))
        case .fullScreen: ShortcutBinding(combo: KeyCombo("f", shift: true))
        case .settings: ShortcutBinding(combo: KeyCombo(","))
        case .showShortcuts: ShortcutBinding(key: "?", combo: KeyCombo("/"))
        }
    }

    /// Its single key is pressed after g.
    public var isChord: Bool {
        switch self {
        case .viewAll, .viewArticles, .viewPosts, .viewVideo, .viewPodcasts, .viewSaved, .viewHighlights, .viewHistory: true
        default: false
        }
    }

    /// Keys that always do this too, and can't be changed.
    public var fixedKeys: [String] {
        switch self {
        case .nextItem: ["↓"]
        case .previousItem: ["↑"]
        case .openOriginal: ["Enter"]
        default: []
        }
    }

    /// No menu item carries this on the Mac, so the window's key monitor answers its ⌘ shortcut itself.
    public var hasNoMenuItem: Bool {
        switch self {
        case .nextItem, .previousItem, .openOriginal, .toggleSaved: true
        default: false
        }
    }
}

/// A line of the shortcuts lists: an action, or something fixed that's only listed.
public enum ShortcutRow: Hashable, Sendable {
    case action(ShortcutAction)
    case fixed(label: String, keys: [String], separator: String?)
}

public struct ShortcutSection: Hashable, Sendable {
    public let title: String
    public let rows: [ShortcutRow]

    /// The Shortcuts pane and the ⌘/ overlay, in display order.
    public static let all: [ShortcutSection] = [
        ShortcutSection(title: "Items", rows: [
            .action(.nextItem), .action(.previousItem), .action(.openOriginal), .action(.toggleSaved), .action(.toggleRead),
            .action(.markAllRead), .action(.reloadArticle), .action(.copyMarkdown), .action(.listen),
            .fixed(label: "Play or pause the video", keys: ["Space"], separator: nil),
            .fixed(label: "Skip the video back or ahead 5 seconds", keys: ["←", "→"], separator: "or"),
            .action(.popOutVideo),
        ]),
        ShortcutSection(title: "Views", rows: [
            .action(.viewAll), .action(.viewArticles), .action(.viewPosts), .action(.viewVideo), .action(.viewPodcasts),
            .action(.viewSaved), .action(.viewHighlights), .action(.viewHistory),
        ]),
        ShortcutSection(title: "Tabs and split view", rows: [
            .fixed(label: "Open in a new tab", keys: ["⌘", "click"], separator: nil),
            .fixed(label: "Open in split view", keys: ["⌥", "click"], separator: nil),
            .action(.nextTab), .action(.previousTab), .action(.newTab), .action(.openLink), .action(.closeTab), .action(.reopenTab),
            .action(.pinTab), .action(.back), .action(.forward), .action(.split), .action(.moveTabLeft), .action(.moveTabRight),
        ]),
        ShortcutSection(title: "App", rows: [
            .action(.search), .action(.filterSources), .action(.refresh), .action(.addSource), .action(.sidebar), .action(.fullScreen),
            .action(.settings),
            .fixed(label: "Clear the source filter or search, or leave full screen", keys: ["Esc"], separator: nil),
            .action(.showShortcuts),
        ]),
    ]
}

/// A key the Shortcuts pane has recorded.
public enum ShortcutCandidate: Hashable, Sendable {
    case key(String)
    case combo(KeyCombo)

    public var slot: ShortcutSlot {
        switch self {
        case .key: .key
        case .combo: .combo
        }
    }
}

/// What a press means while the pane is recording.
public enum RecordedPress: Hashable, Sendable {
    case cancel
    case remove
    case candidate(ShortcutCandidate)
    /// Space, Return, Tab or an arrow alone, or anything else that can't be a shortcut.
    case unusable
}

public enum ShortcutCheck: Equatable, Sendable {
    case ok
    /// macOS or text editing needs it.
    case reserved
    /// g starts the view shortcuts.
    case chordPrefix
    case inUse(by: ShortcutAction)
}

/// The shortcuts in use: each action's default apart from the ones changed, which are all that's stored,
/// so a later change to a default reaches everyone who never touched that action.
public struct ShortcutMap: Codable, Equatable, Sendable {
    /// The key that starts the view shortcuts.
    public static let chordPrefix = "g"

    private var changes: [String: ShortcutBinding] = [:]

    public init() {}

    public func binding(for action: ShortcutAction) -> ShortcutBinding {
        changes[action.rawValue] ?? action.defaultBinding
    }

    public func isChanged(_ action: ShortcutAction) -> Bool {
        binding(for: action) != action.defaultBinding
    }

    public var changedCount: Int { ShortcutAction.allCases.filter(isChanged).count }

    public mutating func reset(_ action: ShortcutAction) { changes[action.rawValue] = nil }

    public mutating func resetAll() { changes = [:] }

    /// The action a plain key runs, not counting the ones that come after g.
    public func action(forKey key: String) -> ShortcutAction? {
        ShortcutAction.allCases.first { !$0.isChord && binding(for: $0).key == key }
    }

    /// The action the key after g runs.
    public func action(forChordKey key: String) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0.isChord && binding(for: $0).key == key }
    }

    public func action(forCombo combo: KeyCombo) -> ShortcutAction? {
        ShortcutAction.allCases.first { binding(for: $0).combo == combo }
    }

    /// Whether `action` can take `candidate`.
    public func check(_ candidate: ShortcutCandidate, for action: ShortcutAction) -> ShortcutCheck {
        let other: ShortcutAction?
        switch candidate {
        case .combo(let combo):
            if combo.isReserved { return .reserved }
            other = self.action(forCombo: combo)
        case .key(let key):
            if action.isChord {
                other = self.action(forChordKey: key)
            } else {
                if key == Self.chordPrefix { return .chordPrefix }
                other = self.action(forKey: key)
            }
        }
        if let other, other != action { return .inUse(by: other) }
        return .ok
    }

    /// Gives `action` the candidate, taking it off whichever action had it. `replacing` is the slot the
    /// person clicked: a new key of the other kind still replaces what they clicked.
    public mutating func assign(_ candidate: ShortcutCandidate, to action: ShortcutAction, replacing: ShortcutSlot? = nil) {
        if case .inUse(let other) = check(candidate, for: action) {
            remove(candidate.slot, from: other)
        }
        var b = binding(for: action)
        if let replacing { b.clear(replacing) }
        switch candidate {
        case .key(let key): b.key = key
        case .combo(let combo): b.combo = combo
        }
        store(b, for: action)
    }

    public mutating func remove(_ slot: ShortcutSlot, from action: ShortcutAction) {
        var b = binding(for: action)
        b.clear(slot)
        store(b, for: action)
    }

    private mutating func store(_ binding: ShortcutBinding, for action: ShortcutAction) {
        changes[action.rawValue] = binding == action.defaultBinding ? nil : binding
    }
}

private extension ShortcutBinding {
    mutating func clear(_ slot: ShortcutSlot) {
        switch slot {
        case .key: key = nil
        case .combo: combo = nil
        }
    }
}
