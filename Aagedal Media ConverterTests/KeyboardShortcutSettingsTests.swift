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
        XCTAssertTrue(ShortcutCommand.toggleDateTag.runsWhileEditingText(key("d", .control)))
        XCTAssertFalse(ShortcutCommand.moveItemsUp.runsWhileEditingText(key("up", .command)))
        XCTAssertFalse(ShortcutCommand.openCrop.runsWhileEditingText(key("c", .option)), "Option types characters")
        XCTAssertFalse(ShortcutCommand.removeSelected.runsWhileEditingText(key("delete", .command)))
        XCTAssertTrue(ShortcutCommand.nextComment.runsWhileEditingText(key("tab")))
        XCTAssertTrue(key("i", .command).isMenuKeyEquivalent)
        XCTAssertFalse(key("i", .option).isMenuKeyEquivalent)
        XCTAssertFalse(key("return", .command).isMenuKeyEquivalent)
        XCTAssertTrue(key("f5").isMenuKeyEquivalent)
    }

    func testKeyPresses() {
        XCTAssertEqual(ShortcutBinding.pressed(key: "+", modifiers: [.command, .shift]), key("=", .command))
        XCTAssertEqual(ShortcutBinding.pressed(key: "I", modifiers: .shift), key("i", .shift))
        XCTAssertEqual(ShortcutBinding.pressed(characters: " ", modifierFlags: [], specialKey: nil), key("space"))
        XCTAssertEqual(ShortcutBinding.pressed(characters: "\u{F702}", modifierFlags: .command, specialKey: .leftArrow), key("left", .command))
        XCTAssertEqual(ShortcutBinding.pressed(characters: "\u{1b}", modifierFlags: [], specialKey: nil), key("escape"))
        XCTAssertEqual(ShortcutBinding.pressed(characters: "L", modifierFlags: [.option, .shift], specialKey: nil), key("l", [.option, .shift]))
        XCTAssertNil(ShortcutBinding.pressed(characters: "", modifierFlags: [], specialKey: nil))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        XCTAssertEqual(event.flatMap { ShortcutBinding.pressed($0) }, key("return", .command))
        XCTAssertEqual(key("delete", .command).display, "⌘⌫")
        XCTAssertEqual(ShortcutModifiers.allCombinations.count, 16)
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
            XCTAssertNil(registry.menuShortcut(for: .openMetadata), "Option chords stay out of menus")
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
