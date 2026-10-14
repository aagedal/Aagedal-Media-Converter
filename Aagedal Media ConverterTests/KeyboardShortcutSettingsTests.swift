import AppKit
import XCTest
@testable import Aagedal_Media_Converter

final class KeyboardShortcutSettingsTests: XCTestCase {
    private func withSettings(_ body: (KeyboardShortcutSettings) throws -> Void) throws {
        let name = "KeyboardShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(KeyboardShortcutSettings(defaults: defaults))
    }

    func testBindingsPersistAndRestoreWithoutChangingOtherPreferences() throws {
        try withSettings { settings in
            settings.defaults.set("keep", forKey: "unrelatedPreference")
            let custom = ShortcutBinding(keyCode: 5, modifiers: [.control, .option])
            settings.set(custom, for: .download)
            let reopened = KeyboardShortcutSettings(defaults: settings.defaults)
            XCTAssertEqual(reopened.binding(for: .download), custom)
            XCTAssertEqual(reopened.binding(for: .conversion), MainWindowShortcut.conversion.defaultBinding)
            reopened.reset()
            XCTAssertEqual(settings.binding(for: .download), MainWindowShortcut.download.defaultBinding)
            XCTAssertEqual(settings.defaults.string(forKey: "unrelatedPreference"), "keep")
        }
    }

    func testDefaultsRemainReservedAfterRemapping() throws {
        try withSettings { settings in
            let custom = ShortcutBinding(keyCode: 5, modifiers: [.control, .option])
            settings.set(custom, for: .download)
            XCTAssertEqual(settings.conflict(for: custom, action: .capture), .download)
            XCTAssertEqual(settings.conflict(for: MainWindowShortcut.download.defaultBinding, action: .capture), .download)
            settings.set(custom, for: .capture)
            XCTAssertEqual(settings.binding(for: .capture), MainWindowShortcut.capture.defaultBinding)
            settings.set(MainWindowShortcut.download.defaultBinding, for: .download)
            XCTAssertEqual(settings.binding(for: .download), MainWindowShortcut.download.defaultBinding)
            XCTAssertNil(settings.defaults.data(forKey: KeyboardShortcutSettings.storageKey))
        }
    }

    func testInvalidStorageAndUnmodifiedKeysFallBackSafely() throws {
        try withSettings { settings in
            settings.defaults.set(Data("invalid JSON".utf8), forKey: KeyboardShortcutSettings.storageKey)
            XCTAssertEqual(settings.binding(for: .download), MainWindowShortcut.download.defaultBinding)
            settings.set(ShortcutBinding(keyCode: 5, modifiers: []), for: .download)
            XCTAssertEqual(settings.binding(for: .download), MainWindowShortcut.download.defaultBinding)
            XCTAssertFalse(ShortcutBinding(keyCode: 53, modifiers: .command).isValid)
            let invalid = ["download": ShortcutBinding(keyCode: 5, modifiers: .shift)]
            settings.defaults.set(try JSONEncoder().encode(invalid), forKey: KeyboardShortcutSettings.storageKey)
            XCTAssertEqual(settings.binding(for: .download), MainWindowShortcut.download.defaultBinding)
        }
    }

    func testMatchingIgnoresCapsLockButRequiresExactCommandModifiers() throws {
        let binding = MainWindowShortcut.download.defaultBinding
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "d",
                charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        }
        XCTAssertTrue(binding.matches(try event([.command, .capsLock])))
        XCTAssertFalse(binding.matches(try event([.command, .shift])))
        XCTAssertFalse(binding.matches(try event([])))
    }
}
