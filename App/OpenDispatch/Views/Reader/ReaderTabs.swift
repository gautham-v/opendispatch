import OpenDispatchCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// One reader pane: the active tab's item, the Start here board, a new tab, or the empty state. In split view a click anywhere
/// in the pane (the article's web view included) focuses it, so the list and j/k act on it.
struct ReaderPaneView: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let item = model.activeItem(inPane: pane) {
                ReaderItemView(item: item, pane: pane)
                    .id(item.id)
            } else if model.panes.indices.contains(pane), model.isStartHere(model.panes[pane].activeTab) {
                StartHerePane(pane: pane)
            } else if model.panes.indices.contains(pane), model.panes[pane].activeTab.isNew {
                NewTabView(pane: pane)
            } else {
                ReaderEmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ofSurface)
        .overlay { TabDropOverlay(pane: pane) }
        #if os(macOS)
        .background {
            if model.isSplit { PaneMouseDownProbe { model.focusPane(pane) } }
        }
        #else
        .simultaneousGesture(TapGesture().onEnded { if model.isSplit { model.focusPane(pane) } })
        #endif
    }
}

/// A new tab (+ or ⌘T) is Explore: a field that searches videos, podcast episodes and sources to add, or
/// opens any link (⌘L). With nothing searched it lists recent searches, what was read last (History) and
/// the latest saved items; with a query, the results (the column widens). Opening anything, from here or
/// the list, fills this tab. The last results stay, so the next new tab shows them again.
struct NewTabView: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var saved: [FeedItem] = []

    private var isSearching: Bool { !model.explore.query.isEmpty }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ExploreSearchField(pane: pane)
                    if isSearching {
                        ExploreDesktopResults(pane: pane)
                    } else {
                        ExploreSuggestedSources(horizontalPadding: 8) { seeAll in
                            HStack {
                                Text("Sources for you")
                                    .font(OFFont.ui(13))
                                    .foregroundStyle(.ofMuted)
                                Spacer()
                                seeAll
                                    .buttonStyle(.plain)
                                    .font(OFFont.ui(13))
                                    .foregroundStyle(.ofAccent)
                            }
                            .padding(.horizontal, 8)
                        }
                        ExploreRecentSearches(pane: pane)
                        recentlyRead
                        section("Saved", saved)
                    }
                }
                .frame(maxWidth: isSearching ? 720 : 440)
                .padding(.horizontal, 24)
                .padding(.vertical, 56)
                // Exactly the pane's width: the page's own minimum would otherwise push the pane, and its
                // bar, past the window.
                .frame(width: geo.size.width)
            }
            .scrollContentBackground(.hidden)
            .overlayScrollers()
            .safeAreaInset(edge: .top, spacing: 0) {
                ReaderBar(pane: pane) {
                    if model.isSplit {
                        Button { model.closePane(pane) } label: { OFIcon.close.image }
                            .buttonStyle(ReaderIconButtonStyle(size: Metrics.readerActionButton, glyph: Metrics.readerActionGlyph))
                            .help("Close this pane")
                            .accessibilityLabel("Close pane")
                    }
                }
            }
        }
        .background(Color.ofSurface)
        .task { saved = (try? await model.database.items(ItemQuery(view: .saved, limit: 5)).items) ?? [] }
        .task { await model.loadSourceSuggestions() }
    }

    @ViewBuilder private func section(_ title: String, _ items: [FeedItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle(title)
                ForEach(items, id: \.id) { item in
                    NewTabRow(host: item.source.host, sourceTitle: item.originName, title: item.item.title) {
                        model.focusPane(pane)
                        model.open(item)
                    }
                }
            }
        }
    }

    /// The last five articles opened, from History, so it outlives the session.
    @ViewBuilder private var recentlyRead: some View {
        let entries = Array(model.history.opened.prefix(5))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Recently read")
                ForEach(entries) { entry in
                    NewTabRow(host: URLHost.host(of: entry.itemUrl), sourceTitle: entry.originLabel, title: entry.itemTitle) {
                        model.focusPane(pane)
                        Task { await model.open(entry) }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(OFFont.ui(13))
            .foregroundStyle(.ofMuted)
            .padding(.leading, 8)
            .padding(.bottom, 4)
    }
}

/// An item on the new tab: badge, title, source muted on the right; the hover grey under the pointer.
private struct NewTabRow: View {
    let host: String
    let sourceTitle: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SourceBadge(host: host, title: sourceTitle, size: 16)
                Text(title)
                    .foregroundStyle(.ofInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sourceTitle)
                    .foregroundStyle(.ofMuted)
                    .lineLimit(1)
            }
            .font(OFFont.ui(13))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(hovering ? Color.ofHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// Split view: two panes with a draggable hairline between them (double-click it to even them out).
struct ReaderSplitView: View {
    @Environment(AppModel.self) private var model

    /// The narrowest a pane gets from dragging the divider.
    private static let paneMinWidth: CGFloat = 300
    private static let space = "reader-split"

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ReaderPaneView(pane: 0)
                    .frame(width: (width * model.splitFraction).rounded())
                divider(width: width)
                ReaderPaneView(pane: 1)
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    private func divider(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.ofHairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .pointerStyle(.columnResize)
                    #endif
                    .onTapGesture(count: 2) { model.splitFraction = 0.5 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .onChanged { value in
                                let least = min(0.5, Self.paneMinWidth / max(width, 1))
                                model.splitFraction = min(max(value.location.x / width, least), 1 - least)
                            }
                    )
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// The reader's top row on macOS / iPad: the pane's tabs, then `actions`. Split view underlines the
/// focused pane's bar in the accent. When the bar is narrow, the `foldable` actions move into More
/// one at a time (`ReaderBarLayout`), and `actions` gets the ones that stay.
struct ReaderBar<Actions: View>: View {
    let pane: Int
    let foldable: [ReaderBarAction]
    let keeping: Set<ReaderBarAction>
    @ViewBuilder let actions: (Set<ReaderBarAction>) -> Actions
    @Environment(AppModel.self) private var model
    @State private var dropOver = false
    @State private var width: CGFloat = 0

    init(pane: Int, foldable: [ReaderBarAction], keeping: Set<ReaderBarAction> = [],
         @ViewBuilder actions: @escaping (Set<ReaderBarAction>) -> Actions) {
        self.pane = pane
        self.foldable = foldable
        self.keeping = keeping
        self.actions = actions
    }

    init(pane: Int, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(pane: pane, foldable: []) { _ in actions() }
    }

    private static var trailingInset: CGFloat { 16 }

    var body: some View {
        HStack(spacing: 6) {
            ReaderTabStrip(pane: pane)
            actions(keptActions)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, Self.trailingInset)
        #if os(macOS)
        // The top row shared with the list header and traffic lights, hairline under it like Claude's bar.
        .frame(height: Metrics.topBarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ofHairline).frame(height: 1) }
        #else
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.desktopHeaderHeight)
        #endif
        .overlay(alignment: .bottom) {
            if model.isSplit && model.focusedPane == pane { Rectangle().fill(Color.ofAccent).frame(height: 2) }
        }
        .frostedBar()
        // A tab dragged here from the other pane moves into this one.
        .overlay { if dropOver { Color.ofAccent.opacity(0.12).allowsHitTesting(false) } }
        .onDrop(of: [.plainText], delegate: tabDropDelegate(model: model, dest: pane, over: $dropOver))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Everything until the bar has been measured.
    private var keptActions: Set<ReaderBarAction> {
        guard width > 0 else { return Set(foldable) }
        return ReaderBarLayout.keptActions(
            foldable,
            contentWidth: Double(width - leadingInset - Self.trailingInset),
            tabCount: model.panes.indices.contains(pane) ? model.panes[pane].tabs.count : 1,
            keeping: keeping
        )
    }

    /// macOS full-screen reader: the traffic lights sit over the bar's leading edge (the left pane's).
    private var leadingInset: CGFloat {
        #if os(macOS)
        model.isFocused && pane == 0 ? Metrics.trafficLightInset : 16
        #else
        16
        #endif
    }
}

/// The reader bar's tabs, shown even when there's only one: pinned tabs first as 32pt source badges,
/// a hairline, then badge and title, the active tab on the selection grey, × on the active or hovered
/// tab, then + for a new tab. Unpinned tabs share the width up to 196pt each. Tabs that don't fit go in
/// a menu before the +, the active one always staying in the row (`ReaderBarLayout.tabRow`). It draws
/// inside whatever width the bar leaves it, so it can never push the bar wider.
struct ReaderTabStrip: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var hovered: UUID?
    @State private var width: CGFloat = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        let p = model.panes.indices.contains(pane) ? model.panes[pane] : ReaderPane()
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .overlay(alignment: .leading) {
                if width > 0 { row(p) }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.leading, -6)
    }

    private func row(_ p: ReaderPane) -> some View {
        let layout = ReaderBarLayout.tabRow(width: Double(width), count: p.tabs.count, pinned: p.pinnedCount, active: p.active)
        return HStack(spacing: 2) {
            if let compact = layout.compactWidth {
                compactTab(p, width: CGFloat(compact), others: layout.hidden)
            } else {
                ForEach(Array(layout.visible.enumerated()), id: \.element) { position, index in
                    let quiet = { (i: Int) in i != p.active && p.tabs[i].id != hovered }
                    // The hairline after the pins stays put; between tabs it hides beside the active or hovered one.
                    let afterPins = position > 0 && index >= p.pinnedCount && layout.visible[position - 1] < p.pinnedCount
                    tabView(p.tabs[index], index: index, count: p.tabs.count, active: index == p.active,
                            width: layout.widths[index].map { CGFloat($0) },
                            divider: afterPins || (position > 0 && quiet(index) && quiet(layout.visible[position - 1])))
                }
                if !layout.hidden.isEmpty {
                    overflowMenu(p, tabs: layout.hidden)
                }
            }
            Button { model.focusPane(pane); model.openNewTab() } label: {
                OFIcon.plus.image
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NewTabButtonStyle())
            .help(model.shortcutHelp("New tab", .newTab))
            .accessibilityLabel("New tab")
        }
    }

    /// The tabs left out of the row, in tab order.
    private func overflowMenu(_ p: ReaderPane, tabs: [Int]) -> some View {
        Menu {
            ForEach(tabs, id: \.self) { index in
                Button(title(p.tabs[index])) { model.activateTab(pane: pane, index: index) }
            }
        } label: {
            HStack(spacing: 3) {
                Text("\(tabs.count)")
                    .font(OFFont.ui(13))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(TabMenuButtonStyle(width: CGFloat(ReaderBarLayout.overflowWidth)))
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(tabs.count) more \(tabs.count == 1 ? "tab" : "tabs")")
        .accessibilityLabel("\(tabs.count) more \(tabs.count == 1 ? "tab" : "tabs")")
    }

    /// No room for a title: the active tab's badge, which opens the others when there are any.
    @ViewBuilder private func compactTab(_ p: ReaderPane, width: CGFloat, others: [Int]) -> some View {
        let tab = p.tabs[p.active]
        if others.isEmpty {
            badge(tab, opening: tab.isNew ? tab.openingURL : nil)
                .frame(width: width, height: 28)
                .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Color.ofSelection))
                .help(title(tab))
                .accessibilityLabel(title(tab))
        } else {
            Menu {
                ForEach(others, id: \.self) { index in
                    Button(title(p.tabs[index])) { model.activateTab(pane: pane, index: index) }
                }
            } label: {
                badge(tab, opening: tab.isNew ? tab.openingURL : nil)
            }
            .buttonStyle(TabMenuButtonStyle(width: width, selected: true))
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(title(tab))
            .accessibilityLabel("\(title(tab)), \(others.count) more \(others.count == 1 ? "tab" : "tabs")")
        }
    }

    private func title(_ tab: ReaderTab) -> String {
        if tab.isNew, let opening = tab.openingURL { return URLHost.host(of: opening) }
        if tab.isNew { return "Explore" }
        if model.isStartHere(tab) { return "Start here" }
        return model.item(for: tab)?.item.title ?? "Nothing selected"
    }

    @ViewBuilder private func badge(_ tab: ReaderTab, opening: String?) -> some View {
        if opening != nil {
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        } else if tab.isNew {
            Image("ph.explore")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else if let item = model.item(for: tab) {
            SourceBadge(host: item.source.host, title: item.originName, size: 14)
        }
    }

    private func tabView(_ tab: ReaderTab, index: Int, count: Int, active: Bool, width: CGFloat?, divider: Bool) -> some View {
        let item = model.item(for: tab)
        let isHovered = hovered == tab.id
        let opening = tab.isNew ? tab.openingURL : nil
        let startHere = model.isStartHere(tab)
        let title = title(tab)
        // The window's only tab, already empty, has nothing to close, and the board stays while the library is empty.
        let closable = (count > 1 || model.isSplit || !tab.isNew) && !(startHere && model.isLibraryEmpty)
        // An inactive tab gives the ×'s place to its title until it is hovered.
        let showsClose = active || isHovered
        return Group {
            if tab.isPinned {
                badge(tab, opening: nil)
                    .frame(width: CGFloat(ReaderBarLayout.pinnedTabWidth), height: 28)
            } else {
                HStack(spacing: 7) {
                    badge(tab, opening: opening)
                    Text(title)
                        .font(OFFont.ui(13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showsClose {
                        Button { model.closeTab(pane: pane, index: index) } label: {
                            OFIcon.close.image
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TabCloseButtonStyle())
                        .opacity(closable ? 1 : 0)
                        .disabled(!closable)
                        .help(model.shortcutHelp("Close tab", .closeTab))
                        .accessibilityLabel("Close tab")
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(width: width, height: 28)
            }
        }
        .foregroundStyle(active ? Color.ofInk : Color.ofMuted)
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                .fill(active ? Color.ofSelection : isHovered ? Color.ofHover : Color.clear)
        )
        .overlay(alignment: .leading) {
            if divider {
                Rectangle().fill(Color.ofHairline).frame(width: 1, height: 14).offset(x: -2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.activateTab(pane: pane, index: index) }
        .onHover { inside in
            if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
        }
        .onDrag {
            model.tabDrag = ReaderTabDrag(pane: pane, tabID: tab.id)
            return NSItemProvider(object: ReaderTabDrag(pane: pane, tabID: tab.id).payload as NSString)
        }
        .contextMenu {
            let url = item.flatMap { URL(string: $0.item.url) }
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { model.togglePinned(pane: pane, index: index) }
                .disabled(item == nil)
            Divider()
            if model.isSplit {
                Button(pane == 0 ? "Move to Right Pane" : "Move to Left Pane") {
                    model.moveTab(pane: pane, index: index, toPane: 1 - pane)
                }
                Button("Swap Panes") { model.swapPanes() }
                Button("Combine Panes") { model.combinePanes(into: pane) }
            } else {
                Button("Split to Right") { model.moveTab(pane: pane, index: index, toPane: 1) }
            }
            Divider()
            Button("Copy Link") { if let url { ReaderPasteboard.copy(url) } }
                .disabled(url == nil)
            Button("Open in Browser") { if let url { openURL(url) } }
                .disabled(url == nil)
            Divider()
            Button("Close Tab") { model.closeTab(pane: pane, index: index) }
            Button("Close Other Tabs") { model.closeOtherTabs(pane: pane, index: index) }
                .disabled(count < 2)
            Button("Close Tabs to the Right") { model.closeTabsToRight(pane: pane, index: index) }
                .disabled(!model.canCloseTabsToRight(pane: pane, index: index))
        }
        .help(tab.isPinned ? "Pinned: \(title)" : title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.isPinned ? "Pinned: \(title)" : title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// While a tab is dragged, the targets that take it: the whole other pane in split view, or the right
/// half of a lone pane (dropping there splits). Only present during a drag, so the reader's web views
/// get their own drops and clicks the rest of the time.
private struct TabDropOverlay: View {
    let pane: Int
    @Environment(AppModel.self) private var model
    @State private var over = false

    var body: some View {
        if let drag = model.tabDrag {
            if model.isSplit {
                if drag.pane != pane {
                    zone(dest: pane, label: pane == 0 ? "Move to Left Pane" : "Move to Right Pane")
                }
            } else {
                HStack(spacing: 0) {
                    Color.clear.allowsHitTesting(false)
                    zone(dest: 1, label: "Split to Right")
                }
            }
        }
    }

    private func zone(dest: Int, label: String) -> some View {
        Color.ofAccent.opacity(over ? 0.16 : 0.07)
            .overlay {
                Text(label)
                    .font(OFFont.ui(13, .medium))
                    .foregroundStyle(.ofInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.ofSurface, in: Capsule())
                    .opacity(over ? 1 : 0.8)
            }
            .overlay { Rectangle().strokeBorder(Color.ofAccent.opacity(over ? 0.8 : 0.35), lineWidth: 2) }
            .contentShape(Rectangle())
            #if os(iOS)
            // A drag cancelled off the targets never reports back; a tap puts the reader back.
            .onTapGesture { model.tabDrag = nil }
            #endif
            .onDrop(of: [.plainText], delegate: tabDropDelegate(model: model, dest: dest, over: $over))
            .accessibilityHidden(true)
    }
}

@MainActor
private func tabDropDelegate(model: AppModel, dest: Int, over: Binding<Bool>) -> TabDropDelegate {
    TabDropDelegate(dragging: model.tabDrag, dest: dest, over: over) { drag in model.dropTab(drag, toPane: dest) }
}

/// Takes a dragged tab for one pane. The drag in progress is the model's `tabDrag` (set when it starts), so
/// validation doesn't decode the item provider; the drop applies only if the dropped text is that
/// drag's payload, so text dragged in from another app is ignored.
private struct TabDropDelegate: DropDelegate {
    let dragging: ReaderTabDrag?
    let dest: Int
    @Binding var over: Bool
    let perform: @MainActor @Sendable (ReaderTabDrag) -> Void

    private var accepts: Bool { dragging.map { $0.pane != dest } ?? false }

    func validateDrop(info: DropInfo) -> Bool {
        accepts && info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        if accepts { over = true }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: accepts ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        over = false
    }

    func performDrop(info: DropInfo) -> Bool {
        over = false
        guard accepts, let dragging,
              let provider = info.itemProviders(for: [UTType.plainText]).first
        else { return false }
        let expected = dragging.payload
        let perform = perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, text as String == expected else { return }
            Task { @MainActor in perform(dragging) }
        }
        return true
    }
}

#if os(macOS)
/// SwiftUI says nothing when a drag ends off every target, so `tabDrag` would keep the drop targets
/// up. The first mouse move, click, scroll or key after the drag clears it. Hosted by the reader.
struct TabDragReset: NSViewRepresentable {
    let active: Bool
    let reset: () -> Void

    func makeNSView(context: Context) -> ResetView { ResetView() }

    func updateNSView(_ nsView: ResetView, context: Context) {
        nsView.reset = reset
        nsView.setActive(active)
    }

    static func dismantleNSView(_ nsView: ResetView, coordinator: ()) {
        nsView.setActive(false)
    }

    final class ResetView: NSView {
        var reset: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setActive(_ active: Bool) {
            if !active {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
                ) { [weak self] event in
                    MainActor.assumeIsolated { self?.reset?() }
                    return event
                }
            }
        }
    }
}
#endif

/// The strip's +: muted, ink on the hover grey while hovered, like an inactive tab.
private struct NewTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NewTabButtonBody(configuration: configuration)
    }
}

private struct NewTabButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? Color.ofInk : Color.ofMuted)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(configuration.isPressed ? Color.ofSelection : hovering ? Color.ofHover : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}

/// A menu in the strip (the overflow count, a compact tab): looks like a tab, grey on hover like +.
private struct TabMenuButtonStyle: ButtonStyle {
    let width: CGFloat
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        TabMenuButtonBody(configuration: configuration, width: width, selected: selected)
    }
}

private struct TabMenuButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let width: CGFloat
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering || selected ? Color.ofInk : Color.ofMuted)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(selected || configuration.isPressed ? Color.ofSelection : hovering ? Color.ofHover : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The tab's ×: muted, ink on a border-grey square while hovered.
private struct TabCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TabCloseButtonBody(configuration: configuration)
    }
}

private struct TabCloseButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? Color.ofInk : Color.ofMuted)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Color.ofBorder : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}

#if os(macOS)
/// Calls `onMouseDown` for every left click inside its frame, without taking the click: a background
/// view can't see clicks that land in the WKWebView above it, so it watches the window's events.
private struct PaneMouseDownProbe: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onMouseDown = onMouseDown
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.uninstall()
    }

    final class ProbeView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                       self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.onMouseDown?()
                    }
                }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
