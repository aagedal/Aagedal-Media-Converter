// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI

/// The app's keyboard shortcuts and saved keyboard presets. Key monitors look up the
/// command for each key press here, so changes apply at once.
@MainActor
final class ShortcutRegistry: ObservableObject {
    static let shared = ShortcutRegistry()

    @Published private(set) var keymap: Keymap {
        didSet { lookup = Self.lookup(for: keymap) }
    }
    /// Saved presets, not counting the built-in default.
    @Published private(set) var presets: [KeyboardPreset]
    /// The preset the keymap was last switched to or saved as; edits since then mark it modified.
    @Published private(set) var activePresetName: String
    private var lookup: [ShortcutContext: [ShortcutBinding: ShortcutCommand]]
    private let defaults: UserDefaults
    static let storageKey = "keyboardShortcuts.v2"
    static let presetsKey = "keyboardShortcutPresets.v1"
    static let activePresetKey = "keyboardShortcutPresets.active"
    /// Main-window shortcuts saved by earlier versions, by physical key code.
    static let legacyStorageKey = "mainWindowKeyboardShortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let keymap: Keymap
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: [ShortcutBinding]].self, from: data) {
            keymap = Keymap.restoring(saved).keymap
        } else if let legacy = Self.legacyChoices(defaults) {
            keymap = Keymap.restoring(legacy).keymap
        } else {
            keymap = .defaults
        }
        self.keymap = keymap
        lookup = Self.lookup(for: keymap)
        let saved = defaults.data(forKey: Self.presetsKey).flatMap { try? JSONDecoder().decode([KeyboardPreset].self, from: $0) } ?? []
        let active = defaults.string(forKey: Self.activePresetKey) ?? KeyboardPreset.builtInName
        presets = saved
        activePresetName = saved.contains { $0.name == active } ? active : KeyboardPreset.builtInName
        if defaults.object(forKey: Self.legacyStorageKey) != nil { persist() }
    }

    private static func lookup(for keymap: Keymap) -> [ShortcutContext: [ShortcutBinding: ShortcutCommand]] {
        Dictionary(uniqueKeysWithValues: ShortcutContext.allCases.map { ($0, keymap.commandsByBinding(in: $0)) })
    }

    func bindings(for command: ShortcutCommand) -> [ShortcutBinding] { keymap.bindings(for: command) }
    func command(for binding: ShortcutBinding, in context: ShortcutContext) -> ShortcutCommand? { lookup[context]?[binding] }
    /// The shortcut a menu item shows: the first one menus can deliver without taking keys from text.
    func menuShortcut(for command: ShortcutCommand) -> KeyboardShortcut? {
        keymap.bindings(for: command).first { $0.isMenuKeyEquivalent }?.keyboardShortcut
    }

    func set(_ binding: ShortcutBinding, for command: ShortcutCommand, slot: Int = 0) -> String? {
        if let error = keymap.validationError(binding, for: command, slot: slot) { return error }
        keymap.set(binding, for: command, slot: slot)
        persist()
        return nil
    }
    /// Assigns a shortcut that another command holds, removing it from that command.
    func reassign(_ binding: ShortcutBinding, to command: ShortcutCommand, slot: Int) -> String? {
        var updated = keymap
        if let other = updated.conflict(for: binding, command: command, slot: slot), other != command {
            updated.unassign(binding, in: command.context)
        }
        if let error = updated.validationError(binding, for: command, slot: slot) { return error }
        updated.set(binding, for: command, slot: slot)
        keymap = updated
        persist()
        return nil
    }
    /// Only changed shortcuts are stored, so later changes to the defaults reach every user.
    private func persist() {
        if let data = try? JSONEncoder().encode(keymap.changes(from: .defaults)) { defaults.set(data, forKey: Self.storageKey) }
        defaults.removeObject(forKey: Self.legacyStorageKey)
        defaults.set(activePresetName, forKey: Self.activePresetKey)
    }

    // MARK: Presets

    func preset(named name: String) -> KeyboardPreset? {
        name == KeyboardPreset.builtInName ? KeyboardPreset(name: name, keymap: .defaults) : presets.first { $0.name == name }
    }
    var isBuiltInPresetActive: Bool { activePresetName == KeyboardPreset.builtInName }
    /// Whether the keymap has changed since its preset was applied or saved.
    var isModified: Bool { preset(named: activePresetName).map { $0.resolved.keymap != keymap } ?? true }
    /// The keymap under the active preset's name, as a file would share it.
    var currentPreset: KeyboardPreset { KeyboardPreset(name: activePresetName, keymap: keymap) }
    /// Switches to a preset, returning how many of its shortcuts this version could not use.
    @discardableResult func applyPreset(named name: String) -> Int {
        guard let preset = preset(named: name) else { return 0 }
        let resolved = preset.resolved
        keymap = resolved.keymap
        activePresetName = name
        persist()
        return resolved.rejected
    }
    /// Saves the keymap under a name, replacing a saved preset of that name, and makes it active.
    func savePreset(named proposedName: String) -> String? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "Enter a name for the preset.") }
        guard name != KeyboardPreset.builtInName else { return String(localized: "The built-in preset cannot be replaced. Choose another name.") }
        let preset = KeyboardPreset(name: name, keymap: keymap)
        if let index = presets.firstIndex(where: { $0.name == name }) { presets[index] = preset } else { presets.append(preset) }
        activePresetName = name
        persistPresets()
        return nil
    }
    func renamePreset(_ oldName: String, to proposedName: String) -> String? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = presets.firstIndex(where: { $0.name == oldName }) else { return String(localized: "Only saved presets can be renamed.") }
        guard !name.isEmpty else { return String(localized: "Enter a name for the preset.") }
        guard name == oldName || preset(named: name) == nil else { return String(localized: "A preset named “\(name)” already exists.") }
        presets[index].name = name
        if activePresetName == oldName { activePresetName = name }
        persistPresets()
        return nil
    }
    func deletePreset(named name: String) {
        presets.removeAll { $0.name == name }
        if activePresetName == name { activePresetName = KeyboardPreset.builtInName }
        persistPresets()
    }
    /// Adds a shared preset, renamed if its name is taken, and switches to it.
    func importPreset(_ preset: KeyboardPreset) -> (name: String, rejected: Int) {
        var imported = preset
        var suffix = 2
        while self.preset(named: imported.name) != nil {
            imported.name = "\(preset.name) \(suffix)"
            suffix += 1
        }
        presets.append(imported)
        persistPresets()
        return (imported.name, applyPreset(named: imported.name))
    }
    private func persistPresets() {
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.presetsKey) }
        persist()
    }
    /// The preset's name as the editor shows it; the built-in preset's name is localized.
    static func displayName(ofPreset name: String) -> String {
        name == KeyboardPreset.builtInName ? String(localized: "Media Converter Default") : name
    }

    // MARK: Earlier versions

    /// Shortcuts that earlier versions stored by key code, as saved choices for the
    /// current commands. Those versions kept U.S. key labels for physical keys.
    private static func legacyChoices(_ defaults: UserDefaults) -> [String: [ShortcutBinding]]? {
        struct LegacyBinding: Decodable {
            let keyCode: UInt16
            let modifierBits: UInt
        }
        guard let data = defaults.data(forKey: legacyStorageKey),
              let saved = try? JSONDecoder().decode([String: LegacyBinding].self, from: data) else { return nil }
        let commands: [String: ShortcutCommand] = [
            "watchFolder": .toggleWatchFolder, "outputFolder": .selectOutputFolder, "merge": .toggleMerge, "resetAll": .resetAll,
            "conversion": .toggleConversion, "download": .showURLInput, "capture": .openCapture, "presets": .showPresetQuickSelect,
            "shortcuts": .showShortcuts]
        let keys: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e",
            15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            31: "o", 32: "u", 34: "i", 35: "p", 36: "return", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m"]
        var choices: [String: [ShortcutBinding]] = [:]
        for (name, legacy) in saved {
            guard let command = commands[name], let key = keys[legacy.keyCode] else { continue }
            let binding = ShortcutBinding(key: key, modifiers: ShortcutModifiers(NSEvent.ModifierFlags(rawValue: legacy.modifierBits)))
            choices[command.rawValue] = [binding]
        }
        return choices
    }
}

// MARK: - AppKit and SwiftUI

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

extension ShortcutBinding {
    /// The shortcut a key press produces, matching how the editor's keyboard labels keys.
    static func pressed(_ event: NSEvent) -> ShortcutBinding? {
        guard let key = keyCodeNames[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return pressed(key: key, modifiers: ShortcutModifiers(event.modifierFlags))
    }

    /// The shortcut for a key press described by its characters, as the trim view's
    /// key handlers report it.
    static func pressed(characters: String, modifierFlags: NSEvent.ModifierFlags, specialKey: NSEvent.SpecialKey?) -> ShortcutBinding? {
        let named: String?
        switch specialKey {
        case .leftArrow?: named = "left"
        case .rightArrow?: named = "right"
        case .upArrow?: named = "up"
        case .downArrow?: named = "down"
        case .home?: named = "home"
        case .end?: named = "end"
        case .pageUp?: named = "pageup"
        case .pageDown?: named = "pagedown"
        case .delete?, .deleteForward?, .backspace?: named = "delete"
        case .carriageReturn?, .enter?, .newline?: named = "return"
        case .tab?, .backTab?: named = "tab"
        case .f1?: named = "f1"
        case .f2?: named = "f2"
        case .f3?: named = "f3"
        case .f4?: named = "f4"
        case .f5?: named = "f5"
        case .f6?: named = "f6"
        case .f7?: named = "f7"
        case .f8?: named = "f8"
        case .f9?: named = "f9"
        case .f10?: named = "f10"
        case .f11?: named = "f11"
        case .f12?: named = "f12"
        default: named = [" ": "space", "\u{1b}": "escape", "\r": "return", "\t": "tab", "\u{19}": "tab", "\u{7f}": "delete"][characters]
        }
        return pressed(key: named ?? characters.lowercased(), modifiers: ShortcutModifiers(modifierFlags))
    }

    var keyEquivalent: KeyEquivalent? {
        guard !isEmpty else { return nil }
        switch normalized.key {
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "delete": return .delete
        case "return": return .return
        case "escape": return .escape
        case "space": return .space
        case "tab": return .tab
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case let key where isFunctionKey:
            // AppKit's private-use characters for F1–F12 start at NSF1FunctionKey.
            return Int(key.dropFirst()).flatMap { UnicodeScalar(NSF1FunctionKey + $0 - 1) }.map { KeyEquivalent(Character($0)) }
        default: return normalized.key.first.map { KeyEquivalent($0) }
        }
    }
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        if shift { result.insert(.shift) }
        return result
    }
    var keyboardShortcut: KeyboardShortcut? { keyEquivalent.map { KeyboardShortcut($0, modifiers: eventModifiers) } }
}
