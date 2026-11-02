import OpenDispatchCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shortcuts pane (Mac and iPad): every action with its keys. Click a key, or Add shortcut or +, then press the new
/// keys: a key with ⌘, ⌥ or ⌃ goes to the menus, a plain one to the window's single-key handler
/// (Views/Feed/KeyboardShortcuts.swift). Changes live in `model.settings.shortcuts`.
struct SettingsShortcutsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var recording: ShortcutRecording?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeading(title: "Shortcuts", hint: "Click a shortcut, then press the new keys. Single keys are ignored while you're typing.")
            tools
                .padding(.bottom, 16)
            ForEach(sections, id: \.title) { section in
                SettingsSection(title: section.title) {
                    ForEach(section.rows, id: \.self) { row in
                        ShortcutEditRow(row: row, recording: $recording)
                    }
                }
            }
            if sections.isEmpty {
                Text("No shortcuts match")
                    .font(OFFont.ui(13))
                    .foregroundStyle(.ofMuted)
                    .padding(.horizontal, 14)
            }
        }
        .background { ShortcutKeyCaptureHost(recording: $recording) }
    }

    private var tools: some View {
        HStack(spacing: 8) {
            TextField("Search shortcuts", text: $query)
                .textFieldStyle(.plain)
                .font(OFFont.ui(13))
                .foregroundStyle(.ofInk)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.ofCode))
            let changed = model.settings.shortcuts.changedCount
            Button(changed > 0 ? "Reset All (\(changed))" : "Reset All") {
                recording = nil
                model.settings.shortcuts.resetAll()
            }
            .buttonStyle(SettingsPaneButtonStyle())
            .disabled(changed == 0)
        }
    }

    private var sections: [(title: String, rows: [ShortcutRow])] {
        let map = model.settings.shortcuts
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ShortcutSection.all.compactMap { section in
            let rows = q.isEmpty ? section.rows : section.rows.filter { $0.matches(q, in: map) }
            return rows.isEmpty ? nil : (section.title, rows)
        }
    }
}

private extension ShortcutRow {
    func matches(_ query: String, in map: ShortcutMap) -> Bool {
        switch self {
        case .fixed(let label, let keys, _):
            return (label + " " + keys.joined(separator: " ")).lowercased().contains(query)
        case .action(let action):
            let b = map.binding(for: action)
            let text = [action.label, b.key ?? "", b.combo?.text ?? ""] + action.fixedKeys
            return text.joined(separator: " ").lowercased().contains(query)
        }
    }
}

/// The press being waited for, or the question or complaint about the last one.
struct ShortcutRecording: Equatable {
    let action: ShortcutAction
    /// The slot that was clicked; nil when adding.
    let slot: ShortcutSlot?
    /// The press needs a yes, because another action has that key.
    var conflict: Conflict?
    var complaint: String?

    struct Conflict: Equatable {
        let candidate: ShortcutCandidate
        let other: ShortcutAction
    }
}

private struct ShortcutEditRow: View {
    let row: ShortcutRow
    @Binding var recording: ShortcutRecording?
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        switch row {
        case .fixed(let label, let keys, let separator):
            SettingsRow(label: label) { ShortcutCaps(keys: keys, separator: separator, fixed: true) }
        case .action(let action):
            editor(action)
        }
    }

    private func editor(_ action: ShortcutAction) -> some View {
        let active = recording?.action == action ? recording : nil
        return VStack(alignment: .trailing, spacing: 0) {
            SettingsRow(label: action.label) { keys(action, active: active) }
            if let active { hint(action, active) }
        }
        .onHover { hovering = $0 }
    }

    private func keys(_ action: ShortcutAction, active: ShortcutRecording?) -> some View {
        let b = model.settings.shortcuts.binding(for: action)
        let adding = active != nil && active?.slot == nil
        let full = b.key != nil && b.combo != nil
        return HStack(spacing: 4) {
            // Before the caps, so the caps line up down the card and nothing moves when + appears on hover.
            if model.settings.shortcuts.isChanged(action) {
                Button {
                    recording = nil
                    model.settings.shortcuts.reset(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.ofMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset to default")
                .accessibilityLabel("Reset \(action.label) to default")
            }
            let parts = parts(action, b, active: active)
            if !adding, !parts.isEmpty, !full {
                Button { record(action, nil) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.ofMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsAddButton ? 1 : 0)
                .accessibilityLabel("Add another shortcut for \(action.label)")
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { ShortcutCapSeparator(text: "or") }
                view(for: part, action)
            }
            if !adding, parts.isEmpty {
                Button("Add shortcut") { record(action, nil) }
                    .buttonStyle(.plain)
                    .font(OFFont.ui(12))
                    .foregroundStyle(.ofMuted)
            }
        }
    }

    /// There is no hover to wait for on a touch screen.
    private var showsAddButton: Bool {
        #if os(macOS)
        hovering
        #else
        true
        #endif
    }

    private enum Part: Hashable {
        case slot(ShortcutSlot)
        case fixed(String)
        case recording
    }

    private func parts(_ action: ShortcutAction, _ b: ShortcutBinding, active: ShortcutRecording?) -> [Part] {
        var out: [Part] = []
        if b.key != nil { out.append(active?.slot == .key ? .recording : .slot(.key)) }
        out += action.fixedKeys.map(Part.fixed)
        if b.combo != nil { out.append(active?.slot == .combo ? .recording : .slot(.combo)) }
        if active != nil, active?.slot == nil { out.append(.recording) }
        return out
    }

    @ViewBuilder private func view(for part: Part, _ action: ShortcutAction) -> some View {
        switch part {
        case .fixed(let key):
            SettingsKeyCap(key: key)
                .opacity(0.7)
        case .recording:
            Text("Press keys…")
                .font(OFFont.ui(12))
                .foregroundStyle(.ofAccent)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.ofAccent, lineWidth: 1.5))
        case .slot(let slot):
            ShortcutSlotButton(caps: ShortcutCapsContent(action: action, slot: slot, map: model.settings.shortcuts),
                               label: action.label) {
                record(action, slot)
            }
        }
    }

    @ViewBuilder private func hint(_ action: ShortcutAction, _ active: ShortcutRecording) -> some View {
        HStack(spacing: 8) {
            if let conflict = active.conflict {
                Text("\(conflict.candidate.text(for: action)) is already \(conflict.other.label).")
                    .foregroundStyle(.ofMuted)
                Button("Use It Here") {
                    model.settings.shortcuts.assign(conflict.candidate, to: action, replacing: active.slot)
                    recording = nil
                }
                .buttonStyle(SettingsSmallButtonStyle())
                Button("Cancel") { recording = nil }
                    .buttonStyle(SettingsSmallButtonStyle(quiet: true))
            } else if let complaint = active.complaint {
                Text(complaint)
                    .foregroundStyle(.ofDanger)
            } else {
                Text(active.slot == nil ? "Esc cancels" : "Esc cancels, Delete removes this shortcut")
                    .foregroundStyle(.ofMuted)
            }
        }
        .font(OFFont.ui(12))
        .multilineTextAlignment(.trailing)
        .padding(.bottom, 9)
    }

    private func record(_ action: ShortcutAction, _ slot: ShortcutSlot?) {
        recording = ShortcutRecording(action: action, slot: slot)
    }
}

extension ShortcutCandidate {
    fileprivate func text(for action: ShortcutAction) -> String {
        switch self {
        case .combo(let combo): combo.text
        case .key(let key): action.isChord ? "\(ShortcutMap.chordPrefix) then \(key)" : key
        }
    }
}

private struct ShortcutSlotButton: View {
    let caps: ShortcutCapsContent
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ShortcutCaps(keys: caps.keys, separator: caps.separator)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.ofNavSelection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-3)
        .onHover { hovering = $0 }
        .accessibilityLabel("Change \(label), now \(caps.keys.joined(separator: " "))")
    }
}

/// The caps of one slot of an action.
struct ShortcutCapsContent {
    let keys: [String]
    let separator: String?

    init(action: ShortcutAction, slot: ShortcutSlot, map: ShortcutMap) {
        let b = map.binding(for: action)
        switch slot {
        case .combo:
            keys = b.combo?.caps ?? []
            separator = nil
        case .key:
            let key = b.key ?? ""
            keys = action.isChord ? [ShortcutMap.chordPrefix, key] : [key]
            separator = action.isChord ? "then" : nil
        }
    }
}

/// A row of key caps with an optional word between them.
struct ShortcutCaps: View {
    let keys: [String]
    var separator: String?
    var fixed = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                if i > 0, let separator { ShortcutCapSeparator(text: separator) }
                SettingsKeyCap(key: key)
            }
        }
        .fixedSize()
        .opacity(fixed ? 0.7 : 1)
    }
}

struct ShortcutCapSeparator: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OFFont.ui(11))
            .foregroundStyle(.ofFaint)
    }
}

/// Takes presses while something is recording, ahead of the menus and of the close button's Esc.
private struct ShortcutKeyCaptureHost: View {
    @Binding var recording: ShortcutRecording?
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            #if os(macOS)
            Color.clear.modifier(MacCapture(active: recording != nil, press: handle, clickAway: {
                if recording?.conflict == nil { recording = nil }
            }))
            #else
            if recording != nil {
                ShortcutKeyCaptureView(press: handle)
                    .frame(width: 0, height: 0)
            }
            #endif
        }
    }

    private func handle(_ press: RecordedPress) {
        guard var current = recording else { return }
        if current.conflict != nil {
            // Only the buttons or Esc answer the question.
            if press == .cancel { recording = nil }
            return
        }
        current.complaint = nil
        switch press {
        case .cancel:
            recording = nil
        case .remove:
            if let slot = current.slot { model.settings.shortcuts.remove(slot, from: current.action) }
            recording = nil
        case .unusable:
            current.complaint = "Space, the arrow keys, Return and Tab keep their jobs. Pick another key."
            recording = current
        case .candidate(let candidate):
            switch model.settings.shortcuts.check(candidate, for: current.action) {
            case .ok:
                model.settings.shortcuts.assign(candidate, to: current.action, replacing: current.slot)
                recording = nil
            case .reserved:
                current.complaint = "\(candidate.text(for: current.action)) belongs to macOS or text editing. Pick another."
                recording = current
            case .chordPrefix:
                current.complaint = "\(ShortcutMap.chordPrefix) starts the view shortcuts. Pick another key."
                recording = current
            case .inUse(let other):
                current.conflict = .init(candidate: candidate, other: other)
                recording = current
            }
        }
    }
}

#if os(macOS)
private struct MacCapture: ViewModifier {
    let active: Bool
    let press: (RecordedPress) -> Void
    let clickAway: () -> Void
    @State private var monitors = ShortcutKeyMonitors()

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, on in
                if on { monitors.start() } else { monitors.stop() }
            }
            .onChange(of: active, initial: true) {
                monitors.press = press
                monitors.clickAway = clickAway
            }
            .onDisappear { monitors.stop() }
    }
}

/// Local monitors see an event before the menus and the responder chain, and returning nil ends it there.
@MainActor
private final class ShortcutKeyMonitors {
    var press: ((RecordedPress) -> Void)?
    var clickAway: (() -> Void)?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.press?(RecordedPress(event: event)) }
            return nil
        }
        // Lets the click through: a click on another shortcut ends this recording and starts that one.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.clickAway?() }
            return event
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }
}

extension KeyCombo {
    /// The combo an event is, nil without ⌘, ⌥ or ⌃. The key is read with no modifiers applied, so ⌥S is
    /// S and ⇧] is ], on whatever the keyboard layout is.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        let key: String
        switch event.keyCode {
        case 123: key = Named.left
        case 124: key = Named.right
        case 125: key = Named.down
        case 126: key = Named.up
        case 115: key = Named.home
        case 119: key = Named.end
        case 116: key = Named.pageUp
        case 121: key = Named.pageDown
        case 36, 76, 48, 49, 51, 53, 117: return nil  // Return, Tab, Space, Delete, Esc
        default:
            guard let c = event.characters(byApplyingModifiers: []), c.count == 1, c.isPrintableKey else { return nil }
            key = c
        }
        self.init(key, command: flags.contains(.command), shift: flags.contains(.shift),
                  option: flags.contains(.option), control: flags.contains(.control))
    }
}

private extension RecordedPress {
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.isDisjoint(with: [.command, .option, .control])
        if event.keyCode == 53 {
            self = .cancel
        } else if plain, event.keyCode == 51 || event.keyCode == 117 {
            self = .remove
        } else if !plain {
            self = KeyCombo(event: event).map { .candidate(.combo($0)) } ?? .unusable
        } else if ![36, 76, 48, 49, 123, 124, 125, 126].contains(event.keyCode),
                  let c = event.characters, c.count == 1, c.isPrintableKey {
            self = .candidate(.key(c))
        } else {
            self = .unusable
        }
    }
}
#else
/// A first responder that hears a hardware keyboard's presses, ⌘ ones included.
private struct ShortcutKeyCaptureView: UIViewRepresentable {
    let press: (RecordedPress) -> Void

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.press = press
        return view
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.press = press
    }

    final class CaptureView: UIView {
        var press: ((RecordedPress) -> Void)?
        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { becomeFirstResponder() }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let key = presses.first?.key else { return super.pressesBegan(presses, with: event) }
            if key.keyCode.isModifier { return }
            press?(RecordedPress(key: key))
        }
    }
}

private extension UIKeyboardHIDUsage {
    var isModifier: Bool {
        switch self {
        case .keyboardLeftGUI, .keyboardRightGUI, .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftControl,
             .keyboardRightControl, .keyboardLeftShift, .keyboardRightShift, .keyboardCapsLock: true
        default: false
        }
    }
}

private extension RecordedPress {
    init(key: UIKey) {
        let plain = key.modifierFlags.isDisjoint(with: [.command, .alternate, .control])
        switch key.keyCode {
        case .keyboardEscape:
            self = .cancel
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
            self = plain ? .remove : .unusable
        case .keyboardReturnOrEnter, .keypadEnter, .keyboardTab, .keyboardSpacebar:
            self = .unusable
        default:
            if plain {
                if [.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow].contains(key.keyCode) {
                    self = .unusable
                } else if key.characters.count == 1, let c = Optional(key.characters), c.isPrintableKey {
                    self = .candidate(.key(c))
                } else {
                    self = .unusable
                }
            } else {
                self = KeyCombo(key: key).map { .candidate(.combo($0)) } ?? .unusable
            }
        }
    }
}

private extension KeyCombo {
    init?(key: UIKey) {
        let name: String
        switch key.keyCode {
        case .keyboardLeftArrow: name = Named.left
        case .keyboardRightArrow: name = Named.right
        case .keyboardUpArrow: name = Named.up
        case .keyboardDownArrow: name = Named.down
        case .keyboardHome: name = Named.home
        case .keyboardEnd: name = Named.end
        case .keyboardPageUp: name = Named.pageUp
        case .keyboardPageDown: name = Named.pageDown
        default:
            let c = key.charactersIgnoringModifiers
            guard c.count == 1, c.isPrintableKey else { return nil }
            name = c
        }
        self.init(name, command: key.modifierFlags.contains(.command), shift: key.modifierFlags.contains(.shift),
                  option: key.modifierFlags.contains(.alternate), control: key.modifierFlags.contains(.control))
    }
}
#endif

private extension String {
    /// One visible character: not a control character or one of the function keys' private-use codes.
    var isPrintableKey: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
        return !(0xF700...0xF8FF).contains(scalar.value)
    }
}

#Preview {
    ScrollView {
        SettingsShortcutsPane().padding()
    }
    .environment(AppModel.preview())
    .frame(width: 640, height: 600)
}
