import Foundation
import Testing
@testable import OpenDispatchCore

@Suite("Keyboard shortcuts")
struct KeyboardShortcutsTests {
    private static let listedActions: [ShortcutAction] = ShortcutSection.all.flatMap(\.rows).compactMap {
        if case .action(let action) = $0 { return action }
        return nil
    }

    @Test func everyActionIsListedOnce() {
        #expect(Self.listedActions.count == ShortcutAction.allCases.count)
        #expect(Set(Self.listedActions) == Set(ShortcutAction.allCases))
    }

    @Test func noDefaultsClash() {
        let map = ShortcutMap()
        for action in ShortcutAction.allCases {
            let b = action.defaultBinding
            if let key = b.key {
                #expect(map.check(.key(key), for: action) == .ok, "\(action) key \(key)")
            }
            if let combo = b.combo {
                #expect(map.check(.combo(combo), for: action) == .ok, "\(action) combo \(combo.text)")
            }
        }
    }

    @Test func capsFollowTheMacOrder() {
        #expect(KeyCombo("s", option: true).caps == ["⌥", "⌘", "S"])
        #expect(KeyCombo("r", shift: true, option: true, control: true).caps == ["⌃", "⌥", "⇧", "⌘", "R"])
        #expect(KeyCombo(KeyCombo.Named.left, control: true).text == "⌃⌘←")
        #expect(KeyCombo("R").key == "r")
    }

    @Test func assigningAFreeKeyKeepsTheOtherSlot() {
        var map = ShortcutMap()
        map.assign(.key("u"), to: .refresh, replacing: .key)
        #expect(map.binding(for: .refresh) == ShortcutBinding(key: "u", combo: KeyCombo("r")))
        #expect(map.action(forKey: "u") == .refresh)
        #expect(map.action(forKey: "r") == nil)
        #expect(map.isChanged(.refresh))
        #expect(map.changedCount == 1)
    }

    @Test func aKeyOfTheOtherKindReplacesTheClickedSlot() {
        var map = ShortcutMap()
        map.assign(.combo(KeyCombo("e")), to: .toggleSaved, replacing: .key)
        #expect(map.binding(for: .toggleSaved) == ShortcutBinding(combo: KeyCombo("e")))
    }

    @Test func addingLeavesBothSlots() {
        var map = ShortcutMap()
        map.assign(.combo(KeyCombo("e")), to: .toggleSaved)
        #expect(map.binding(for: .toggleSaved) == ShortcutBinding(key: "s", combo: KeyCombo("e")))
    }

    @Test func aKeyInUseIsReportedAndCanBeTaken() {
        var map = ShortcutMap()
        #expect(map.check(.combo(KeyCombo("r")), for: .toggleSaved) == .inUse(by: .refresh))
        map.assign(.combo(KeyCombo("r")), to: .toggleSaved)
        #expect(map.action(forCombo: KeyCombo("r")) == .toggleSaved)
        #expect(map.binding(for: .refresh) == ShortcutBinding(key: "r"))
    }

    @Test func viewKeysHaveTheirOwnSpace() {
        let map = ShortcutMap()
        // s is both Save and g then s.
        #expect(map.action(forKey: "s") == .toggleSaved)
        #expect(map.action(forChordKey: "s") == .viewSaved)
        #expect(map.check(.key("a"), for: .toggleSaved) == .ok)
        #expect(map.check(.key("a"), for: .viewSaved) == .inUse(by: .viewAll))
        #expect(map.check(.key("g"), for: .viewSaved) == .ok)
    }

    @Test func refusals() {
        let map = ShortcutMap()
        #expect(map.check(.key("g"), for: .toggleSaved) == .chordPrefix)
        #expect(map.check(.combo(KeyCombo("q")), for: .refresh) == .reserved)
        #expect(map.check(.combo(KeyCombo("v")), for: .refresh) == .reserved)
        // Its own key isn't a clash.
        #expect(map.check(.combo(KeyCombo("r")), for: .refresh) == .ok)
    }

    @Test func removingAndResetting() {
        var map = ShortcutMap()
        map.remove(.combo, from: .refresh)
        #expect(map.action(forCombo: KeyCombo("r")) == nil)
        map.assign(.key("x"), to: .pinTab)
        #expect(map.changedCount == 2)
        map.reset(.refresh)
        #expect(map.action(forCombo: KeyCombo("r")) == .refresh)
        map.resetAll()
        #expect(map == ShortcutMap())
    }

    @Test func puttingADefaultBackStoresNothing() throws {
        var map = ShortcutMap()
        map.assign(.key("u"), to: .refresh, replacing: .key)
        map.assign(.key("r"), to: .refresh, replacing: .key)
        #expect(map == ShortcutMap())
    }

    @Test func survivesEncodingWithRemovedShortcuts() throws {
        var map = ShortcutMap()
        map.remove(.key, from: .toggleSaved)
        map.assign(.combo(KeyCombo(KeyCombo.Named.up, shift: true)), to: .pinTab)
        let decoded = try JSONDecoder().decode(ShortcutMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        #expect(decoded.binding(for: .toggleSaved).key == nil)
        #expect(decoded.action(forKey: "s") == nil)
    }

    @Test func storedActionsThisBuildDoesNotKnowAreIgnored() throws {
        let json = #"{"changes":{"fromTheFuture":{"key":"x"},"refresh":{"key":"u"}}}"#
        let map = try JSONDecoder().decode(ShortcutMap.self, from: Data(json.utf8))
        #expect(map.binding(for: .refresh).key == "u")
        #expect(map.action(forKey: "x") == nil)
    }
}
