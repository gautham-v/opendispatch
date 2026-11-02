import OpenDispatchCore
import SwiftUI

/// Keyboard shortcuts overlay (shortcuts-dialog.tsx), opened with "?" or ⌘/ unless those were changed. It shows
/// the keys in use; Edit opens Settings → Shortcuts. Esc, the show-shortcuts key or the close button dismisses it.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Keyboard shortcuts")
                    .font(OFFont.ui(17, .semibold))
                    .tracking(-0.17)
                    .foregroundStyle(.ofInk)
                    .padding(.trailing, 90)
                ForEach(ShortcutSection.all, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title)
                            .font(OFFont.ui(11, .semibold))
                            .tracking(0.11)
                            .foregroundStyle(.ofFaint)
                            .padding(.bottom, 4)
                        ForEach(section.rows, id: \.self) { row in
                            if let entry = entry(row) {
                                rowView(label: entry.label, parts: entry.parts)
                            }
                        }
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 420, maxWidth: 420)
        #if os(macOS)
        .frame(minHeight: 520)
        #endif
        .background(Color.ofSurface)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                Button("Edit") {
                    dismiss()
                    model.showSettings(.shortcuts)
                }
                .buttonStyle(SettingsSmallButtonStyle(quiet: true))
                Button { dismiss() } label: {
                    OFIcon.close.image
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.ofMuted)
                        .frame(width: Metrics.desktopIconButton, height: Metrics.desktopIconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close keyboard shortcuts")
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard press.characters == model.settings.shortcuts.binding(for: .showShortcuts).key else { return .ignored }
            dismiss()
            return .handled
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private struct Part: Hashable {
        let keys: [String]
        var separator: String?
    }

    /// A line's label and its alternatives; nil for an action with no keys.
    private func entry(_ row: ShortcutRow) -> (label: String, parts: [Part])? {
        switch row {
        case .fixed(let label, let keys, let separator):
            if separator == "or" { return (label, keys.map { Part(keys: [$0]) }) }
            return (label, [Part(keys: keys, separator: separator)])
        case .action(let action):
            let map = model.settings.shortcuts
            let b = map.binding(for: action)
            var parts: [Part] = []
            if b.key != nil {
                let caps = ShortcutCapsContent(action: action, slot: .key, map: map)
                parts.append(Part(keys: caps.keys, separator: caps.separator))
            }
            parts += action.fixedKeys.map { Part(keys: [$0]) }
            if let combo = b.combo { parts.append(Part(keys: combo.caps)) }
            return parts.isEmpty ? nil : (action.label, parts)
        }
    }

    private func rowView(label: String, parts: [Part]) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(OFFont.ui(14))
                .foregroundStyle(.ofInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    if i > 0 { ShortcutCapSeparator(text: "or") }
                    ShortcutCaps(keys: part.keys, separator: part.separator)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { SettingsHairline() }
        .accessibilityElement(children: .combine)
    }
}

/// `<kbd>`: 12pt key name on code background with a hairline border.
struct SettingsKeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(OFFont.ui(12))
            .foregroundStyle(.ofInk)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.ofCode))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.ofHairline))
    }
}

#Preview {
    ShortcutsView()
        .environment(AppModel.preview())
}
