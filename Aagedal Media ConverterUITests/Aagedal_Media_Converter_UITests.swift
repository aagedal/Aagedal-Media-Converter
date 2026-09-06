//
//  Aagedal_VideoLoop_Converter_2_0UITests.swift
//  Aagedal VideoLoop Converter 2.0UITests
//
//  Created by Truls Aagedal on 30/06/2024.
//

import XCTest

final class Aagedal_Media_Converter_UITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesWithEmptyQueue() throws {
        launchApp()
        defer { app.terminate() }

        XCTAssertTrue(element("queue.empty").waitForExistence(timeout: 10))
        XCTAssertTrue(element("toolbar.import").exists)
        XCTAssertTrue(element("toolbar.preset").exists)
        XCTAssertTrue(element("toolbar.settings").exists)
        XCTAssertEqual(element("toolbar.conversion").label, "Start Conversion")
    }

    @MainActor
    func testHiddenDefaultPresetStillDisplaysItsSelectionInBothLanguages() throws {
        for (language, locale) in [("en", "en_US"), ("nb", "nb_NO")] {
            launchApp(language: language, locale: locale, additionalArguments: ["-videoLoopVisible", "NO"])
            defer { app.terminate() }
            XCTAssertTrue(element("queue.empty").waitForExistence(timeout: 10))
            XCTAssertTrue(waitForValue("VideoLoop", of: element("toolbar.preset"), timeout: 5))
            app.activate()
            attachWindowScreenshot(named: "Hidden active preset - \(language)")
            app.terminate()
        }
    }

    @MainActor
    func testDescriptivePresetNamesInBothLanguages() throws {
        for (language, locale, prefixes) in [
            ("en", "en_US", ["VideoLoop with sound", "Stream Copy", "Animated Still (", "Audio Only (", "Image Sequence ("]),
            ("nb", "nb_NO", ["VideoLoop med lyd", "Strømkopiering", "Animert stillbilde (", "Kun lyd (", "Bildesekvens ("])
        ] {
            launchApp(language: language, locale: locale)
            defer { app.terminate() }
            XCTAssertTrue(element("toolbar.settings").waitForExistence(timeout: 10))
            app.activate()
            element("toolbar.settings").click()
            XCTAssertTrue(element("settings.root").waitForExistence(timeout: 10))
            for pane in ["presets", "encoding"] {
                let identifier = "settings.tab.\(pane)"
                element(identifier).click()
                let row = app.outlineRows.containing(.any, identifier: identifier).firstMatch
                XCTAssertTrue(waitForSelection(of: row, timeout: 5))
                if pane == "presets" {
                    for prefix in prefixes {
                        let name = app.staticTexts.matching(NSPredicate(
                            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix
                        )).firstMatch
                        XCTAssertTrue(name.exists, "Missing localized preset name: \(prefix)")
                    }
                }
                attachWindowScreenshot(named: "Localized preset names - \(language) - \(pane)")
            }
            app.terminate()
        }
    }

    @MainActor
    func testOpensSettingsAndMovesBetweenPanes() throws {
        launchApp()
        defer { app.terminate() }

        let settingsButton = element("toolbar.settings")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()

        let settingsRoot = element("settings.root")
        XCTAssertTrue(settingsRoot.waitForExistence(timeout: 10))
        let generalTab = element("settings.tab.general")
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5))
        XCTAssertEqual(settingsRoot.value as? String, "general")
        XCTAssertEqual(element("settings.general.revealOutput").label, "Show in Finder")
        XCTAssertEqual(element("settings.general.chooseOutput").label, "Change default output folder")

        element("settings.tab.screenshots").click()
        XCTAssertEqual(settingsRoot.value as? String, "screenshots")
        XCTAssertEqual(element("settings.screenshots.reveal").label, "Show in Finder")
        XCTAssertEqual(element("settings.screenshots.chooseFolder").label, "Change screenshot folder")
        XCTAssertEqual(element("settings.screenshots.resetFolder").label, "Reset to Downloads")
        for label in ["8-bit sources", "10-bit sources", ">10-bit sources", "Alpha channel"] {
            XCTAssertTrue(app.popUpButtons[label].exists, "Missing accessible screenshot picker: \(label)")
        }

        let presetsTab = element("settings.tab.presets")
        XCTAssertTrue(presetsTab.exists)
        presetsTab.click()
        XCTAssertEqual(settingsRoot.value as? String, "presets")

        let metadataTab = element("settings.tab.metadata")
        metadataTab.click()
        XCTAssertEqual(settingsRoot.value as? String, "metadata")
    }

    @MainActor
    func testMainWindowAndEverySettingsPaneInBothLanguages() throws {
        let panes = [
            ("general", "General", "Generelt"),
            ("encoding", "Encoding Groups", "Kodingsgrupper"),
            ("fileNames", "File Names", "Filnavn"),
            ("metadata", "Metadata", "Metadata"),
            ("presets", "Presets", "Forhåndsinnstillinger"),
            ("screenshots", "Screenshots", "Skjermbilder"),
            ("screenCapture", "Screen Capture", "Skjermopptak"),
            ("waveform", "Audio Waveform", "Lydbølge"),
            ("watchFolder", "Watch Folder", "Watch Folder"),
            ("ytdlp", "Downloads", "Nedlastinger"),
            ("upload", "Upload", "Opplasting"),
            ("whisper", "Transcription", "Transkripsjon"),
            ("ocr", "OCR", "OCR"),
            ("analytics", "Analytics", "Analyse"),
            ("sync", "Sync", "Synkronisering"),
            ("updates", "Updates", "Oppdateringer"),
            ("shortcuts", "Shortcuts", "Snarveier"),
            ("tools", "Tool Diagnostics", "Verktøydiagnostikk")
        ]
        for (language, locale) in [("en", "en_US"), ("nb", "nb_NO")] {
            launchApp(language: language, locale: locale)
            defer { app.terminate() }
            XCTAssertTrue(element("queue.empty").waitForExistence(timeout: 10))
            attachWindowScreenshot(named: "Locale audit - \(language) - main")
            app.activate()
            element("toolbar.settings").click()
            let root = element("settings.root")
            if !root.waitForExistence(timeout: 3) {
                // Desktop focus can consume the first click. Retry once, then
                // still require the real Settings window and sidebar selection.
                app.activate()
                element("toolbar.settings").click()
            }
            XCTAssertTrue(root.waitForExistence(timeout: 10))

            for (identifier, english, norwegian) in panes {
                let tab = element("settings.tab.\(identifier)")
                XCTAssertTrue(tab.exists)
                let expectedLabel = language == "en" ? english : norwegian
                // AppKit static text exposes its spoken content as a value;
                // other SwiftUI accessibility representations use the label.
                XCTAssertTrue(
                    tab.label == expectedLabel || tab.value as? String == expectedLabel,
                    "Missing localized sidebar name: \(expectedLabel). \(tab.debugDescription)"
                )
                let row = app.outlineRows.containing(.any, identifier: "settings.tab.\(identifier)").firstMatch
                app.activate()
                tab.click()
                if !waitForSelection(of: row, timeout: 3) {
                    app.activate()
                    tab.click()
                }
                XCTAssertTrue(waitForSelection(of: row, timeout: 5))
                attachWindowScreenshot(named: "Locale audit - \(language) - \(identifier)")
            }
            app.terminate()
        }
    }

    @MainActor
    private func attachWindowScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testScreenCaptureSettingsExposeBroadcastRatesInBothLanguages() throws {
        for (language, locale, labels) in [
            ("en", "en_US", ["Auto (Display)", "25 fps (PAL)", "29.97 fps (NTSC)", "50 fps (PAL)", "59.94 fps (NTSC)", "60 fps"]),
            ("nb", "nb_NO", ["Automatisk (skjerm)", "25 b/s (PAL)", "29,97 b/s (NTSC)", "50 b/s (PAL)", "59,94 b/s (NTSC)", "60 b/s"])
        ] {
            launchApp(language: language, locale: locale)
            defer { app.terminate() }
            let settingsButton = element("toolbar.settings")
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
            settingsButton.click()
            let captureTab = element("settings.tab.screenCapture")
            XCTAssertTrue(captureTab.waitForExistence(timeout: 5))
            captureTab.click()
            let picker = element("capture.frameRate")
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Screen Capture Settings - \(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            picker.click()
            for label in labels {
                XCTAssertTrue(app.menuItems[label].exists, "Missing frame rate: \(label)")
            }
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
    }

    @MainActor
    func testToolDiagnosticsInBothLanguages() throws {
        for (language, locale, checkLabel) in [
            ("en", "en_US", "Check Tools"),
            ("nb", "nb_NO", "Kontroller verktøy")
        ] {
            launchApp(language: language, locale: locale)
            defer { app.terminate() }
            XCTAssertTrue(element("toolbar.settings").waitForExistence(timeout: 10))
            element("toolbar.settings").click()
            let toolsTab = element("settings.tab.tools")
            XCTAssertTrue(toolsTab.waitForExistence(timeout: 5))
            toolsTab.click()
            let check = element("settings.tools.check")
            XCTAssertTrue(check.waitForExistence(timeout: 5))
            XCTAssertEqual(check.label, checkLabel)
            attachWindowScreenshot(named: "Tool Diagnostics - \(language)")
            check.click()
            XCTAssertTrue(waitForEnabled(true, of: check, timeout: 90))
            for id in ["whisper-model", "parakeet-model", "ffmpeg", "bmxtranswrap", "mxf2raw", "raw2bmx", "asdcp-wrap", "avmenc", "avmdec", "parakeet"] {
                XCTAssertTrue(element("settings.tools.\(id)").exists)
            }
            attachWindowScreenshot(named: "Tool Diagnostics results - \(language)")
            app.terminate()
        }
    }

    @MainActor
    func testImportsGeneratedFixtureAndSelectsPreset() throws {
        launchApp(generatedFixture: true)
        defer { terminateAndCleanFixtures() }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        XCTAssertEqual(queueItem.label, "ui-test-fixture.mp4")
        XCTAssertEqual(queueItem.value as? String, "waiting")
        XCTAssertFalse(element("queue.empty").exists)

        let presetPicker = element("toolbar.preset")
        XCTAssertTrue(presetPicker.waitForExistence(timeout: 5))
        app.activate()
        presetPicker.click()

        let h264Preset = app.menuItems["H.264 / AVC"]
        if !h264Preset.waitForExistence(timeout: 2) {
            // A floating window from another app can occasionally steal the first
            // menu click on macOS. Reactivate and retry the interaction once.
            app.activate()
            presetPicker.click()
        }
        XCTAssertTrue(h264Preset.waitForExistence(timeout: 5))
        h264Preset.click()
        XCTAssertEqual(presetPicker.value as? String, "H.264 / AVC")
    }

    @MainActor
    func testStartsAndCancelsConversion() throws {
        launchApp(
            generatedFixture: true,
            defaultPreset: "H.264 / AVC",
            realtimeInput: true
        )
        defer { terminateAndCleanFixtures() }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        XCTAssertEqual(queueItem.value as? String, "waiting")

        let conversionButton = element("toolbar.conversion")
        XCTAssertTrue(conversionButton.waitForExistence(timeout: 5))
        XCTAssertTrue(conversionButton.isEnabled)
        conversionButton.click()

        XCTAssertTrue(waitForValue("converting", of: queueItem, timeout: 10))
        XCTAssertTrue(waitForLabel("Cancel Conversion", of: conversionButton, timeout: 5))
        conversionButton.click()

        XCTAssertTrue(waitForValue("cancelled", of: queueItem, timeout: 10))
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
    }

    @MainActor
    func testExposesSuccessfulConversionResult() throws {
        launchApp(
            generatedFixture: true,
            defaultPreset: "H.264 / AVC"
        )
        defer { terminateAndCleanFixtures() }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        let conversionButton = element("toolbar.conversion")
        XCTAssertTrue(conversionButton.waitForExistence(timeout: 5))
        conversionButton.click()

        XCTAssertTrue(waitForValue("done", of: queueItem, timeout: 20))
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
    }

    @MainActor
    func testExposesFailedConversionAndError() throws {
        launchApp(
            generatedFixture: true,
            defaultPreset: "H.264 / AVC",
            removeFixtureAfterImport: true
        )
        defer { terminateAndCleanFixtures() }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        XCTAssertEqual(queueItem.label, "ui-test-fixture.mp4")
        let conversionButton = element("toolbar.conversion")
        XCTAssertTrue(conversionButton.waitForExistence(timeout: 5))
        conversionButton.click()

        XCTAssertTrue(waitForValue("failed", of: queueItem, timeout: 20))
        let errorDetail = element("queue.item.detail")
        XCTAssertTrue(errorDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel("Cannot access input file", of: errorDetail, timeout: 5))
        let detailsButton = element("queue.item.errorDetails")
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 5))
        app.activate()
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: detailsButton)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
        detailsButton.click()
        let expandedDetails = element("queue.errorDetails.text")
        XCTAssertTrue(expandedDetails.waitForExistence(timeout: 5))
        XCTAssertTrue((expandedDetails.value as? String ?? "").contains("Cannot access input file"))
        XCTAssertTrue(element("queue.errorDetails.copy").isEnabled)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Queue error details"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    @MainActor
    private func launchApp(
        generatedFixture: Bool = false,
        defaultPreset: String = "VideoLoop",
        realtimeInput: Bool = false,
        removeFixtureAfterImport: Bool = false,
        language: String = "en",
        locale: String = "en_US",
        additionalArguments: [String] = []
    ) {
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-ffmpegBinarySource", "app", "-defaultExportPreset", defaultPreset]
        app.launchArguments += additionalArguments
        app.launchEnvironment["AMC_UI_TEST_SESSION"] = "1"
        if generatedFixture {
            app.launchArguments += [
                "-saveNextToOriginal", "NO",
            ]
            app.launchEnvironment["AMC_UI_TEST_GENERATED_FIXTURE"] = "1"
            if removeFixtureAfterImport {
                app.launchEnvironment["AMC_UI_TEST_REMOVE_FIXTURE_AFTER_IMPORT"] = "1"
            }
            if realtimeInput {
                app.launchEnvironment["AMC_UI_TEST_REALTIME_INPUT"] = "1"
            }
        }
        app.launch()
    }

    @MainActor
    private func terminateAndCleanFixtures() {
        app.terminate()
        // XCTest may force-terminate the app without willTerminateNotification.
        // Relaunch for synchronous app-owned cleanup; the runner never accesses
        // the app's private fixture files or output directory.
        app.launchEnvironment.removeValue(forKey: "AMC_UI_TEST_GENERATED_FIXTURE")
        app.launchEnvironment["AMC_UI_TEST_CLEANUP_FIXTURES"] = "1"
        app.launch()
        app.terminate()
    }

    @MainActor
    private func waitForSelection(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForValue(_ value: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForLabel(_ label: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForEnabled(_ enabled: Bool, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "enabled == %@", NSNumber(value: enabled))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
