// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One key of the shortcut editor's on-screen keyboard.
struct VirtualKey: Identifiable, Hashable {
    enum Role: Hashable {
        /// A key that shortcuts can use, by the name or characters the key monitors see for it.
        case key(base: String, shifted: String)
        case modifier(ShortcutModifiers)
        case inert
        case spacer
    }
    let id: String
    let keyCode: UInt16?
    let role: Role
    /// In key units; a letter key is one unit wide.
    let width: CGFloat
    let label: String
    /// The legend above the main one, such as ! over 1.
    let shiftedLabel: String?

    /// The shortcuts a press of this key with the given modifiers may mean, matching
    /// `ShortcutBinding.candidates(for:)` for the same press.
    func candidates(with modifiers: ShortcutModifiers) -> [ShortcutBinding] {
        guard case let .key(base, shifted) = role,
              let typed = ShortcutBinding.pressed(key: modifiers.contains(.shift) ? shifted : base, modifiers: modifiers) else { return [] }
        return keyCode.map { ShortcutBinding.candidates(typed: typed, keyCode: $0) } ?? [typed]
    }
    /// The shortcut the editor assigns to this key with the given modifiers held, matching
    /// `ShortcutBinding.recorded(_:)`: the U.S. letter or digit where the layout types another character.
    func binding(with modifiers: ShortcutModifiers) -> ShortcutBinding? { candidates(with: modifiers).last }
    /// The command a press of this key runs, and the shortcut that runs it.
    func match(with modifiers: ShortcutModifiers, in commands: [ShortcutBinding: ShortcutCommand]) -> (command: ShortcutCommand, binding: ShortcutBinding)? {
        for binding in candidates(with: modifiers) {
            if let command = commands[binding] { return (command, binding) }
        }
        return nil
    }
    /// Every distinct shortcut this key can produce, fewest modifiers first.
    var bindings: [(modifiers: ShortcutModifiers, binding: ShortcutBinding)] {
        var seen: Set<ShortcutBinding> = []
        return ShortcutModifiers.allCombinations.compactMap { modifiers in
            guard let binding = binding(with: modifiers), seen.insert(binding).inserted else { return nil }
            return (modifiers, binding)
        }
    }
    /// A name for lists and accessibility, such as "J" or "Left Arrow".
    var name: String {
        guard case let .key(base, _) = role else { return label }
        switch base {
        case "left": return String(localized: "Left Arrow")
        case "right": return String(localized: "Right Arrow")
        case "up": return String(localized: "Up Arrow")
        case "down": return String(localized: "Down Arrow")
        case "delete": return keyCode == 117 ? String(localized: "Forward Delete") : String(localized: "Delete")
        case "return": return String(localized: "Return")
        case "escape": return String(localized: "Escape")
        case "space": return String(localized: "Space")
        case "tab": return String(localized: "Tab")
        case "home": return String(localized: "Home")
        case "end": return String(localized: "End")
        case "pageup": return String(localized: "Page Up")
        case "pagedown": return String(localized: "Page Down")
        default: return base.uppercased()
        }
    }
}

/// The physical keyboard drawn by the shortcut editor, labelled from the current input
/// source so that each key shows the character it types (Ø on a Norwegian layout, for example).
struct VirtualKeyboardLayout: Equatable {
    var mainRows: [[VirtualKey]]
    var navigationRows: [[VirtualKey]]
    var isISO: Bool
    var inputSourceName: String

    var keys: [VirtualKey] { (mainRows + navigationRows).flatMap { $0 } }
    func key(id: VirtualKey.ID?) -> VirtualKey? { keys.first { $0.id == id } }
    /// The key that produces a shortcut on this layout, if any does.
    func key(for binding: ShortcutBinding) -> VirtualKey? {
        keys.first { $0.candidates(with: binding.modifiers).contains(binding.normalized) }
    }

    private enum Spec {
        case code(UInt16, CGFloat = 1)
        case modifier(ShortcutModifiers, String, CGFloat)
        case inert(String, CGFloat)
        case spacer(CGFloat)
    }

    static func current() -> VirtualKeyboardLayout {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        let layoutData = source.flatMap { source in
            TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData).map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }
        }
        let sourceName = source.flatMap { source in
            TISGetInputSourceProperty(source, kTISPropertyLocalizedName).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        } ?? "U.S."
        let isISO = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
        let functionRow: [Spec] = [.code(53, 1.5)] + [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].map { .code($0, 1.125) }
        let letters2: [Spec] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30].map { .code($0) }
        let letters3: [Spec] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39].map { .code($0) }
        let letters4: [Spec] = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44].map { .code($0) }
        let digits: [Spec] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24].map { .code($0) }
        let bottom: [Spec] = [.inert("fn", 1), .modifier(.control, "⌃ control", 1.25), .modifier(.option, "⌥ option", 1.25),
                              .modifier(.command, "⌘ command", 1.5), .code(49, 5.5), .modifier(.command, "⌘ command", 1.5),
                              .modifier(.option, "⌥ option", 1.25), .modifier(.control, "⌃ control", 1.75)]
        // ISO keyboards have a key left of 1 (code 10), one beside left Shift (code 50) and a tall Return.
        let main: [[Spec]] = isISO ? [
            functionRow,
            [.code(10)] + digits + [.code(51, 2)],
            [.code(48, 1.5)] + letters2 + [.code(36, 1.5)],
            [.inert("⇪", 1.75)] + letters3 + [.code(42), .code(36, 1.25)],
            [.modifier(.shift, "⇧ shift", 1.25), .code(50)] + letters4 + [.modifier(.shift, "⇧ shift", 2.75)],
            bottom,
        ] : [
            functionRow,
            [.code(50)] + digits + [.code(51, 2)],
            [.code(48, 1.5)] + letters2 + [.code(42, 1.5)],
            [.inert("⇪", 1.75)] + letters3 + [.code(36, 2.25)],
            [.modifier(.shift, "⇧ shift", 2.25)] + letters4 + [.modifier(.shift, "⇧ shift", 2.75)],
            bottom,
        ]
        let navigation: [[Spec]] = [
            [.spacer(3)],
            [.inert("fn", 1), .code(115), .code(116)],
            [.code(117), .code(119), .code(121)],
            [.spacer(3)],
            [.spacer(1), .code(126), .spacer(1)],
            [.code(123), .code(125), .code(124)],
        ]
        func keys(_ rows: [[Spec]], prefix: String) -> [[VirtualKey]] {
            var drawn: Set<UInt16> = []
            return rows.enumerated().map { row, specs in
                specs.enumerated().map { column, spec in
                    let id = "\(prefix)\(row).\(column)"
                    switch spec {
                    case let .code(code, width):
                        // The lower half of the ISO Return key carries no second legend.
                        let key = key(code: code, width: width, id: id, layoutData: layoutData)
                        guard drawn.insert(code).inserted else {
                            return VirtualKey(id: id, keyCode: code, role: key.role, width: width, label: "", shiftedLabel: nil)
                        }
                        return key
                    case let .modifier(modifier, label, width):
                        return VirtualKey(id: id, keyCode: nil, role: .modifier(modifier), width: width, label: label, shiftedLabel: nil)
                    case let .inert(label, width): return VirtualKey(id: id, keyCode: nil, role: .inert, width: width, label: label, shiftedLabel: nil)
                    case let .spacer(width): return VirtualKey(id: id, keyCode: nil, role: .spacer, width: width, label: "", shiftedLabel: nil)
                    }
                }
            }
        }
        return VirtualKeyboardLayout(mainRows: keys(main, prefix: "m"), navigationRows: keys(navigation, prefix: "n"),
                                     isISO: isISO, inputSourceName: sourceName)
    }

    private static func key(code: UInt16, width: CGFloat, id: String, layoutData: Data?) -> VirtualKey {
        if let name = ShortcutBinding.keyCodeNames[code] {
            let labels = ["escape": "esc", "delete": code == 117 ? "⌦" : "⌫ delete", "tab": "⇥ tab", "return": "↩ return", "space": "",
                          "home": "home", "end": "end", "pageup": "pg up", "pagedown": "pg dn"]
            return VirtualKey(id: id, keyCode: code, role: .key(base: name, shifted: name), width: width,
                              label: labels[name] ?? ShortcutBinding(key: name).keyLabel, shiftedLabel: nil)
        }
        let (base, shifted) = characters(for: code, layoutData: layoutData) ?? usCharacters[code] ?? ("?", "?")
        let lowered = (base.lowercased(), shifted.lowercased())
        // Letters show one legend; keys whose Shift character differs show both, as printed caps do.
        let showsShifted = lowered.1 != lowered.0 && !shifted.isEmpty
        // Some lowercase letters, such as ß, have no single-letter capital.
        let capital = base.uppercased()
        return VirtualKey(id: id, keyCode: code, role: .key(base: lowered.0, shifted: lowered.1), width: width,
                          label: capital.count == base.count ? capital : base, shiftedLabel: showsShifted ? shifted : nil)
    }

    /// The characters the input source types for a key, unshifted and with Shift.
    private static func characters(for keyCode: UInt16, layoutData: Data?) -> (String, String)? {
        guard let layoutData else { return nil }
        return layoutData.withUnsafeBytes { raw -> (String, String)? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            func translate(_ modifierState: UInt32) -> String? {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                                            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                let string = String(utf16CodeUnits: characters, count: length)
                return string.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ? string : nil
            }
            guard let base = translate(0) else { return nil }
            return (base, translate(UInt32(shiftKey >> 8) & 0xFF) ?? base)
        }
    }

    private static let usCharacters: [UInt16: (String, String)] = [
        50: ("`", "~"), 10: ("§", "±"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 23: ("5", "%"), 22: ("6", "^"),
        26: ("7", "&"), 28: ("8", "*"), 25: ("9", "("), 29: ("0", ")"), 27: ("-", "_"), 24: ("=", "+"), 12: ("q", "Q"), 13: ("w", "W"),
        14: ("e", "E"), 15: ("r", "R"), 17: ("t", "T"), 16: ("y", "Y"), 32: ("u", "U"), 34: ("i", "I"), 31: ("o", "O"), 35: ("p", "P"),
        33: ("[", "{"), 30: ("]", "}"), 42: ("\\", "|"), 0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 5: ("g", "G"),
        4: ("h", "H"), 38: ("j", "J"), 40: ("k", "K"), 37: ("l", "L"), 41: (";", ":"), 39: ("'", "\""), 6: ("z", "Z"), 7: ("x", "X"),
        8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 45: ("n", "N"), 46: ("m", "M"), 43: (",", "<"), 47: (".", ">"), 44: ("/", "?"),
    ]
}

extension ShortcutCategory {
    var color: Color {
        switch self {
        case .playback: .green
        case .navigation: .teal
        case .trimming: .orange
        case .items: .blue
        case .views: .purple
        case .crop: .indigo
        case .encoding: .pink
        case .general: .brown
        }
    }
}

// MARK: - On-screen keyboard

/// The on-screen keyboard at the largest size that fits the available width.
struct VirtualKeyboardView: View {
    let layout: VirtualKeyboardLayout
    let context: ShortcutContext
    let commands: [ShortcutBinding: ShortcutCommand]
    let layer: ShortcutModifiers
    let selectedKeyID: VirtualKey.ID?
    let highlightedKeyIDs: Set<VirtualKey.ID>
    let select: (VirtualKey) -> Void
    let toggleModifier: (ShortcutModifiers) -> Void
    let drop: (ShortcutCommand, VirtualKey) -> Bool

    /// The keyboard's size at full scale, with 48-point letter keys.
    private static let naturalSize = CGSize(width: 900, height: 288)

    var body: some View {
        GeometryReader { proxy in
            KeyboardRows(layout: layout, context: context, commands: commands, layer: layer, selectedKeyID: selectedKeyID,
                         highlightedKeyIDs: highlightedKeyIDs, select: select, toggleModifier: toggleModifier, drop: drop,
                         scale: min(1, proxy.size.width / Self.naturalSize.width))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(Self.naturalSize.width / Self.naturalSize.height, contentMode: .fit)
        .frame(maxWidth: Self.naturalSize.width)
    }
}

private struct KeyboardRows: View {
    let layout: VirtualKeyboardLayout
    let context: ShortcutContext
    let commands: [ShortcutBinding: ShortcutCommand]
    let layer: ShortcutModifiers
    let selectedKeyID: VirtualKey.ID?
    let highlightedKeyIDs: Set<VirtualKey.ID>
    let select: (VirtualKey) -> Void
    let toggleModifier: (ShortcutModifiers) -> Void
    let drop: (ShortcutCommand, VirtualKey) -> Bool
    let scale: CGFloat

    private var unit: CGFloat { 48 * scale }
    private var gap: CGFloat { 4 * scale }

    var body: some View {
        HStack(alignment: .top, spacing: unit / 2) {
            rows(layout.mainRows)
            rows(layout.navigationRows)
        }
        .padding(10 * scale)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        // The layout's name fills the gap above the navigation keys.
        .overlay(alignment: .topTrailing) {
            Text(verbatim: layout.inputSourceName)
                .font(.system(size: max(8, 10 * scale)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 3 * unit - gap, height: 28 * scale)
                .padding([.top, .trailing], 10 * scale)
                .help("Keys are labelled for this keyboard layout")
        }
    }

    private func rows(_ rows: [[VirtualKey]]) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: gap) {
                    ForEach(row) { key in
                        cap(key).frame(width: key.width * unit - gap, height: (index == 0 ? 28 : 44) * scale)
                    }
                }
            }
        }
    }

    @ViewBuilder private func cap(_ key: VirtualKey) -> some View {
        switch key.role {
        case .spacer:
            Color.clear
        case let .modifier(modifier):
            Button { toggleModifier(modifier) } label: {
                KeyCapView(key: key, command: nil, reserved: nil, otherLayers: [], isSelected: false, isHighlighted: false,
                           isActiveModifier: layer.contains(modifier), scale: scale)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show shortcuts that use \(key.label)"))
        case .inert:
            KeyCapView(key: key, command: nil, reserved: nil, otherLayers: [], isSelected: false, isHighlighted: false, isActiveModifier: false, scale: scale)
                .opacity(0.5)
        case .key:
            let binding = key.binding(with: layer)
            let command = key.match(with: layer, in: commands)?.command
            let others = key.bindings.filter { $0.binding != binding }.compactMap { key.match(with: $0.modifiers, in: commands)?.command }
            Button { select(key) } label: {
                KeyCapView(key: key, command: command, reserved: command == nil ? binding?.reservation(in: context)?.title : nil,
                           otherLayers: others, isSelected: selectedKeyID == key.id, isHighlighted: highlightedKeyIDs.contains(key.id),
                           isActiveModifier: false, scale: scale)
            }
            .buttonStyle(.plain)
            .help(summary(key))
            .accessibilityLabel(key.name + (command.map { ", \($0.title)" } ?? ""))
            .dropDestination(for: String.self) { items, _ in
                guard let command = items.lazy.compactMap(ShortcutCommand.init(rawValue:)).first else { return false }
                return drop(command, key)
            }
        }
    }

    private func summary(_ key: VirtualKey) -> String {
        let lines = key.bindings.compactMap { entry in key.match(with: entry.modifiers, in: commands).map { "\(entry.binding.display)  \($0.command.title)" } }
        return ([key.name] + (lines.isEmpty ? [String(localized: "No shortcuts")] : lines)).joined(separator: "\n")
    }
}

private struct KeyCapView: View {
    let key: VirtualKey
    let command: ShortcutCommand?
    let reserved: String?
    /// Commands on this key under other modifier combinations.
    let otherLayers: [ShortcutCommand]
    let isSelected: Bool
    let isHighlighted: Bool
    let isActiveModifier: Bool
    let scale: CGFloat
    @State private var hovering = false

    private var fill: Color {
        if isActiveModifier { return .accentColor }
        if let command { return command.category.color.opacity(hovering ? 1 : 0.82) }
        if reserved != nil { return Color.secondary.opacity(0.3) }
        return Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.7 : 1)
    }
    private var textColor: Color { isActiveModifier || command != nil ? .white : .primary }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5 * scale)
                .fill(fill)
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
            RoundedRectangle(cornerRadius: 5 * scale)
                .strokeBorder(isSelected ? Color.accentColor : isHighlighted ? Color.primary.opacity(0.75) : Color.primary.opacity(0.12),
                              style: StrokeStyle(lineWidth: isSelected ? 2.5 : isHighlighted ? 1.5 : 0.5, dash: isHighlighted && !isSelected ? [3, 2] : []))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 2) {
                    VStack(alignment: .leading, spacing: -1) {
                        if let shifted = key.shiftedLabel { Text(verbatim: shifted).font(.system(size: max(7, 8 * scale))).opacity(0.7) }
                        Text(verbatim: key.label).font(.system(size: max(7, (key.label.count > 2 ? 9 : 11) * scale), weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 0)
                    // One dot per command on this key under other modifiers.
                    HStack(spacing: 2) {
                        ForEach(Array(otherLayers.prefix(key.width > 1 ? 4 : 3).enumerated()), id: \.offset) { _, other in
                            Circle().fill(other.category.color).frame(width: 5 * scale, height: 5 * scale)
                                .overlay(Circle().strokeBorder(Color.white.opacity(command == nil ? 0 : 0.8), lineWidth: 0.5))
                        }
                    }
                    .padding(.top, 2 * scale)
                }
                Spacer(minLength: 0)
                if let title = command?.shortTitle ?? reserved {
                    Text(verbatim: title)
                        .font(.system(size: max(7, 8.5 * scale), weight: .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .opacity(command == nil ? 0.7 : 1)
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 4 * scale)
            .padding(.vertical, 3 * scale)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Key details

/// Everything one key does in a context, under each modifier combination.
struct KeyDetailView: View {
    let key: VirtualKey?
    let context: ShortcutContext
    let commands: [ShortcutBinding: ShortcutCommand]
    let layer: ShortcutModifiers
    let selectedCommand: ShortcutCommand?
    let assign: (ShortcutBinding) -> Void
    let remove: (ShortcutBinding) -> Void
    let selectCommand: (ShortcutCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key, case .key = key.role {
                HStack {
                    Text(key.name).font(.headline)
                    Spacer()
                    let used = key.bindings.filter { key.match(with: $0.modifiers, in: commands) != nil }.count
                    Text("\(used) of \(key.bindings.count) used").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        let current = key.binding(with: layer)
                        ForEach(Array(key.bindings.enumerated()), id: \.offset) { _, entry in
                            row(entry.binding, assigned: key.match(with: entry.modifiers, in: commands), inLayer: entry.binding == current)
                        }
                    }
                }
                if let selectedCommand, selectedCommand.context == context, let binding = key.binding(with: layer),
                   key.match(with: layer, in: commands) == nil, binding.validationError(for: selectedCommand) == nil {
                    Button(String(localized: "Assign “\(selectedCommand.title)” to \(binding.display)")) { assign(binding) }
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("Key Details").font(.headline)
                Text("Click a key on the keyboard to see what it does with every combination of ⌃ ⌥ ⇧ ⌘.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    /// One modifier combination of the key, and the command its press runs, if any.
    private func row(_ binding: ShortcutBinding, assigned: (command: ShortcutCommand, binding: ShortcutBinding)?, inLayer: Bool) -> some View {
        let command = assigned?.command
        return HStack(spacing: 8) {
            Text(verbatim: binding.display)
                .font(.callout.monospaced())
                .frame(width: 72, alignment: .leading)
            if let command {
                Button { selectCommand(command) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(command.category.color).frame(width: 7, height: 7)
                        Text(verbatim: command.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(command.title)
                Button { remove(assigned?.binding ?? binding) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove this shortcut")
                    .accessibilityLabel("Remove this shortcut")
            } else if let reservation = binding.reservation(in: context) {
                Text(verbatim: reservation.title).foregroundStyle(.secondary).lineLimit(1)
                    .help(reservation.message)
                Spacer(minLength: 0)
            } else {
                Text("Unassigned").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if let selectedCommand, selectedCommand.context == context, binding.validationError(for: selectedCommand) == nil {
                    Button { assign(binding) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help(String(localized: "Assign “\(selectedCommand.title)” to \(binding.display)"))
                        .accessibilityLabel(String(localized: "Assign “\(selectedCommand.title)” to \(binding.display)"))
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(inLayer ? Color.accentColor.opacity(0.12) : .clear))
    }
}
