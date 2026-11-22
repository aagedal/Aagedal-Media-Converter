import AppKit
import SwiftUI
import XCTest
@testable import Aagedal_Media_Converter

@MainActor
final class KeyboardShortcutSettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "KeyboardShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func key(_ key: String, _ modifiers: ShortcutModifiers = []) -> ShortcutBinding {
        ShortcutBinding(key: key, modifiers: modifiers)
    }

    // MARK: Model

    func testDefaultsAreValidAndUniqueWithinEachContext() {
        let defaults = Keymap.defaults
        for command in ShortcutCommand.allCases {
            for (slot, binding) in command.defaultBindings.enumerated() {
                XCTAssertNil(defaults.validationError(binding, for: command, slot: slot), "\(command) \(binding.display)")
            }
            XCTAssertLessThanOrEqual(command.defaultBindings.count, Keymap.slotCount)
        }
        for context in ShortcutContext.allCases {
            let bindings = ShortcutCommand.allCases.filter { $0.context == context }.flatMap(\.defaultBindings)
            XCTAssertEqual(Set(bindings).count, bindings.count, "\(context) has a shortcut on two commands")
        }
        let restored = Keymap.restoring([:])
        XCTAssertEqual(restored.keymap, defaults)
        XCTAssertEqual(restored.rejected, 0)
    }

    func testDefaultsMatchTheEarlierBuiltInShortcuts() {
        let defaults = Keymap.defaults
        XCTAssertEqual(defaults[.toggleConversion], key("return", .command))
        XCTAssertEqual(defaults[.showURLInput], key("d", .command))
        XCTAssertEqual(defaults.bindings(for: .openTrim), [key("t", .command), key("return")])
        XCTAssertEqual(defaults.bindings(for: .playFullscreen), [key("f", .command), key("space")])
        XCTAssertEqual(defaults.bindings(for: .removeSelected), [key("delete"), key("delete", .command)])
        XCTAssertEqual(defaults[.selectPreset10], key("0", .command))
        XCTAssertEqual(defaults.bindings(for: .trimTogglePlayback), [key("space"), key("k")])
        XCTAssertEqual(defaults[.trimCrop9x16], key("9", .command))
        XCTAssertEqual(defaults[.fullscreenNextItem], key("n", .command))
        XCTAssertEqual(ShortcutCommand.selectPreset10.presetIndex, 9)
        XCTAssertEqual(ShortcutCommand.trimCrop16x9.cropAspectRatio, .ratio16_9)
    }

    func testContextsKeepSeparateShortcuts() {
        let keymap = Keymap.defaults
        XCTAssertEqual(keymap.command(for: key("space"), in: .main), .playFullscreen)
        XCTAssertEqual(keymap.command(for: key("space"), in: .trim), .trimTogglePlayback)
        XCTAssertEqual(keymap.command(for: key("space"), in: .fullscreen), .fullscreenTogglePlayback)
        XCTAssertEqual(keymap.command(for: key("n", .command), in: .main), .newEncodingGroup)
        XCTAssertEqual(keymap.command(for: key("n", .command), in: .fullscreen), .fullscreenNextItem)
        // A trim-view key may reuse a main-window shortcut without a conflict.
        XCTAssertNil(keymap.validationError(key("t", .command), for: .trimToggleLoop, slot: 1))
        XCTAssertNotNil(keymap.validationError(key("l", .command), for: .trimToggleAudioMeter, slot: 1))
    }

    func testReservedShortcuts() {
        XCTAssertNotNil(key("q", .command).validationError(for: .trimToggleLoop))
        XCTAssertNotNil(key("?", [.command, .shift]).validationError(for: .resetAll), "Help is reserved by its character")
        XCTAssertNil(key("/", [.command, .shift]).validationError(for: .resetAll))
        XCTAssertNotNil(key("space", .command).validationError(for: .trimTogglePlayback))
        XCTAssertNotNil(key("left", .control).validationError(for: .trimPreviousFrame))
        // ⌘A is Select All in the main window, but the trim view's audio meter shortcut.
        XCTAssertNotNil(key("a", .command).validationError(for: .resetAll))
        XCTAssertNil(key("a", .command).validationError(for: .trimToggleAudioMeter))
        // Bare digits start timecode entry in the players.
        XCTAssertNotNil(key("5").validationError(for: .trimSetIn))
        XCTAssertNotNil(key("escape").validationError(for: .fullscreenToggleMute))
        XCTAssertNil(key("5", .option).validationError(for: .trimSetIn))
        XCTAssertNil(key("5").validationError(for: .toggleMute))
        XCTAssertEqual(key("q", .command).reservation(in: .main)?.title, String(localized: "Quit"))
    }

    func testWindowCommandsNeedModifiers() {
        XCTAssertNotNil(key("w").validationError(for: .toggleWatchFolder))
        XCTAssertNotNil(key("w", .shift).validationError(for: .toggleWatchFolder))
        XCTAssertNil(key("w", .option).validationError(for: .toggleWatchFolder))
        XCTAssertNil(key("f5").validationError(for: .toggleWatchFolder), "Function keys never reach text")
        XCTAssertNil(key("w").validationError(for: .toggleMute), "Queue commands stand aside for focused text")
        XCTAssertNil(key("w").validationError(for: .trimSetIn))
        XCTAssertNotNil(key("ab", .command).validationError(for: .resetAll))
    }

    func testTwoShortcutsPerCommand() {
        var keymap = Keymap.defaults
        let first = key("u", .command)
        let alternate = key("u", .control)
        XCTAssertNil(keymap.validationError(alternate, for: .toggleUpload, slot: 1))
        keymap.set(alternate, for: .toggleUpload, slot: 1)
        XCTAssertEqual(keymap.bindings(for: .toggleUpload), [first, alternate])
        XCTAssertEqual(keymap.command(for: alternate, in: .main), .toggleUpload)
        XCTAssertEqual(keymap.validationError(first, for: .toggleUpload, slot: 1), String(localized: "This is already the command's other shortcut."))
        XCTAssertNil(keymap.validationError(first, for: .toggleUpload, slot: 0), "A shortcut does not conflict with itself")
        XCTAssertNotNil(keymap.validationError(alternate, for: .toggleMute, slot: 1))
        // Clearing the first shortcut promotes the second.
        keymap.set(ShortcutBinding(key: ""), for: .toggleUpload, slot: 0)
        XCTAssertEqual(keymap.bindings(for: .toggleUpload), [alternate])
        keymap.unassign(alternate, in: .main)
        XCTAssertTrue(keymap.bindings(for: .toggleUpload).isEmpty)
        // A third shortcut is dropped.
        keymap.set(key("1", .control), for: .toggleUpload, slot: 0)
        keymap.set(key("2", .control), for: .toggleUpload, slot: 1)
        keymap.set(key("3", .control), for: .toggleUpload, slot: 2)
        XCTAssertEqual(keymap.bindings(for: .toggleUpload).count, 2)
    }

    func testTextEditingKeepsTypingAndNavigationKeys() {
        XCTAssertTrue(ShortcutCommand.toggleConversion.runsWhileEditingText(key("return", .command)))
        XCTAssertTrue(ShortcutCommand.cycleSort.runsWhileEditingText(key("s", .control)))
        XCTAssertFalse(ShortcutCommand.toggleDateTag.runsWhileEditingText(key("d", .control)), "⌃D deletes forward in text")
        XCTAssertFalse(ShortcutCommand.showShortcuts.runsWhileEditingText(key("k", .control)), "⌃K deletes to the line end in text")
        XCTAssertTrue(ShortcutCommand.toggleDateTag.runsWhileEditingText(key("d", [.command, .control])))
        XCTAssertFalse(ShortcutCommand.moveItemsUp.runsWhileEditingText(key("up", .command)))
        XCTAssertFalse(ShortcutCommand.openCrop.runsWhileEditingText(key("c", .option)), "Option types characters")
        XCTAssertFalse(ShortcutCommand.removeSelected.runsWhileEditingText(key("delete", .command)))
        XCTAssertTrue(ShortcutCommand.nextComment.runsWhileEditingText(key("tab")))
        XCTAssertTrue(ShortcutCommand.previousComment.runsWhileEditingText(key("tab", .shift)))
        XCTAssertFalse(ShortcutCommand.nextComment.runsWhileEditingText(key("n")), "Only Tab leaves the comment text")
        XCTAssertFalse(ShortcutCommand.previousComment.runsWhileEditingText(key("space")))
        XCTAssertTrue(key("i", .command).isMenuKeyEquivalent)
        XCTAssertTrue(key("i", .option).isMenuKeyEquivalent, "The text-editing guard keeps ⌥I for focused text")
        XCTAssertTrue(key("n", .control).isMenuKeyEquivalent)
        XCTAssertFalse(key("i", .shift).isMenuKeyEquivalent)
        XCTAssertFalse(key("return", .command).isMenuKeyEquivalent)
        XCTAssertTrue(key("f5").isMenuKeyEquivalent)
        XCTAssertFalse(key("n", .control).isSafeDuringTextEditing, "⌃N moves the insertion point down a line")
    }

    func testModifiedPlayerKeysFallBackToTheBareKey() throws {
        XCTAssertEqual(key("right", .shift).bareKeyFallback(in: .fullscreen), key("right"))
        XCTAssertEqual(key("space", .shift).bareKeyFallback(in: .trim), key("space"))
        XCTAssertEqual(key("l", .shift).bareKeyFallback(in: .fullscreen), key("l"))
        XCTAssertNil(key("l", .shift).bareKeyFallback(in: .trim), "The trim view has only ever done this for arrows and Space")
        XCTAssertNil(key("right").bareKeyFallback(in: .fullscreen), "A bare key has nothing to fall back to")
        XCTAssertNil(key("down", .command).bareKeyFallback(in: .main))
        try withDefaults { defaults in
            let registry = ShortcutRegistry(defaults: defaults)
            XCTAssertEqual(registry.bareKeyMatch([key("left", .option)], in: .fullscreen), .fullscreenPreviousFrame)
            XCTAssertEqual(registry.bareKeyMatch([key("о", .shift), key("j", .shift)], in: .fullscreen), .fullscreenPlayReverse,
                           "The U.S. key at the same position counts on non-Latin layouts")
            XCTAssertNil(registry.match([key("right", .shift)], in: .fullscreen))
        }
    }

    func testKeyPresses() {
        XCTAssertEqual(ShortcutBinding.pressed(key: "+", modifiers: [.command, .shift]), key("=", .command))
        XCTAssertEqual(ShortcutBinding.pressed(key: "I", modifiers: .shift), key("i", .shift))
        func pressed(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) -> ShortcutBinding? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
                .flatMap { ShortcutBinding.pressed($0) }
        }
        XCTAssertEqual(pressed("\r", 36, .command), key("return", .command))
        XCTAssertEqual(pressed(" ", 49), key("space"))
        XCTAssertEqual(pressed("\u{F702}", 123, .command), key("left", .command))
        XCTAssertEqual(pressed("\u{1b}", 53), key("escape"))
        XCTAssertEqual(pressed("L", 37, [.option, .shift]), key("l", [.option, .shift]))
        XCTAssertNil(pressed("", 37))
        XCTAssertEqual(key("delete", .command).display, "⌘⌫")
        XCTAssertEqual(ShortcutModifiers.allCombinations.count, 16)
    }

    func testKeyPressesOnOtherLayoutsAlsoMatchTheUSKey() throws {
        func candidates(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> [ShortcutBinding] {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
                .map { ShortcutBinding.candidates(for: $0) } ?? []
        }
        // Russian: the T key types "е".
        XCTAssertEqual(candidates("е", 17, .command), [key("е", .command), key("t", .command)])
        // French: the 1 key types "&" without Shift.
        XCTAssertEqual(candidates("&", 18, .command), [key("&", .command), key("1", .command)])
        // Latin letters keep their layout's meaning: the French A key types "q".
        XCTAssertEqual(candidates("q", 0, .option), [key("q", .option)])
        XCTAssertEqual(candidates("ø", 41, .command), [key("ø", .command)], "Keys other than letters and digits have no fallback")
        XCTAssertEqual(ShortcutBinding.candidates(typed: key("е", [.command, .shift]), keyCode: 17), [key("е", [.command, .shift]), key("t", [.command, .shift])])
        // The editor records the U.S. key, so the shortcut also works after a switch to a Latin layout.
        let russianT = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "е", charactersIgnoringModifiers: "е", isARepeat: false, keyCode: 17)
        XCTAssertEqual(russianT.flatMap { ShortcutBinding.recorded($0) }, key("t", .command))
        let russianKey = VirtualKey(id: "t", keyCode: 17, role: .key(base: "е", shifted: "е"), width: 1, label: "Е", shiftedLabel: nil)
        XCTAssertEqual(russianKey.candidates(with: .command), [key("е", .command), key("t", .command)])
        XCTAssertEqual(russianKey.binding(with: .command), key("t", .command))
        XCTAssertEqual(russianKey.match(with: .command, in: Keymap.defaults.commandsByBinding(in: .main))?.command, .openTrim,
                       "The on-screen keyboard shows ⌘T on the key that types Е")
        // Select All goes by the typed character: the AZERTY key at the U.S. A position types Q.
        XCTAssertFalse(candidates("q", 0, .command).contains(key("a", .command)))
        XCTAssertTrue(candidates("a", 12, .command).contains(key("a", .command)))
        try withDefaults { defaults in
            let registry = ShortcutRegistry(defaults: defaults)
            XCTAssertEqual(registry.match(candidates("е", 17, .command), in: .main)?.command, .openTrim)
            XCTAssertEqual(registry.match(candidates("&", 18, .command), in: .main)?.command, .selectPreset1)
        }
    }

    func testRestoringKeepsChoicesAndDropsInvalidShortcuts() {
        var keymap = Keymap.defaults
        keymap.set(key("j", .control), for: .toggleUpload, slot: 1)
        XCTAssertEqual(Array(keymap.changes(from: .defaults).keys), [ShortcutCommand.toggleUpload.rawValue])
        XCTAssertEqual(Keymap.restoring(keymap.changes(from: .defaults)).keymap, keymap)

        let restored = Keymap.restoring([
            ShortcutCommand.toggleMute.rawValue: [key("u", .command)],
            ShortcutCommand.resetAll.rawValue: [key("w"), key("q", .command), key("r", .control)],
            "main.unknownFutureCommand": [key("y", .command)],
        ])
        XCTAssertEqual(restored.keymap[.toggleMute], key("u", .command))
        XCTAssertTrue(restored.keymap.bindings(for: .toggleUpload).isEmpty, "An omitted command loses a default that a saved choice took")
        XCTAssertEqual(restored.keymap.bindings(for: .resetAll), [key("r", .control)], "A bare key and a reserved one are dropped")
        XCTAssertTrue(restored.keymap.bindings(for: .showRandomTip).isEmpty, "The saved choice keeps ⌃R")
        XCTAssertEqual(restored.rejected, 2)
        XCTAssertEqual(restored.keymap[.toggleConversion], key("return", .command), "Omitted commands keep their defaults")

        // A command whose saved shortcuts are all reserved now gets its default back.
        let reserved = Keymap.restoring([ShortcutCommand.toggleMerge.rawValue: [key("m", .command)],
                                         ShortcutCommand.resetAll.rawValue: [key("h", .command)],
                                         ShortcutCommand.toggleMute.rawValue: []])
        XCTAssertEqual(reserved.keymap.bindings(for: .toggleMerge), [key("m", .option)])
        XCTAssertEqual(reserved.keymap.bindings(for: .resetAll), ShortcutCommand.resetAll.defaultBindings)
        XCTAssertTrue(reserved.keymap.bindings(for: .toggleMute).isEmpty, "An empty list is a choice to have no shortcut")
        XCTAssertEqual(reserved.rejected, 2)
    }

    func testPlusMeansTheEqualsKey() {
        XCTAssertEqual(key("+", .command).normalized, key("=", .command))
        XCTAssertEqual(key("+", [.command, .shift]).normalized, key("=", .command))
        let restored = Keymap.restoring([ShortcutCommand.trimCropLarger.rawValue: [key("+", [.command, .option])]])
        XCTAssertEqual(restored.keymap.bindings(for: .trimCropLarger), [key("=", [.command, .option])])
        XCTAssertEqual(restored.keymap.command(for: ShortcutBinding.pressed(key: "+", modifiers: [.command, .option, .shift])!, in: .trim),
                       .trimCropLarger)
    }

    func testPresetFiles() throws {
        var keymap = Keymap.defaults
        keymap.set(key("y", .command), for: .openCapture, slot: 1)
        let preset = KeyboardPreset(name: "Shared", keymap: keymap)
        XCTAssertEqual(preset.shortcuts.count, ShortcutCommand.allCases.count)
        let data = try preset.fileData()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"format\" : \"\(KeyboardPreset.fileFormat)\""))
        let reopened = try KeyboardPreset(fileData: data)
        XCTAssertEqual(reopened, preset)
        XCTAssertEqual(reopened.resolved.keymap, keymap)
        XCTAssertThrowsError(try KeyboardPreset(fileData: Data("{}".utf8))) { error in
            guard case KeyboardPresetError.notAPreset = error else { return XCTFail("\(error)") }
        }
        var newer = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        newer["version"] = KeyboardPreset.fileVersion + 1
        XCTAssertThrowsError(try KeyboardPreset(fileData: JSONSerialization.data(withJSONObject: newer))) { error in
            guard case KeyboardPresetError.newerVersion = error else { return XCTFail("\(error)") }
        }
        // Shortcuts are written without their unused modifiers.
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(key("b", .command))) as? [String: Any])
        XCTAssertEqual(Set(written.keys), ["key", "command"])
    }

    // MARK: Registry

    func testRegistryStoresOnlyChangesAndLooksUpCommands() throws {
        try withDefaults { defaults in
            defaults.set("keep", forKey: "unrelatedPreference")
            let registry = ShortcutRegistry(defaults: defaults)
            XCTAssertEqual(registry.command(for: key("d", .command), in: .main), .showURLInput)
            XCTAssertNil(registry.set(key("g", [.control, .option]), for: .showURLInput))
            XCTAssertEqual(registry.command(for: key("g", [.control, .option]), in: .main), .showURLInput)
            XCTAssertNil(registry.command(for: key("d", .command), in: .main))
            XCTAssertNotNil(registry.set(key("q", .command), for: .openCapture))
            XCTAssertTrue(registry.isModified)

            let reopened = ShortcutRegistry(defaults: defaults)
            XCTAssertEqual(reopened.keymap, registry.keymap)
            let saved = try XCTUnwrap(defaults.data(forKey: ShortcutRegistry.storageKey))
            let changes = try JSONDecoder().decode([String: [ShortcutBinding]].self, from: saved)
            XCTAssertEqual(Array(changes.keys), [ShortcutCommand.showURLInput.rawValue])

            reopened.applyPreset(named: KeyboardPreset.builtInName)
            XCTAssertEqual(reopened.keymap, .defaults)
            XCTAssertFalse(reopened.isModified)
            XCTAssertEqual(defaults.string(forKey: "unrelatedPreference"), "keep")
        }
    }

    func testRegistryReassignsAndShowsMenuShortcuts() throws {
        try withDefaults { defaults in
            let registry = ShortcutRegistry(defaults: defaults)
            XCTAssertNotNil(registry.set(key("e", .command), for: .toggleUpload, slot: 1))
            XCTAssertNil(registry.reassign(key("e", .command), to: .toggleUpload, slot: 1))
            XCTAssertEqual(registry.bindings(for: .toggleUpload), [key("u", .command), key("e", .command)])
            XCTAssertTrue(registry.bindings(for: .toggleAutoEncode).isEmpty)
            XCTAssertEqual(registry.menuShortcut(for: .importFiles), KeyboardShortcut("i", modifiers: .command))
            XCTAssertEqual(registry.menuShortcut(for: .openMetadata), KeyboardShortcut("i", modifiers: .option))
            // The text-editing guard leaves ⌘I to the menu but hands ⌥I to focused text.
            XCTAssertEqual(registry.menuBinding(matching: [key("i", .option)]), key("i", .option))
            XCTAssertFalse(key("i", .option).isSafeDuringTextEditing)
            XCTAssertTrue(key("i", .command).isSafeDuringTextEditing)
            XCTAssertNil(registry.menuBinding(matching: [key("u", .option)]))
        }
    }

    func testModifiedFollowsTheActivePreset() throws {
        try withDefaults { defaults in
            let registry = ShortcutRegistry(defaults: defaults)
            XCTAssertFalse(registry.isModified)
            XCTAssertNil(registry.set(key("y", .command), for: .openCapture, slot: 1))
            XCTAssertTrue(registry.isModified)
            XCTAssertNil(registry.savePreset(named: "Mine"))
            XCTAssertFalse(registry.isModified)
            XCTAssertNil(registry.renamePreset("Mine", to: "Ours"))
            XCTAssertFalse(registry.isModified)
            registry.deletePreset(named: "Ours")
            XCTAssertTrue(registry.isModified, "The keymap now differs from the built-in preset")
        }
    }

    func testEarlierMainWindowShortcutsMigrate() throws {
        try withDefaults { defaults in
            let legacy: [String: [String: UInt]] = [
                "download": ["keyCode": 5, "modifierBits": NSEvent.ModifierFlags([.control, .option]).rawValue],
                "conversion": ["keyCode": 99, "modifierBits": NSEvent.ModifierFlags.command.rawValue],
            ]
            defaults.set(try JSONEncoder().encode(legacy), forKey: ShortcutRegistry.legacyStorageKey)
            let registry = ShortcutRegistry(defaults: defaults)
            XCTAssertEqual(registry.bindings(for: .showURLInput), [key("g", [.control, .option])])
            XCTAssertEqual(registry.bindings(for: .toggleConversion), [key("return", .command)], "Unknown key codes keep the default")
            XCTAssertNil(defaults.object(forKey: ShortcutRegistry.legacyStorageKey))
            XCTAssertEqual(ShortcutRegistry(defaults: defaults).keymap, registry.keymap)
        }
        try withDefaults { defaults in
            defaults.set(Data("invalid JSON".utf8), forKey: ShortcutRegistry.legacyStorageKey)
            XCTAssertEqual(ShortcutRegistry(defaults: defaults).keymap, .defaults)
        }
        try withDefaults { defaults in
            // Earlier versions allowed ⌘M, which is now Minimize; Merge keeps its default.
            let legacy: [String: [String: UInt]] = ["merge": ["keyCode": 46, "modifierBits": NSEvent.ModifierFlags.command.rawValue]]
            defaults.set(try JSONEncoder().encode(legacy), forKey: ShortcutRegistry.legacyStorageKey)
            XCTAssertEqual(ShortcutRegistry(defaults: defaults).bindings(for: .toggleMerge), [key("m", .option)])
        }
    }

    func testRegistryPresets() throws {
        try withDefaults { defaults in
            let registry = ShortcutRegistry(defaults: defaults)
            XCTAssertNotNil(registry.savePreset(named: KeyboardPreset.builtInName))
            XCTAssertNotNil(registry.savePreset(named: "  "))
            XCTAssertNil(registry.set(key("y", .command), for: .openCapture, slot: 1))
            XCTAssertNil(registry.savePreset(named: "Editing"))
            XCTAssertEqual(registry.activePresetName, "Editing")
            XCTAssertFalse(registry.isModified)

            registry.applyPreset(named: KeyboardPreset.builtInName)
            XCTAssertEqual(registry.keymap, .defaults)
            registry.applyPreset(named: "Editing")
            XCTAssertEqual(registry.bindings(for: .openCapture).last, key("y", .command))

            XCTAssertNil(registry.renamePreset("Editing", to: "Cutting"))
            XCTAssertEqual(registry.activePresetName, "Cutting")
            let imported = registry.importPreset(KeyboardPreset(name: "Cutting", keymap: .defaults))
            XCTAssertEqual(imported.name, "Cutting 2")
            XCTAssertEqual(registry.keymap, .defaults)

            let reopened = ShortcutRegistry(defaults: defaults)
            XCTAssertEqual(reopened.presets.map(\.name), ["Cutting", "Cutting 2"])
            XCTAssertEqual(reopened.activePresetName, "Cutting 2")
            reopened.deletePreset(named: "Cutting 2")
            XCTAssertTrue(reopened.isBuiltInPresetActive)
        }
    }
}
