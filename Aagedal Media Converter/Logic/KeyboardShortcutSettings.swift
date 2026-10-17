// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Main-window shortcuts. Key codes preserve the app's existing physical-key behavior.
enum MainWindowShortcut: String, CaseIterable, Identifiable {
    case watchFolder, outputFolder, merge, resetAll, conversion, download, capture, presets, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watchFolder: return "Toggle watch folder"
        case .outputFolder: return "Select output folder"
        case .merge: return "Toggle merging of clips"
        case .resetAll: return "Reset conversion status of all items"
        case .conversion: return "Start/Stop encoding"
        case .download: return "Show URL input overlay (for downloading)"
        case .capture: return "Open Capture Mode"
        case .presets: return "Open preset quick-select overlay"
        case .shortcuts: return "Open Shortcuts help"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .watchFolder: return ShortcutBinding(keyCode: 13, modifiers: .option)
        case .outputFolder: return ShortcutBinding(keyCode: 3, modifiers: .option)
        case .merge: return ShortcutBinding(keyCode: 46, modifiers: .option)
        case .resetAll: return ShortcutBinding(keyCode: 15, modifiers: [.command, .shift])
        case .conversion: return ShortcutBinding(keyCode: 36, modifiers: .command)
        case .download: return ShortcutBinding(keyCode: 2, modifiers: .command)
        case .capture: return ShortcutBinding(keyCode: 8, modifiers: [.command, .shift])
        case .presets: return ShortcutBinding(keyCode: 35, modifiers: .command)
        case .shortcuts: return ShortcutBinding(keyCode: 40, modifiers: .control)
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt16
    private let modifierBits: UInt

    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
    ]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierBits = modifiers.intersection(Self.supportedModifiers).rawValue
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    var isValid: Bool {
        Self.keyNames[keyCode] != nil && !modifiers.intersection([.command, .control, .option]).isEmpty
            && modifierBits == modifiers.intersection(Self.supportedModifiers).rawValue
    }

    var display: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(Self.keyNames[keyCode] ?? "?")
        return parts.joined(separator: " + ")
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && modifiers == event.modifierFlags.intersection(Self.supportedModifiers)
    }
}

struct KeyboardShortcutSettings {
    static let storageKey = "mainWindowKeyboardShortcuts.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var overrides: [String: ShortcutBinding] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let bindings = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else { return [:] }
        return bindings.filter { MainWindowShortcut(rawValue: $0.key) != nil && $0.value.isValid }
    }

    func binding(for action: MainWindowShortcut) -> ShortcutBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    func conflict(for binding: ShortcutBinding, action: MainWindowShortcut) -> MainWindowShortcut? {
        // Reserve defaults as well so individual actions can always be restored safely.
        MainWindowShortcut.allCases.first {
            $0 != action && (self.binding(for: $0) == binding || $0.defaultBinding == binding)
        }
    }

    func set(_ binding: ShortcutBinding, for action: MainWindowShortcut) {
        guard binding.isValid, conflict(for: binding, action: action) == nil else { return }
        var bindings = overrides
        bindings[action.rawValue] = binding == action.defaultBinding ? nil : binding
        if bindings.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func reset() { defaults.removeObject(forKey: Self.storageKey) }
}
