import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension AppModel {
    /// What SwiftUI needs for an action's ⌘ shortcut; nil when it has none.
    func keyboardShortcut(_ action: ShortcutAction) -> KeyboardShortcut? {
        settings.shortcuts.binding(for: action).combo?.keyboardShortcut
    }

    /// A tooltip with the action's keys in it: "New tab (⌘T)", or just "New tab" with none.
    func shortcutHelp(_ text: String, _ action: ShortcutAction) -> String {
        guard let combo = settings.shortcuts.binding(for: action).combo else { return text }
        return "\(text) (\(combo.text))"
    }

    #if os(macOS)
    /// ⌘W: close the Settings overlay when it's up; else close the reader's active tab when the reader
    /// window is key and has tabs, else close the key window.
    func closeTabOrWindow() {
        if let key = NSApp.keyWindow, key === ReaderWindow.current {
            if isSettingsPresented {
                isSettingsPresented = false
                return
            }
            if closeActiveTab() { return }
        }
        NSApp.keyWindow?.performClose(nil)
    }
    #endif
}

extension KeyCombo {
    var keyboardShortcut: KeyboardShortcut {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(keyEquivalent, modifiers: modifiers)
    }

    private var keyEquivalent: KeyEquivalent {
        switch key {
        case Named.left: .leftArrow
        case Named.right: .rightArrow
        case Named.up: .upArrow
        case Named.down: .downArrow
        case Named.home: .home
        case Named.end: .end
        case Named.pageUp: .pageUp
        case Named.pageDown: .pageDown
        default: KeyEquivalent(key.first ?? " ")
        }
    }
}

/// Runs an action from a key: a single key anywhere, a ⌘ shortcut where no menu item carries it. The checks
/// are the ones that gray out the matching menu items.
@MainActor
struct ShortcutRunner {
    let model: AppModel
    let speech: ReaderSpeech
    let openURL: (URL) -> Void
    let focusSearch: () -> Void

    func run(_ action: ShortcutAction) {
        switch action {
        case .nextItem:
            model.moveSelection(by: 1)
        case .previousItem:
            model.moveSelection(by: -1)
        case .openOriginal:
            guard let item = model.selectedItem, let url = URL(string: item.item.url) else { return }
            if model.opensOnYouTube(item) { model.watchOnYouTube(item) } else { openURL(url) }
        case .toggleSaved:
            Task { await model.toggleSavedOnSelection() }
        case .toggleRead:
            model.toggleReadOnSelection()
        case .markAllRead:
            if !(model.showsHighlights || model.showsHistory || model.items.isEmpty) { model.markAllRead() }
        case .reloadArticle:
            if let item = model.selectedItem, item.source.kind != .youtube { model.reloadArticle(item) }
        case .copyMarkdown:
            if let item = model.selectedItem { model.copyMarkdown(item: item) }
        case .listen:
            if let item = model.selectedItem, item.source.kind != .youtube { speech.requestToggle() }
        case .popOutVideo:
            #if os(macOS)
            ReaderFloatingPlayer.shared.toggle()
            #else
            ReaderYouTubeController.current?.togglePictureInPicture()
            #endif
        case .viewAll: model.navigate(view: .all)
        case .viewArticles: model.navigate(view: .articles)
        case .viewPosts: model.navigate(view: .posts)
        case .viewVideo: model.navigate(view: .video)
        case .viewPodcasts: model.navigate(view: .podcasts)
        case .viewSaved: model.navigate(view: .saved)
        case .viewHighlights: model.showHighlights()
        case .viewHistory: model.showHistory()
        case .nextTab:
            if model.panes[model.focusedPane].tabs.count >= 2 { model.selectTab(offset: 1) }
        case .previousTab:
            if model.panes[model.focusedPane].tabs.count >= 2 { model.selectTab(offset: -1) }
        case .newTab:
            model.openNewTab()
        case .openLink:
            model.openLocation()
        case .closeTab:
            #if os(macOS)
            model.closeTabOrWindow()
            #else
            _ = model.closeActiveTab()
            #endif
        case .reopenTab:
            if !model.closedItems.isEmpty { model.reopenClosedTab() }
        case .pinTab:
            if model.selectedItem != nil {
                model.togglePinned(pane: model.focusedPane, index: model.panes[model.focusedPane].active)
            }
        case .back:
            if model.canGoBack { model.goBack() }
        case .forward:
            if model.canGoForward { model.goForward() }
        case .split:
            if model.selectedItem != nil || model.isSplit { model.toggleSplit() }
        case .moveTabLeft:
            if model.canMoveTabLeft { model.moveActiveTab(toRight: false) }
        case .moveTabRight:
            if model.canMoveTabRight { model.moveActiveTab(toRight: true) }
        case .search:
            focusSearch()
        case .filterSources:
            model.openSourceFilter()
        case .refresh:
            if !model.isRefreshing { Task { await model.refresh(force: true) } }
        case .addSource:
            model.isAddSourcePresented = true
        case .sidebar:
            model.toggleSidebar()
        case .fullScreen:
            model.toggleFocusMode()
        case .settings:
            model.showSettings(model.settingsTab)
        case .showShortcuts:
            model.isShortcutsPresented.toggle()
        }
    }
}
