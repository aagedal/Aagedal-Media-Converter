// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let control = ShortcutModifiers(rawValue: 1)
    static let option = ShortcutModifiers(rawValue: 2)
    static let shift = ShortcutModifiers(rawValue: 4)
    static let command = ShortcutModifiers(rawValue: 8)
    /// All sixteen combinations, fewest modifiers first.
    static let allCombinations = (0..<16).map(ShortcutModifiers.init(rawValue:))
        .sorted { ($0.rawValue.nonzeroBitCount, $0.rawValue) < ($1.rawValue.nonzeroBitCount, $1.rawValue) }
    /// In the order macOS menus show them.
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A key and its modifiers. Keys are stored by the character the current keyboard
/// layout types (with only Shift applied), or by name for keys that type no character.
struct ShortcutBinding: Codable, Hashable, Sendable {
    /// Keys named rather than typed.
    static let namedKeys = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "delete", "return", "escape", "space", "tab"]
    /// Keys that move the insertion point or delete text, which focused text keeps even with ⌘ or ⌃.
    static let textEditingKeys: Set<String> = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown", "delete"]
    static let functionKeys = (1...12).map { "f\($0)" }
    /// macOS virtual key codes of the keys that have names rather than characters.
    /// Forward delete and keypad enter share the names of delete and return.
    static let keyCodeNames: [UInt16: String] = [
        49: "space", 48: "tab", 51: "delete", 117: "delete", 123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "return",
        53: "escape", 115: "home", 119: "end", 116: "pageup", 121: "pagedown", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5",
        97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
    /// Characters that start timecode entry in the players when typed without modifiers.
    static let timecodeCharacters: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", ".", ":", ";", "="]
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    var normalized: ShortcutBinding {
        var result = self
        result.key = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return result
    }
    var isEmpty: Bool { normalized.key.isEmpty }
    var isFunctionKey: Bool { Self.functionKeys.contains(normalized.key) }
    var modifiers: ShortcutModifiers {
        var result: ShortcutModifiers = []
        if command { result.insert(.command) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        if shift { result.insert(.shift) }
        return result
    }
    var keyLabel: String {
        ["left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "return": "↩", "escape": "⎋", "space": "Space", "tab": "⇥",
         "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟"][normalized.key] ?? normalized.key.uppercased()
    }
    var display: String { isEmpty ? "—" : modifiers.symbols + keyLabel }
    /// Words a search for this shortcut may use, such as "cmd shift b".
    var searchText: String {
        guard !isEmpty else { return "" }
        let words = [control ? "control ctrl" : "", option ? "option opt alt" : "", shift ? "shift" : "", command ? "command cmd" : ""]
        return (words + [normalized.key, display]).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    /// The binding for a key press, from the key's name or the character it types with
    /// only Shift applied (as `charactersIgnoringModifiers` reports it).
    static func pressed(key: String, modifiers: ShortcutModifiers) -> ShortcutBinding? {
        guard !key.isEmpty else { return nil }
        // "+" is Shift-= on U.S. keyboards and its own key on many others; both mean the = binding.
        if key == "+" { return ShortcutBinding(key: "=", modifiers: modifiers.subtracting(.shift)) }
        return ShortcutBinding(key: key, modifiers: modifiers).normalized
    }

    /// Whether the shortcut may run while text has focus: function keys, and Command or
    /// Control chords other than those that move the insertion point or delete text.
    var isSafeDuringTextEditing: Bool {
        let shortcut = normalized
        return shortcut.isFunctionKey || ((shortcut.command || shortcut.control) && !Self.textEditingKeys.contains(shortcut.key))
    }
    /// Menus show only chords that never take keys from text entry; the window's key
    /// monitors deliver every other shortcut.
    var isMenuKeyEquivalent: Bool {
        let shortcut = normalized
        return shortcut.isFunctionKey || ((shortcut.command || shortcut.control) && !Self.namedKeys.contains(shortcut.key))
    }
}

extension ShortcutBinding {
    init(key: String, modifiers: ShortcutModifiers) {
        self.init(key: key, command: modifiers.contains(.command), option: modifiers.contains(.option),
                  control: modifiers.contains(.control), shift: modifiers.contains(.shift))
    }
    // Absent modifiers decode as off and are not written, which keeps shared preset files short.
    private enum CodingKeys: String, CodingKey { case key, command, option, control, shift }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(String.self, forKey: .key),
                  command: try container.decodeIfPresent(Bool.self, forKey: .command) ?? false,
                  option: try container.decodeIfPresent(Bool.self, forKey: .option) ?? false,
                  control: try container.decodeIfPresent(Bool.self, forKey: .control) ?? false,
                  shift: try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        for (flag, codingKey) in [(command, CodingKeys.command), (option, .option), (control, .control), (shift, .shift)] where flag {
            try container.encode(true, forKey: codingKey)
        }
    }
}

// MARK: - Reserved shortcuts

/// A shortcut no command may use, and why.
struct ShortcutReservation: Equatable, Sendable {
    /// A few words for the on-screen keyboard, such as "Quit".
    let title: String
    let message: String
}

extension ShortcutBinding {
    /// The standard macOS command that owns this shortcut in every window.
    var standardCommandTitle: String? {
        let candidate = normalized
        // Help is ⌘? on every layout: Shift-/ on U.S. keyboards, Shift-+ on Norwegian ones.
        if candidate.command && candidate.key == "?" { return String(localized: "Help") }
        switch candidate.modifiers {
        case .command:
            return ["q": String(localized: "Quit"), "w": String(localized: "Close"), "h": String(localized: "Hide"),
                    "m": String(localized: "Minimize"), ",": String(localized: "Settings…"), "z": String(localized: "Undo"),
                    "x": String(localized: "Cut"), "c": String(localized: "Copy"), "v": String(localized: "Paste"),
                    "`": String(localized: "Next Window")][candidate.key]
        case [.command, .shift]: return candidate.key == "z" ? String(localized: "Redo") : nil
        case [.command, .option]: return candidate.key == "h" ? String(localized: "Hide Others") : nil
        case [.command, .control]: return candidate.key == "f" ? String(localized: "Full Screen") : nil
        default: return nil
        }
    }
    /// Chords that macOS takes before the app sees them.
    var isSystemChord: Bool {
        let candidate = normalized
        return (candidate.key == "space" && (candidate.command || candidate.option || candidate.control))
            || (candidate.control && ["left", "right", "up", "down"].contains(candidate.key))
            || (candidate.command && candidate.key == "tab")
            || (candidate.command && candidate.option && candidate.key == "escape")
    }

    /// Why no command in `context` may use this shortcut.
    func reservation(in context: ShortcutContext) -> ShortcutReservation? {
        let candidate = normalized
        guard !candidate.isEmpty else { return nil }
        if let title = candidate.standardCommandTitle {
            return ShortcutReservation(title: title, message: String(localized: "This shortcut is reserved for a standard macOS command."))
        }
        if candidate.isSystemChord {
            return ShortcutReservation(title: "macOS", message: String(localized: "This combination is reserved for macOS."))
        }
        if let title = context.builtInShortcutTitle(for: candidate) {
            return ShortcutReservation(title: title, message: String(localized: "This shortcut is built in and cannot be reassigned."))
        }
        return nil
    }

    /// Why this shortcut cannot run `command`, apart from conflicts with other commands.
    func validationError(for command: ShortcutCommand) -> String? {
        let candidate = normalized
        if candidate.isEmpty { return nil }
        guard Self.namedKeys.contains(candidate.key) || candidate.isFunctionKey
                || (candidate.key.count == 1 && candidate.key.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else {
            return String(localized: "Use one character, F1–F12, an arrow key, Home, End, Page Up, Page Down, Delete, Return, Escape, Space or Tab.")
        }
        guard command.allowsUnmodifiedKey || candidate.isFunctionKey || candidate.command || candidate.option || candidate.control else {
            return String(localized: "Include Command, Option or Control. Only queue and player commands can use a key on its own.")
        }
        return candidate.reservation(in: command.context)?.message
    }
}

extension ShortcutContext {
    /// The fixed key handling in this context that commands cannot replace.
    func builtInShortcutTitle(for binding: ShortcutBinding) -> String? {
        let candidate = binding.normalized
        switch self {
        case .main:
            if candidate.modifiers == .command && candidate.key == "a" { return String(localized: "Select All") }
            // Overlays such as URL input and preset quick-select close with Escape.
            if candidate.modifiers.isEmpty && candidate.key == "escape" { return String(localized: "Close") }
        case .trim, .fullscreen:
            if candidate.modifiers.isEmpty && candidate.key == "escape" { return String(localized: "Close") }
            if candidate.modifiers.isEmpty && ShortcutBinding.timecodeCharacters.contains(candidate.key) { return String(localized: "Timecode") }
        }
        return nil
    }
}

// MARK: - Keymap

/// Every command's shortcuts: up to two each, the first being the one menus show.
/// A command's shortcuts stay compact, so clearing the first promotes the second.
/// Commands conflict only with commands of their own context.
struct Keymap: Equatable, Sendable {
    static let slotCount = 2
    private var shortcuts: [ShortcutCommand: [ShortcutBinding]] = [:]

    static var defaults: Keymap {
        var keymap = Keymap()
        for command in ShortcutCommand.allCases { keymap.shortcuts[command] = command.defaultBindings }
        return keymap
    }

    /// The command's first shortcut, or an empty binding.
    subscript(command: ShortcutCommand) -> ShortcutBinding { binding(for: command, slot: 0) }
    func bindings(for command: ShortcutCommand) -> [ShortcutBinding] { shortcuts[command] ?? [] }
    func binding(for command: ShortcutCommand, slot: Int) -> ShortcutBinding {
        let list = bindings(for: command)
        return list.indices.contains(slot) ? list[slot] : ShortcutBinding(key: "")
    }
    /// The command that a shortcut runs in a context, and which of that command's shortcuts it is.
    func assignment(of binding: ShortcutBinding, in context: ShortcutContext) -> (command: ShortcutCommand, slot: Int)? {
        let target = binding.normalized
        guard !target.isEmpty else { return nil }
        for command in ShortcutCommand.allCases where command.context == context {
            if let slot = bindings(for: command).firstIndex(of: target) { return (command, slot) }
        }
        return nil
    }
    func command(for binding: ShortcutBinding, in context: ShortcutContext) -> ShortcutCommand? {
        assignment(of: binding, in: context)?.command
    }
    /// Every assigned shortcut of a context and its command, for lookups across a whole keyboard.
    func commandsByBinding(in context: ShortcutContext) -> [ShortcutBinding: ShortcutCommand] {
        var result: [ShortcutBinding: ShortcutCommand] = [:]
        for command in ShortcutCommand.allCases where command.context == context {
            for binding in bindings(for: command) { result[binding] = command }
        }
        return result
    }

    /// The other command (or this command's other slot) that already uses `binding`.
    func conflict(for binding: ShortcutBinding, command: ShortcutCommand, slot: Int) -> ShortcutCommand? {
        guard let found = assignment(of: binding, in: command.context) else { return nil }
        return found.command == command && found.slot == min(slot, bindings(for: command).count) ? nil : found.command
    }
    /// Why `binding` cannot be the command's shortcut in `slot`, including conflicts.
    func validationError(_ binding: ShortcutBinding, for command: ShortcutCommand, slot: Int = 0) -> String? {
        if let error = binding.validationError(for: command) { return error }
        if let other = conflict(for: binding, command: command, slot: slot) {
            return other == command
                ? String(localized: "This is already the command's other shortcut.")
                : String(localized: "Already assigned to “\(other.title)”.")
        }
        return nil
    }

    /// Sets one shortcut without validation; an empty binding clears the slot, and a
    /// slot past the command's last shortcut adds one.
    mutating func set(_ binding: ShortcutBinding, for command: ShortcutCommand, slot: Int) {
        var list = bindings(for: command)
        let value = binding.normalized
        if list.indices.contains(slot) {
            if value.isEmpty { list.remove(at: slot) } else { list[slot] = value }
        } else if !value.isEmpty {
            list.append(value)
        }
        shortcuts[command] = Array(list.prefix(Self.slotCount))
    }
    /// Removes a shortcut from whichever command of the context has it.
    mutating func unassign(_ binding: ShortcutBinding, in context: ShortcutContext) {
        guard let found = assignment(of: binding, in: context) else { return }
        set(ShortcutBinding(key: ""), for: found.command, slot: found.slot)
    }

    /// Every command's shortcuts by command name, unbound commands included.
    var savedForm: [String: [ShortcutBinding]] {
        Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { ($0.rawValue, bindings(for: $0)) })
    }
    /// The saved form of only the commands whose shortcuts differ from `base`.
    func changes(from base: Keymap) -> [String: [ShortcutBinding]] {
        savedForm.filter { name, bindings in ShortcutCommand(rawValue: name).map { base.bindings(for: $0) != bindings } ?? false }
    }
    /// Rebuilds a keymap from saved choices. Commands absent from `saved` (such as ones
    /// added since it was written) take their defaults unless a saved choice already
    /// uses them; saved shortcuts that are invalid or already in use are left out and counted.
    static func restoring(_ saved: [String: [ShortcutBinding]]) -> (keymap: Keymap, rejected: Int) {
        var keymap = Keymap()
        var rejected = 0
        for command in ShortcutCommand.allCases {
            keymap.shortcuts[command] = []
            for binding in saved[command.rawValue] ?? [] where !binding.isEmpty {
                let slot = keymap.bindings(for: command).count
                if slot < slotCount && keymap.validationError(binding, for: command, slot: slot) == nil {
                    keymap.set(binding, for: command, slot: slot)
                } else {
                    rejected += 1
                }
            }
        }
        // New or changed defaults must not erase an existing custom map.
        // Leave such a command unbound if its default is already in use.
        for command in ShortcutCommand.allCases where saved[command.rawValue] == nil {
            for binding in command.defaultBindings where keymap.assignment(of: binding, in: command.context) == nil {
                keymap.set(binding, for: command, slot: keymap.bindings(for: command).count)
            }
        }
        return (keymap, rejected)
    }
}

// MARK: - Presets

/// A named keymap that can be saved, switched to, and shared as a file.
struct KeyboardPreset: Codable, Equatable, Identifiable, Sendable {
    /// The built-in preset's identifier; the editor shows it localized.
    static let builtInName = "Media Converter Default"
    static let fileExtension = "amckeys"
    static let fileFormat = "com.aagedal.mediaconverter.keyboard-preset"
    static let fileVersion = 1
    var name: String
    /// Every command's shortcuts by command name, so the preset reads the same on any machine.
    var shortcuts: [String: [ShortcutBinding]]
    var id: String { name }
    /// The preset's keymap, and how many of its shortcuts this version cannot use.
    var resolved: (keymap: Keymap, rejected: Int) { Keymap.restoring(shortcuts) }

    private struct File: Codable {
        var format: String
        var version: Int
        var name: String
        var shortcuts: [String: [ShortcutBinding]]
    }
    func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(format: Self.fileFormat, version: Self.fileVersion, name: name, shortcuts: shortcuts))
    }
}

extension KeyboardPreset {
    init(name: String, keymap: Keymap) { self.init(name: name, shortcuts: keymap.savedForm) }
    init(fileData data: Data) throws {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == Self.fileFormat else {
            throw KeyboardPresetError.notAPreset
        }
        guard file.version <= Self.fileVersion else { throw KeyboardPresetError.newerVersion }
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: name.isEmpty ? String(localized: "Imported Shortcuts") : name, shortcuts: file.shortcuts)
    }
}

enum KeyboardPresetError: LocalizedError {
    case notAPreset, newerVersion
    var errorDescription: String? {
        switch self {
        case .notAPreset: String(localized: "This file is not a Media Converter keyboard preset.")
        case .newerVersion: String(localized: "This keyboard preset was made by a newer version of Media Converter.")
        }
    }
}
