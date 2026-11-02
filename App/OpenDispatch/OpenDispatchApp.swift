import OpenDispatchCore
import SwiftUI
import UserNotifications
#if os(macOS)
import Sparkle
#endif

@main
struct OpenDispatchApp: App {
    /// The single app model (owns AppDatabase via OpenDispatchServices). Injected with `.environment(model)`.
    @State private var model: AppModel
    /// Highlights and notes (HighlightStore), beside the model rather than in it.
    @State private var highlights: HighlightStore
    /// Read aloud (the reader's Listen): one session at a time, app-wide.
    @State private var speech = ReaderSpeech()
    #if os(macOS)
    /// Sparkle: checks the appcast on its own schedule, installs updates on quit unless turned off in
    /// Settings → About, and backs "Check for Updates…".
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    init() {
        let model = AppModel.live()
        _model = State(initialValue: model)
        PostNotifications.delegate.model = model
        UNUserNotificationCenter.current().delegate = PostNotifications.delegate
        _highlights = State(initialValue: HighlightStore(model: model))
        #if os(macOS)
        // Overlay scrollers for this app even with a mouse attached (System Settings' "Automatically"
        // then means always-visible scroll bars). Otherwise SwiftUI reserves a 15pt scroll-bar gutter on
        // the right of every scroll view, so rows stop short of the right edge. overlayScrollers() then
        // shows each scroller only while the pointer is over its pane.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        #else
        OFFont.registerBundledFonts()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(speech)
                .environment(highlights)
                #if os(macOS)
                .environment(\.updater, updater.updater)
                #endif
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        // A link from outside (opendispatch://…) goes to the window that's open instead of opening another.
        .handlesExternalEvents(matching: ["*"])
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { OpenDispatchCommands(model: model, speech: speech, updater: updater.updater) }
        #endif
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [services = model.services] in
            await BackgroundRefresh.run(services)
        }
        #endif
    }
}

extension FeedView {
    var shortcutAction: ShortcutAction {
        switch self {
        case .all: .viewAll
        case .saved: .viewSaved
        case .articles: .viewArticles
        case .posts: .viewPosts
        case .video: .viewVideo
        case .podcasts: .viewPodcasts
        }
    }
}

#if os(macOS)
/// Menu bar commands, with the ⌘ shortcuts from `model.settings.shortcuts` (Settings → Shortcuts). Single keys are
/// handled in the window by Views/Feed/KeyboardShortcuts.swift.
struct OpenDispatchCommands: Commands {
    let model: AppModel
    let speech: ReaderSpeech
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }
        // Settings is an overlay in the main window (SettingsOverlay), so there's no Settings scene.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings(model.settingsTab) }
                .keyboardShortcut(model.keyboardShortcut(.settings))
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.openNewTab() }
                .keyboardShortcut(model.keyboardShortcut(.newTab))
            Button("Open Link…") { model.openLocation() }
                .keyboardShortcut(model.keyboardShortcut(.openLink))
            Button("Add Source…") { model.isAddSourcePresented = true }
                .keyboardShortcut(model.keyboardShortcut(.addSource))
        }
        // Copies the focused reader's item (or its transcript) as Markdown for pasting into an AI.
        CommandGroup(after: .pasteboard) {
            Button("Copy as Markdown") { if let item = model.selectedItem { model.copyMarkdown(item: item) } }
                .keyboardShortcut(model.keyboardShortcut(.copyMarkdown))
                .disabled(model.selectedItem == nil)
        }
        CommandMenu("Feed") {
            Button("Refresh") { Task { await model.refresh(force: true) } }
                .keyboardShortcut(model.keyboardShortcut(.refresh))
                .disabled(model.isRefreshing)
            Button("Search") { model.openSearch() }
                .keyboardShortcut(model.keyboardShortcut(.search))
            Button("Filter Sources") { model.openSourceFilter() }
                .keyboardShortcut(model.keyboardShortcut(.filterSources))
            Button("New Topic…") { model.beginNewTopic() }
            Divider()
            // Same order as the sidebar.
            ForEach(SidebarViewItem.ordered) { item in
                switch item {
                case .explore: Button("Explore") { model.openLocation() }
                case .view(let view):
                    Button(view.title) { model.navigate(view: view) }
                        .keyboardShortcut(model.keyboardShortcut(view.shortcutAction))
                case .highlights:
                    Button("Highlights") { model.showHighlights() }
                        .keyboardShortcut(model.keyboardShortcut(.viewHighlights))
                case .history:
                    Button("History") { model.showHistory() }
                        .keyboardShortcut(model.keyboardShortcut(.viewHistory))
                }
            }
            Divider()
            Button(model.selectedItem.map { HistoryStore.markLabel(kind: $0.source.kind, isRead: model.history.isRead($0)) } ?? "Mark as Read") {
                model.toggleReadOnSelection()
            }
            .keyboardShortcut(model.keyboardShortcut(.toggleRead))
            .disabled(model.selectedItem == nil)
            Button("Mark All as Read") { model.markAllRead() }
                .keyboardShortcut(model.keyboardShortcut(.markAllRead))
                .disabled(model.showsHighlights || model.showsHistory || model.items.isEmpty)
            Toggle("Hide Read Items", isOn: Binding(get: { model.settings.hideReadItems }, set: { _ in model.toggleHideReadItems() }))
        }
        CommandGroup(replacing: .saveItem) {
            Button(model.hasReaderTabs ? "Close Tab" : "Close Window") { model.closeTabOrWindow() }
                .keyboardShortcut(model.keyboardShortcut(.closeTab))
            Button("Reopen Closed Tab") { model.reopenClosedTab() }
                .keyboardShortcut(model.keyboardShortcut(.reopenTab))
                .disabled(model.closedItems.isEmpty)
        }
        CommandGroup(after: .sidebar) {
            Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
                .keyboardShortcut(model.keyboardShortcut(.sidebar))
            Button(model.focusMode ? "Exit Full-Screen Reader" : "Full-Screen Reader") { model.toggleFocusMode() }
                .keyboardShortcut(model.keyboardShortcut(.fullScreen))
            Divider()
            Button(model.isSplit ? "Close Split View" : "Split View") { model.toggleSplit() }
                .keyboardShortcut(model.keyboardShortcut(.split))
                .disabled(model.selectedItem == nil && !model.isSplit)
            Button("Move Tab to Left Pane") { model.moveActiveTab(toRight: false) }
                .keyboardShortcut(model.keyboardShortcut(.moveTabLeft))
                .disabled(!model.canMoveTabLeft)
            Button(model.isSplit ? "Move Tab to Right Pane" : "Split to Right") { model.moveActiveTab(toRight: true) }
                .keyboardShortcut(model.keyboardShortcut(.moveTabRight))
                .disabled(!model.canMoveTabRight)
            Button("Back") { model.goBack() }
                .keyboardShortcut(model.keyboardShortcut(.back))
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut(model.keyboardShortcut(.forward))
                .disabled(!model.canGoForward)
            Button("Show Next Tab") { model.selectTab(offset: 1) }
                .keyboardShortcut(model.keyboardShortcut(.nextTab))
                .disabled(model.panes[model.focusedPane].tabs.count < 2)
            Button("Show Previous Tab") { model.selectTab(offset: -1) }
                .keyboardShortcut(model.keyboardShortcut(.previousTab))
                .disabled(model.panes[model.focusedPane].tabs.count < 2)
            Button(model.panes[model.focusedPane].activeTab.isPinned ? "Unpin Tab" : "Pin Tab") {
                model.togglePinned(pane: model.focusedPane, index: model.panes[model.focusedPane].active)
            }
            .keyboardShortcut(model.keyboardShortcut(.pinTab))
            .disabled(model.selectedItem == nil)
            Divider()
            Button(listenTitle) { speech.requestToggle() }
                .keyboardShortcut(model.keyboardShortcut(.listen))
                .disabled(model.selectedItem == nil || model.selectedItem?.source.kind == .youtube)
            Divider()
            // Re-extract the focused reader's article (⌘R is Feed › Refresh).
            Button("Reload Article") { if let item = model.selectedItem { model.reloadArticle(item) } }
                .keyboardShortcut(model.keyboardShortcut(.reloadArticle))
                .disabled(model.selectedItem == nil || model.selectedItem?.source.kind == .youtube)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.isShortcutsPresented = true }
                .keyboardShortcut(model.keyboardShortcut(.showShortcuts))
        }
    }

    private var listenTitle: String {
        switch speech.state {
        case .idle: "Listen"
        case .playing: "Pause Listening"
        case .paused: "Resume Listening"
        }
    }
}
#endif
