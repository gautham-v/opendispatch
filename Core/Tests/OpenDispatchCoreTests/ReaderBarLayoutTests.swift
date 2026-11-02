import Testing
@testable import OpenDispatchCore

@Suite("Reader bar layout")
struct ReaderBarLayoutTests {
    private static let allActions: [ReaderBarAction] = [.save, .listen, .highlights, .more, .split, .fullScreen]

    /// Tabs, overflow button, + and the spacing between them, as the strip draws them.
    private func used(_ row: TabRow, pinned: Int) -> Double {
        if let compact = row.compactWidth { return compact + ReaderBarLayout.tabSpacing + ReaderBarLayout.plusWidth }
        let tabs = row.visible.reduce(0.0) { $0 + (row.widths[$1] ?? ReaderBarLayout.pinnedTabWidth) }
        let overflow = row.hidden.isEmpty ? 0 : ReaderBarLayout.overflowWidth
        let items = row.visible.count + (row.hidden.isEmpty ? 0 : 1)
        return tabs + overflow + Double(items) * ReaderBarLayout.tabSpacing + ReaderBarLayout.plusWidth
    }

    @Test func allActionsMeasureAsTheBarDraws() {
        #expect(ReaderBarLayout.actionsWidth(Self.allActions) == 205)
        #expect(ReaderBarLayout.actionsWidth([.more]) == 28)
        #expect(ReaderBarLayout.actionsWidth([]) == 0)
    }

    @Test func nothingFoldsWithRoom() {
        let kept = ReaderBarLayout.keptActions(Self.allActions, contentWidth: 800, tabCount: 8)
        #expect(kept == Set(Self.allActions))
    }

    /// The 900pt minimum window leaves a 296pt pane, 264pt inside its padding.
    @Test func foldsInOrderAtTheMinimumWindow() {
        let one = ReaderBarLayout.keptActions(Self.allActions, contentWidth: 264, tabCount: 1)
        #expect(one == [.save, .more, .fullScreen])
        let many = ReaderBarLayout.keptActions(Self.allActions, contentWidth: 264, tabCount: 8)
        #expect(many == [.save, .more])
    }

    @Test func moreNeverFolds() {
        let kept = ReaderBarLayout.keptActions(Self.allActions, contentWidth: 40, tabCount: 3)
        #expect(kept == [.more])
    }

    @Test func listenStaysWhileReadingAloud() {
        let kept = ReaderBarLayout.keptActions(Self.allActions, contentWidth: 264, tabCount: 1, keeping: [.listen])
        #expect(kept.contains(.listen))
    }

    @Test func wideTabsStopAtTheMaximum() {
        let row = ReaderBarLayout.tabRow(width: 1200, count: 2, pinned: 0, active: 0)
        #expect(row.visible == [0, 1])
        #expect(row.hidden.isEmpty)
        #expect(row.widths[0] == ReaderBarLayout.maxTabWidth)
    }

    /// Screenshot 2: the Explore page at the minimum window, no actions, 270pt for the strip.
    @Test func twoTabsShareTheStrip() {
        let row = ReaderBarLayout.tabRow(width: 270, count: 2, pinned: 0, active: 1)
        #expect(row.visible == [0, 1])
        #expect(row.hidden.isEmpty)
        #expect(row.widths[0] == 119)
    }

    /// Screenshot 3: eight tabs, the last active.
    @Test func extraTabsMoveToOverflowAndActiveStays() {
        let row = ReaderBarLayout.tabRow(width: 270, count: 8, pinned: 0, active: 7)
        #expect(row.visible == [0, 7])
        #expect(row.hidden == [1, 2, 3, 4, 5, 6])
        #expect(row.widths[7] == ReaderBarLayout.activeTabMinWidth)
        #expect(row.widths[0]! >= ReaderBarLayout.inactiveTabMinWidth)
    }

    @Test func activeTabStaysInPlaceWhenAlreadyShown() {
        let row = ReaderBarLayout.tabRow(width: 270, count: 8, pinned: 0, active: 1)
        #expect(row.visible == [0, 1])
    }

    @Test func pinsStayBeforeOtherTabs() {
        let row = ReaderBarLayout.tabRow(width: 270, count: 6, pinned: 2, active: 5)
        #expect(row.visible.prefix(2) == [0, 1])
        #expect(row.visible.contains(5))
        #expect(row.widths[0] == nil)
    }

    @Test func activePinStaysWhenPinsOverflow() {
        let row = ReaderBarLayout.tabRow(width: 120, count: 6, pinned: 5, active: 4)
        #expect(row.visible.contains(4))
        #expect(row.hidden.count + row.visible.count == 6)
    }

    /// Screenshot 1 with every action kept: 59pt, not enough for a title.
    @Test func noRoomForATitleLeavesABadgeAndPlus() {
        let row = ReaderBarLayout.tabRow(width: 59, count: 3, pinned: 0, active: 2)
        #expect(row.compactWidth == 29)
        #expect(row.visible == [2])
        #expect(row.hidden == [0, 1])
    }

    @Test func everyTabIsReachableAndTheRowNeverOutgrowsTheStrip() {
        for width in stride(from: 58.0, through: 900, by: 7) {
            for count in 1...14 {
                for pinned in 0...min(count, 4) {
                    for active in 0..<count {
                        let row = ReaderBarLayout.tabRow(width: width, count: count, pinned: pinned, active: active)
                        #expect(row.visible.contains(active))
                        #expect(Set(row.visible + row.hidden) == Set(0..<count))
                        #expect(row.visible.count + row.hidden.count == count)
                        #expect(used(row, pinned: pinned) <= width + 0.5, "width \(width), count \(count), pinned \(pinned), active \(active)")
                        for tab in row.visible where row.widths[tab] != nil {
                            let least = tab == active ? ReaderBarLayout.activeTabMinWidth : ReaderBarLayout.inactiveTabMinWidth
                            #expect(row.widths[tab]! >= least - 1)
                        }
                    }
                }
            }
        }
    }
}
