import Foundation

/// A button in the reader bar's action group, in bar order.
public enum ReaderBarAction: Hashable, Sendable {
    case save, listen, highlights, more, split, fullScreen
}

/// How the reader bar (macOS / iPad) shares a narrow width: which actions stay out of the More menu, and
/// which tabs stay in the row. Sizes are points.
public enum ReaderBarLayout {
    public static let plusWidth = 28.0
    public static let tabSpacing = 2.0
    public static let overflowWidth = 44.0
    public static let pinnedTabWidth = 32.0
    public static let maxTabWidth = 196.0
    /// Enough for the × and a title of about seven characters ("Explore").
    public static let activeTabMinWidth = 104.0
    /// An inactive tab has no × until hovered, so it fits a similar title in less.
    public static let inactiveTabMinWidth = 80.0

    static let actionSize = 28.0
    static let actionSpacing = 4.0
    /// The hairline between article actions and window controls, with its padding.
    static let actionDividerWidth = 13.0
    /// Room to leave the tabs: one titled tab and +, or with others one titled tab, the overflow button and +.
    static let singleTabRoom = 130.0
    static let manyTabsRoom = 180.0
    /// What folds into More first; More itself never folds.
    static let foldOrder: [ReaderBarAction] = [.split, .highlights, .listen, .fullScreen, .save]

    /// The width of a group of action buttons, with the hairline when it has both article actions and window controls.
    public static func actionsWidth(_ actions: [ReaderBarAction]) -> Double {
        guard !actions.isEmpty else { return 0 }
        let windowControls = actions.filter { $0 == .split || $0 == .fullScreen }.count
        let divider = windowControls > 0 && windowControls < actions.count
        let buttons = Double(actions.count) * actionSize + Double(actions.count - 1) * actionSpacing
        return buttons + (divider ? actionDividerWidth + actionSpacing : 0)
    }

    /// The actions that stay in the bar. `contentWidth` is the bar inside its padding. Actions fold one at a
    /// time until the tabs have room, except those in `keeping` (Listen while it is reading aloud).
    public static func keptActions(
        _ actions: [ReaderBarAction],
        contentWidth: Double,
        tabCount: Int,
        keeping: Set<ReaderBarAction> = []
    ) -> Set<ReaderBarAction> {
        let room = tabCount > 1 ? manyTabsRoom : singleTabRoom
        var kept = actions
        for action in foldOrder where !keeping.contains(action) {
            if contentWidth - actionsWidth(kept) >= room { break }
            kept.removeAll { $0 == action }
        }
        return Set(kept)
    }

    /// The tab row for a strip of `width` points. See `TabRow`.
    public static func tabRow(width: Double, count: Int, pinned: Int, active: Int) -> TabRow {
        guard count > 0 else { return TabRow(visible: [], hidden: [], widths: [:], compactWidth: nil) }
        let activeIsPinned = active < pinned
        let unpinnedCount = count - pinned
        let leastUnpinned = activeIsPinned || unpinnedCount == 0 ? 0 : 1
        let leastPinned = activeIsPinned ? 1 : 0

        // All the pins with as many tabs as fit, then fewer pins beside the one tab that must show.
        for shown in stride(from: unpinnedCount, through: leastUnpinned, by: -1) {
            if let row = row(width, count, pinned, active, pinsShown: pinned, tabsShown: shown) { return row }
        }
        for pins in stride(from: pinned - 1, through: leastPinned, by: -1) {
            if let row = row(width, count, pinned, active, pinsShown: pins, tabsShown: leastUnpinned) { return row }
        }
        // No room for a title: the active tab as a badge, and +.
        return TabRow(
            visible: [active],
            hidden: (0..<count).filter { $0 != active },
            widths: [:],
            compactWidth: max(actionSize, width - plusWidth - tabSpacing)
        )
    }

    private static func row(_ width: Double, _ count: Int, _ pinned: Int, _ active: Int, pinsShown: Int, tabsShown: Int) -> TabRow? {
        let activeIsPinned = active < pinned
        let overflows = pinsShown + tabsShown < count
        let items = pinsShown + tabsShown + (overflows ? 1 : 0)
        let room = width - plusWidth - (overflows ? overflowWidth : 0)
            - Double(items) * tabSpacing - Double(pinsShown) * pinnedTabWidth
        let least = tabsShown == 0 ? 0
            : activeIsPinned ? Double(tabsShown) * inactiveTabMinWidth
            : activeTabMinWidth + Double(tabsShown - 1) * inactiveTabMinWidth
        guard room >= least else { return nil }

        let pins = shown(pinsShown, of: Array(0..<pinned), including: active)
        let tabs = shown(tabsShown, of: Array(pinned..<count), including: active)
        var widths: [Int: Double] = [:]
        if tabsShown > 0 {
            let share = min(maxTabWidth, room / Double(tabsShown))
            let others = (room - activeTabMinWidth) / Double(max(tabsShown - 1, 1))
            for tab in tabs {
                let tabWidth = activeIsPinned || share >= activeTabMinWidth ? share
                    : tab == active ? activeTabMinWidth : others
                widths[tab] = tabWidth.rounded(.down)
            }
        }
        let visible = pins + tabs
        return TabRow(visible: visible, hidden: (0..<count).filter { !visible.contains($0) }, widths: widths, compactWidth: nil)
    }

    /// The first `count` of `tabs`, the active one in the last place if it would be left out.
    private static func shown(_ count: Int, of tabs: [Int], including active: Int) -> [Int] {
        var result = Array(tabs.prefix(count))
        if !result.isEmpty, tabs.contains(active), !result.contains(active) {
            result[result.count - 1] = active
        }
        return result
    }
}

/// The reader bar's tabs at one width. The active tab is always in `visible`.
public struct TabRow: Equatable, Sendable {
    /// Tab indexes in the row, in order.
    public let visible: [Int]
    /// Tab indexes in the overflow menu, in order.
    public let hidden: [Int]
    /// Width of each visible unpinned tab; pinned tabs have `ReaderBarLayout.pinnedTabWidth`.
    public let widths: [Int: Double]
    /// Set when not even one titled tab fits: the active tab, this wide, shows only its badge.
    public let compactWidth: Double?
}
