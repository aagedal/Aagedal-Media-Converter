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
    func testDamagedScheduleRecoveryInBothLanguages() throws {
        for (language, locale, warningText, cancelTitle) in [
            ("en", "en_US", "Saved download schedules could not be read.", "Cancel"),
            ("nb", "nb_NO", "Lagrede nedlastingsplaner kunne ikke leses.", "Avbryt")
        ] {
            launchApp(language: language, locale: locale, damagedSchedules: true)
            defer { app.terminate() }
            app.activate()
            let warning = element("scheduledDownloadStorageWarning")
            XCTAssertTrue(warning.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(
                format: "label == %@ OR value == %@", warningText, warningText
            )).firstMatch.exists)
            attachWindowScreenshot(named: "Schedule storage warning - \(language)")
            element("scheduledDownloadStorageResetButton").click()
            let confirmation = element("scheduledDownloadStorageResetConfirmButton")
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            attachWindowScreenshot(named: "Schedule storage reset confirmation - \(language)")
            app.sheets.firstMatch.buttons[cancelTitle].click()
            XCTAssertTrue(warning.exists)
            element("scheduledDownloadStorageResetButton").click()
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            confirmation.click()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: warning)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
            XCTAssertTrue(element("queue.empty").exists)
            app.terminate()
        }
    }

    @MainActor
    func testDamagedHistoryRecoveryInBothLanguages() throws {
        for (language, locale, warningText, cancelTitle) in [
            ("en", "en_US", "Saved download history could not be read.", "Cancel"),
            ("nb", "nb_NO", "Lagret nedlastingshistorikk kunne ikke leses.", "Avbryt")
        ] {
            launchApp(language: language, locale: locale, damagedHistory: true)
            defer { app.terminate() }
            app.activate()
            let warning = element("downloadHistoryStorageWarning")
            XCTAssertTrue(warning.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(
                format: "label == %@ OR value == %@", warningText, warningText
            )).firstMatch.exists)
            let optionLabels = language == "nb"
                ? ["Ta opp fra starten", "Kun lyd", "Konverter", "Opplasting"]
                : ["Record from start", "Audio only", "Encode", "Upload"]
            for label in optionLabels {
                XCTAssertTrue(app.buttons[label].exists, "Missing localized download option: \(label)")
            }
            attachWindowScreenshot(named: "History storage warning - \(language)")
            element("downloadHistoryStorageResetButton").click()
            let confirmation = element("downloadHistoryStorageResetConfirmButton")
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            attachWindowScreenshot(named: "History storage reset confirmation - \(language)")
            app.sheets.firstMatch.buttons[cancelTitle].click()
            XCTAssertTrue(warning.exists)
            element("downloadHistoryStorageResetButton").click()
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            confirmation.click()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: warning)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
            app.terminate()
        }
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
    func testOutputFolderErrorsPreserveLocationInBothLanguages() throws {
        for (language, locale, cleanupPrefix, unavailablePrefix) in [
            ("en", "en_US", "Automatic cleanup", "The output folder is unavailable"),
            ("nb", "nb_NO", "Automatisk opprydding", "Utdatamappen er utilgjengelig")
        ] {
            let missingFolder = "/private/tmp/AMC-UITest-Missing-\(UUID().uuidString)"
            launchApp(language: language, locale: locale, additionalArguments: [
                "-outputFolder", missingFolder, "-saveNextToOriginal", "NO",
                "-autoDeleteOldEncodes", "YES", "-autoDeleteOldEncodesDays", "7"
            ])
            defer { app.terminate() }
            let settingsButton = element("toolbar.settings")
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
            settingsButton.click()
            let cleanupError = element("settings.general.cleanupError")
            XCTAssertTrue(cleanupError.waitForExistence(timeout: 10))
            attachWindowScreenshot(named: "Output cleanup error - \(language)")
            // Selectable SwiftUI text exposes its contents as an accessibility value.
            let cleanupText = cleanupError.value as? String ?? cleanupError.label
            XCTAssertTrue(cleanupText.hasPrefix(cleanupPrefix), cleanupText)
            element("settings.general.retryCleanup").click()
            XCTAssertTrue(cleanupError.exists)
            XCTAssertTrue(app.staticTexts[missingFolder].exists)
            element("settings.general.revealOutput").click()
            let alert = app.sheets.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", unavailablePrefix, unavailablePrefix)).firstMatch.exists)
            attachWindowScreenshot(named: "Output location error - \(language)")
            alert.buttons["OK"].click()
            XCTAssertTrue(app.staticTexts[missingFolder].exists)
            app.terminate()
        }
    }

    @MainActor
    func testWatchFolderUnavailableRevealPreservesLocationInBothLanguages() throws {
        for (language, locale, unavailablePrefix) in [
            ("en", "en_US", "The watch folder is unavailable"),
            ("nb", "nb_NO", "Overvåkingsmappen er utilgjengelig")
        ] {
            let missingFolder = "/private/tmp/AMC-UITest-Missing-Watch-\(UUID().uuidString)"
            launchApp(language: language, locale: locale, additionalArguments: [
                "-watchFolderPath", missingFolder,
                "-watchFolderModeEnabled", "NO", "-watchFolderAutoActivateOnLaunch", "NO"
            ])
            defer { app.terminate() }
            XCTAssertTrue(element("toolbar.settings").waitForExistence(timeout: 10))
            app.activate()
            element("toolbar.settings").click()
            XCTAssertTrue(element("settings.root").waitForExistence(timeout: 10))
            element("settings.tab.watchFolder").click()
            let reveal = element("settings.watchFolder.reveal")
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[missingFolder].exists)
            // Retry after dismissal: a missing volume must retain its saved path
            // and continue to offer reauthorization/reconnection guidance.
            for attempt in 1...2 {
                reveal.click()
                let alert = app.sheets.firstMatch
                XCTAssertTrue(alert.waitForExistence(timeout: 5))
                XCTAssertTrue(alert.staticTexts.containing(NSPredicate(
                    format: "label BEGINSWITH %@ OR value BEGINSWITH %@", unavailablePrefix, unavailablePrefix
                )).firstMatch.exists)
                if attempt == 1 {
                    attachWindowScreenshot(named: "Watch folder location error - \(language)")
                }
                alert.buttons["OK"].click()
                XCTAssertTrue(app.staticTexts[missingFolder].exists)
                XCTAssertTrue(reveal.exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testWatchFolderStartupFailureRemainsVisibleAfterModeDisablesInBothLanguages() throws {
        for (language, locale, unavailablePrefix) in [
            ("en", "en_US", "The watch folder is unavailable"),
            ("nb", "nb_NO", "Overvåkingsmappen er utilgjengelig")
        ] {
            let missingFolder = "/private/tmp/AMC-UITest-Missing-Watch-\(UUID().uuidString)"
            launchApp(language: language, locale: locale, additionalArguments: [
                "-watchFolderPath", missingFolder,
                "-watchFolderAutoActivateOnLaunch", "YES"
            ])
            defer { app.terminate() }
            let alert = app.sheets.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            XCTAssertTrue(alert.staticTexts.containing(NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@", unavailablePrefix, unavailablePrefix
            )).firstMatch.exists)
            attachWindowScreenshot(named: "Watch folder startup error - \(language)")
            alert.buttons["OK"].click()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
            element("toolbar.settings").click()
            XCTAssertTrue(element("settings.root").waitForExistence(timeout: 10))
            element("settings.tab.watchFolder").click()
            XCTAssertTrue(app.staticTexts[missingFolder].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testMainWindowAndEverySettingsPaneInBothLanguages() throws {
        executionTimeAllowance = 300
        let panes = [
            ("general", "General", "Generelt"),
            ("agentAccess", "Agent Access", "Agenttilgang"),
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
    func testAgentAccessOptInAndConnectionDiagnosticInBothLanguages() throws {
        for (language, locale, ready, disabled) in [
            ("en", "en_US", "Ready", "Disabled"),
            ("nb", "nb_NO", "Klar", "Deaktivert")
        ] {
            launchApp(
                language: language,
                locale: locale,
                resetAgentAccess: true
            )
            defer { app.terminate() }

            XCTAssertTrue(element("toolbar.settings").waitForExistence(timeout: 10))
            app.activate()
            element("toolbar.settings").click()
            XCTAssertTrue(element("settings.root").waitForExistence(timeout: 10))
            let agentAccessTab = element("settings.tab.agentAccess")
            let agentAccessRow = app.outlineRows.containing(
                .any,
                identifier: "settings.tab.agentAccess"
            ).firstMatch
            agentAccessTab.click()
            if !waitForSelection(of: agentAccessRow, timeout: 3) {
                app.activate()
                agentAccessTab.click()
            }
            XCTAssertTrue(waitForSelection(of: agentAccessRow, timeout: 5))

            let accessToggle = element("settings.agentAccess.enabled")
            let status = element("settings.agentAccess.connectionStatus")
            let connectionTest = element("settings.agentAccess.test")
            XCTAssertTrue(accessToggle.waitForExistence(timeout: 5))
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertFalse(connectionTest.isEnabled)

            accessToggle.click()
            XCTAssertTrue(waitForEnabled(true, of: connectionTest, timeout: 10))
            XCTAssertTrue(
                waitForLabelOrValue(ready, of: status, timeout: 10),
                status.debugDescription
            )
            connectionTest.click()
            XCTAssertTrue(
                waitForLabelOrValue(ready, of: status, timeout: 10),
                status.debugDescription
            )
            XCTAssertTrue(element("settings.agentAccess.configuration").exists)
            let clientPicker = element("settings.agentAccess.client")
            let setup = element("settings.agentAccess.configuration")
            XCTAssertTrue(clientPicker.exists)
            for client in ["Claude Desktop", "Claude Code", "Codex", "OpenCode"] {
                let option = clientPicker.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", client)).firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 5))
            }
            XCTAssertTrue(waitForTextContaining("mcpServers", of: setup, timeout: 5))
            attachWindowScreenshot(named: "Agent Access ready - \(language)")

            accessToggle.click()
            XCTAssertTrue(waitForLabelOrValue(disabled, of: status, timeout: 5))
            XCTAssertFalse(connectionTest.isEnabled)
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
    func testNativePreviewSeekScreenshotAndReopen() throws {
        try exercisePreview(container: "mp4", expectedBackend: "AVPlayer")
    }

    @MainActor
    func testMPVPreviewSeekScreenshotAndReopen() throws {
        try exercisePreview(container: "mkv", expectedBackend: "MPV")
    }

    @MainActor
    func testStitchingRippleShortcutsAndSelectionReset() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("group.edit").waitForExistence(timeout: 30))
        element("group.edit").click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        let timeline = element("group.timeline")
        let timecode = element("stitching.timecode")
        func totalFrames() -> Int {
            let text = (timecode.value as? String) ?? timecode.label
            let parts = text.components(separatedBy: " / ").last!.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 4 else { XCTFail("Unexpected timecode: \(text)"); return -1 }
            return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * 24 + parts[3]
        }
        element("stitching.fit").click()
        XCTAssertEqual(totalFrames(), 96)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.05)).click()
        app.typeKey("q", modifierFlags: [])
        let afterQ = totalFrames()
        XCTAssertGreaterThan(afterQ, 48)
        XCTAssertLessThan(afterQ, 96)
        element("stitching.fit").click()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.05)).click()
        app.typeKey("w", modifierFlags: [])
        XCTAssertLessThan(totalFrames(), afterQ)
        element("stitching.fit").click()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35)).click()
        XCUIElement.perform(withKeyModifiers: .shift) {
            timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)).click()
        }
        element("stitching.resetTrim").click()
        XCTAssertEqual(totalFrames(), 288, "Both six-second sources should be fully restored")
    }

    @MainActor
    func testStitchingKeyframeMarkersDoNotRequireSnapping() throws {
        launchApp(generatedFixture: true, defaultPreset: "Stream Copy", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("group.edit").waitForExistence(timeout: 30))
        element("group.edit").click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        element("stitching.fit").click()
        let snap = app.checkBoxes["Snap trims and ranges to keyframes"]
        XCTAssertTrue(snap.exists, app.debugDescription)
        XCTAssertEqual(String(describing: snap.value ?? ""), "0")
        let markers = app.descendants(matching: .any).matching(identifier: "stitching.keyframeMarkers")
        let visibleMarkers = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            markers.allElementsBoundByIndex.contains { (Int($0.label.components(separatedBy: ": ").last ?? "") ?? 0) > 0 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleMarkers], timeout: 30), .completed,
                       "Stream Copy must show candidate keyframes while free trimming remains enabled")
        let info = element("stitching.timelineInfo")
        XCTAssertTrue(info.exists)
        XCTAssertFalse(element("stitching.requestedCut").exists)
        info.click()
        XCTAssertTrue(element("stitching.requestedCut").waitForExistence(timeout: 5))
        XCTAssertTrue(element("stitching.requestedEnd").waitForExistence(timeout: 5))
        XCTAssertTrue(element("stitching.seekEstimate").waitForExistence(timeout: 5))
        XCTAssertTrue(element("stitching.streamCopyBoundaryGuidance").exists)
        info.click()
        let timecode = element("stitching.timecode")
        let duration = (timecode.value as? String) ?? timecode.label
        snap.click()
        XCTAssertEqual(String(describing: snap.value ?? ""), "1")
        info.click()
        XCTAssertTrue(element("stitching.requestedCut").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("stitching.requestedEnd").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("stitching.seekEstimate").waitForNonExistence(timeout: 5))
        info.click()
        snap.click()
        XCTAssertEqual(String(describing: snap.value ?? ""), "0")
        info.click()
        XCTAssertTrue(element("stitching.requestedCut").waitForExistence(timeout: 5))
        XCTAssertTrue(element("stitching.requestedEnd").waitForExistence(timeout: 5))
        XCTAssertTrue(element("stitching.seekEstimate").waitForExistence(timeout: 5))
        info.click()
        XCTAssertEqual((timecode.value as? String) ?? timecode.label, duration)
        XCTAssertTrue(markers.allElementsBoundByIndex.contains { (Int($0.label.components(separatedBy: ": ").last ?? "") ?? 0) > 0 })
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "stitching-keyframe-candidates-free-trim"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testStitchingRangeDeletionAndUndo() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("group.edit").waitForExistence(timeout: 30))
        element("group.edit").click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        element("stitching.fit").click()
        let timecode = element("stitching.timecode")
        func durationText() -> String {
            ((timecode.value as? String) ?? timecode.label).components(separatedBy: " / ").last ?? ""
        }
        let originalDuration = durationText()
        element("stitching.rangeTool").click()
        XCTAssertEqual(String(describing: element("stitching.rangeTool").value ?? ""), "1")
        // Other desktop apps can open status-item popovers during this test.
        // Restore focus before synthesizing the timeline drag.
        app.activate()
        let rangeSurface = app.descendants(matching: .any).matching(identifier: "stitching.rangeSurface").firstMatch
        XCTAssertTrue(rangeSurface.waitForExistence(timeout: 5), app.debugDescription)
        let start = rangeSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.4))
        let end = rangeSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        // press(forDuration:) sends touch events; the macOS editor needs mouse events.
        start.click(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(element("stitching.deleteRange").wait(for: \.isEnabled, toEqual: true, timeout: 5), app.debugDescription)
        XCTAssertEqual(durationText(), originalDuration, "Selecting a range must not trim or reorder clips")
        element("stitching.clearRange").click()
        XCTAssertFalse(element("stitching.deleteRange").isEnabled)
        end.click(forDuration: 0.1, thenDragTo: start)
        XCTAssertTrue(element("stitching.deleteRange").wait(for: \.isEnabled, toEqual: true, timeout: 5),
                      "Reverse drags must select the same deletable interval")
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertNotEqual(durationText(), originalDuration)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(durationText(), originalDuration)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertNotEqual(durationText(), originalDuration)
    }

    @MainActor
    func testStitchingBackspaceDeletesSelectedClipAndUndoRestoresIt() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("group.edit").waitForExistence(timeout: 30))
        element("group.edit").click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        element("stitching.fit").click()
        let timeline = element("group.timeline")
        let timecode = element("stitching.timecode")
        func durationText() -> String {
            ((timecode.value as? String) ?? timecode.label).components(separatedBy: " / ").last ?? ""
        }
        let originalDuration = durationText()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).click()
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertNotEqual(durationText(), originalDuration)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(durationText(), originalDuration)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertNotEqual(durationText(), originalDuration)
    }

    @MainActor
    func testStitchingTimelineEditExportsMergedOutput() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        let edit = element("group.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        edit.click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        element("stitching.fit").click()

        let timecode = element("stitching.timecode")
        let originalDuration = (timecode.value as? String) ?? timecode.label
        element("group.timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.05)).click()
        app.typeKey("q", modifierFlags: [])
        XCTAssertNotEqual((timecode.value as? String) ?? timecode.label, originalDuration)
        element("group.done").click()

        let output = element("group.output")
        XCTAssertFalse(output.exists)
        let conversion = element("toolbar.conversion")
        XCTAssertTrue(waitForEnabled(true, of: conversion, timeout: 5))
        conversion.click()
        XCTAssertTrue(output.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversion, timeout: 5))
    }

    @MainActor
    func testGeneratedCameraCardReviewImportsGroupInBothLanguages() throws {
        for (language, locale) in [("en", "en_US"), ("nb", "nb_NO")] {
            launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC",
                      language: language, locale: locale, previewContainer: "mp4",
                      cameraCard: true)
            let name = element("cameraCard.name")
            XCTAssertTrue(name.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertEqual(name.value as? String, "UI Test Card")
            let review = element("cameraCard.review")
            XCTAssertTrue(review.isEnabled)
            review.click()
            let proposal = element("cameraCard.review.proposal")
            XCTAssertTrue(proposal.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(proposal.label.contains("1"), proposal.label)
            attachWindowScreenshot(named: "Camera card review - \(language)")
            element("cameraCard.review.import").click()
            let edit = element("group.edit")
            XCTAssertTrue(edit.waitForExistence(timeout: 30), app.debugDescription)
            edit.click()
            let files = element("group.files")
            XCTAssertTrue(files.waitForExistence(timeout: 10))
            XCTAssertTrue(files.staticTexts["C0001.mp4"].exists)
            XCTAssertTrue(files.staticTexts["C0002.mp4"].exists)
            XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
            XCTAssertTrue(element("stitching.selectedClip").waitForExistence(timeout: 5))
            element("group.done").click()
            terminateAndCleanFixtures()
        }
    }

    @MainActor
    func testStitchingSplitKeepsDurationAndAllowsIndependentTrim() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("group.edit").waitForExistence(timeout: 30))
        element("group.edit").click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        element("stitching.fit").click()
        let timeline = element("group.timeline")
        let timecode = element("stitching.timecode")
        func durationText() -> String {
            ((timecode.value as? String) ?? timecode.label).components(separatedBy: " / ").last ?? ""
        }
        let originalDuration = durationText()
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.05)).click()
        let split = element("stitching.split")
        XCTAssertTrue(split.isEnabled)
        app.typeKey("b", modifierFlags: .command)
        XCTAssertEqual(durationText(), originalDuration)
        XCTAssertFalse(split.isEnabled, "The new second part starts at the playhead")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(split.isEnabled, "Undo restores the unsplit source range")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertFalse(split.isEnabled, "Redo restores the cut")
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.05)).click()
        app.typeKey("q", modifierFlags: [])
        XCTAssertNotEqual(durationText(), originalDuration)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(durationText(), originalDuration)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertNotEqual(durationText(), originalDuration)
    }

    @MainActor
    func testStitchingMarkersCanBeAddedEditedAndDeleted() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("group.edit").waitForExistence(timeout: 30))
        element("group.edit").click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        app.typeKey("m", modifierFlags: [])
        XCTAssertTrue(element("stitching.marker").waitForExistence(timeout: 5))
        app.typeKey("m", modifierFlags: [])
        let note = element("stitching.markerText")
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.click()
        app.typeKey("a", modifierFlags: .command)
        note.typeText("Review music")
        element("stitching.saveMarker").click()
        XCTAssertTrue(waitForLabel("Marked: Review music", of: element("stitching.marker"), timeout: 5))
        element("group.done").click()
        element("group.edit").click()
        XCTAssertTrue(element("stitching.marker").waitForExistence(timeout: 10))
        element("stitching.marker").click()
        element("stitching.deleteMarker").click()
        XCTAssertTrue(element("stitching.marker").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testStitchingColdSeekAndRapidScrub() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        let edit = element("group.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        edit.click()
        let timeline = element("group.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        element("stitching.fit").click()
        let early = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.05))
        let late = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.05))
        late.click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        XCTAssertTrue(waitForValue("ui-test-second.mp4", of: element("stitching.selectedClip"), timeout: 10))
        // Start on the first clip so the final state proves the drag landed,
        // rather than merely retaining the preceding cold seek's position.
        early.click()
        XCTAssertTrue(waitForValue("ui-test-fixture.mp4", of: element("stitching.selectedClip"), timeout: 10))
        early.click(forDuration: 0.05, thenDragTo: late)
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        XCTAssertTrue(waitForValue("ui-test-second.mp4", of: element("stitching.selectedClip"), timeout: 10))
        let seekLanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", "00:00:03:"),
            object: element("stitching.timecode")
        )
        XCTAssertEqual(XCTWaiter.wait(for: [seekLanded], timeout: 5), .completed)
        attachWindowScreenshot(named: "Dynamic waveform and cold seek")
        element("group.done").click()
        XCTAssertTrue(element("stitching.preview").waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testStitchingUnavailableSourceStopsAndAllowsRetryInBothLanguages() throws {
        for (language, locale, pauseLabel) in [("en", "en_US", "Play sequence"), ("nb", "nb_NO", "Spill av sekvens")] {
            launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", language: language, locale: locale,
                      previewContainer: "mkv", stitching: true, missingStitchingSource: true)
            let edit = element("group.edit")
            XCTAssertTrue(edit.waitForExistence(timeout: 30))
            edit.click()
            let preview = element("stitching.preview")
            let play = element("stitching.play")
            let selected = element("stitching.selectedClip")
            XCTAssertTrue(waitForLabel("mpv ready", of: preview, timeout: 30))
            play.click()
            XCTAssertTrue(waitForValue("ui-test-second.mkv", of: selected, timeout: 15))
            XCTAssertTrue(waitForLabel("failed", of: preview, timeout: 15))
            XCTAssertTrue(waitForLabel(pauseLabel, of: play, timeout: 5))
            XCTAssertEqual(element("stitching.timecode").value as? String, "00:00:02:00 / 00:00:04:00",
                           "A failed source must remain at its requested in-point, not complete the sequence")
            let retry = element("preview.retry")
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            XCTAssertTrue(retry.isHittable)
            attachWindowScreenshot(named: "Stitching unavailable source - \(language)")
            retry.click()
            // The file remains unavailable; Retry must show the error again and
            // never turn failure into successful sequence completion.
            XCTAssertTrue(waitForLabel("failed", of: preview, timeout: 15))
            XCTAssertTrue(waitForLabel(pauseLabel, of: play, timeout: 5))
            XCTAssertEqual(selected.value as? String, "ui-test-second.mkv")
            element("stitching.fit").click()
            element("group.timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.05)).click()
            XCTAssertTrue(waitForValue("ui-test-fixture.mkv", of: selected, timeout: 5))
            XCTAssertTrue(waitForLabel("mpv ready", of: preview, timeout: 30))
            play.click()
            XCTAssertTrue(waitForValue("ui-test-second.mkv", of: selected, timeout: 15))
            XCTAssertTrue(waitForLabel("failed", of: preview, timeout: 15))
            XCTAssertTrue(waitForLabel(pauseLabel, of: play, timeout: 5))
            element("group.done").click()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
            terminateAndCleanFixtures()
        }
    }

    @MainActor
    func testNativeStitchingSequencePlaybackAndReplay() throws {
        try exerciseStitchingSequence(container: "mp4", expectedBackend: "AVPlayer")
    }

    @MainActor
    func testMPVStitchingSequencePlaybackAndReplay() throws {
        try exerciseStitchingSequence(container: "mkv", expectedBackend: "MPV")
    }

    @MainActor
    func testNativeStitchingPauseAndDismissDuringLoading() throws {
        try exerciseStitchingDelayedLoad(container: "mp4", backend: "native")
    }

    @MainActor
    func testMPVStitchingPauseAndDismissDuringLoading() throws {
        try exerciseStitchingDelayedLoad(container: "mkv", backend: "mpv")
    }

    @MainActor
    private func exerciseStitchingDelayedLoad(container: String, backend: String) throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: container,
                  stitching: true, delayedStitchingLoad: true)
        defer { terminateAndCleanFixtures() }
        let edit = element("group.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        let preview = element("stitching.preview")
        let play = element("stitching.play")
        let selected = element("stitching.selectedClip")
        for dismissWhileLoading in [false, true] {
            edit.click()
            XCTAssertTrue(waitForLabel("\(backend) ready", of: preview, timeout: 30))
            play.click()
            XCTAssertTrue(waitForValue("ui-test-second.\(container)", of: selected, timeout: 15))
            XCTAssertTrue(preview.label.hasSuffix("loading"), "The transition must still be loading")
            if dismissWhileLoading {
                element("group.done").click()
                XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
                edit.click()
                XCTAssertTrue(waitForLabel("\(backend) ready", of: preview, timeout: 30))
                // Remain open past the abandoned preparation's delay. It must not
                // switch sources or start playback in the replacement editor.
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    selected.value as? String != "ui-test-fixture.\(container)" || play.label != "Play sequence"
                }, object: nil)
                changed.isInverted = true
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
            } else {
                play.click()
                XCTAssertTrue(waitForLabel("Play sequence", of: play, timeout: 5))
                XCTAssertTrue(waitForLabel("\(backend) ready", of: preview, timeout: 30))
                let backendTime = element("stitching.backendTime")
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    guard let time = Double((backendTime.value as? String) ?? backendTime.label) else { return false }
                    return abs(time - 2) < 0.15
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                               "Expected second clip in-point; backend value: \(backendTime.debugDescription)")
                // Observe the backend clock: the sequence counter deliberately
                // ignores paused callbacks and alone could hide unwanted playback.
                let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    guard let time = Double((backendTime.value as? String) ?? backendTime.label) else { return true }
                    return abs(time - 2) > 0.2
                }, object: nil)
                moved.isInverted = true
                XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 2), .completed)
                play.click()
                XCTAssertTrue(waitForValue("00:00:04:00 / 00:00:04:00", of: element("stitching.timecode"), timeout: 15))
                XCTAssertTrue(waitForLabel("Play sequence", of: play, timeout: 5))
            }
            element("group.done").click()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        }
    }

    @MainActor
    private func exerciseStitchingSequence(container: String, expectedBackend: String) throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", previewContainer: container, stitching: true)
        defer { terminateAndCleanFixtures() }
        app.activate()
        let edit = element("group.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        for attempt in 0..<2 {
            edit.click()
            let timeline = element("group.timeline")
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))
            XCTAssertTrue(element("group.files").exists)
            let preview = element("stitching.preview")
            XCTAssertTrue(waitForLabel("\(expectedBackend == "AVPlayer" ? "native" : "mpv") ready", of: preview, timeout: 30))
            let play = element("stitching.play")
            let selected = element("stitching.selectedClip")
            let timecode = element("stitching.timecode")
            XCTAssertTrue(waitForValue("00:00:00:00 / 00:00:04:00", of: timecode, timeout: 10))
            play.click()
            XCTAssertTrue(waitForValue("ui-test-second.\(container)", of: selected, timeout: 15))
            XCTAssertTrue(waitForLabel("Play sequence", of: play, timeout: 15))
            XCTAssertTrue(waitForValue("00:00:04:00 / 00:00:04:00", of: timecode, timeout: 5))
            // J reverses across the cut and stops at the first trimmed in-point.
            app.typeText("j")
            XCTAssertTrue(waitForValue("ui-test-fixture.\(container)", of: selected, timeout: 15))
            XCTAssertTrue(waitForLabel("Play sequence", of: play, timeout: 15))
            XCTAssertTrue(waitForValue("00:00:00:00 / 00:00:04:00", of: timecode, timeout: 5))
            // K is a pause command, including when already paused. Repeated L speeds up.
            app.typeText("k")
            XCTAssertTrue(waitForLabel("Play sequence", of: play, timeout: 5))
            app.typeText("ll")
            XCTAssertTrue(waitForValue("1.5×", of: element("stitching.rate"), timeout: 5))
            XCTAssertTrue(waitForLabel("Play sequence", of: play, timeout: 15))
            XCTAssertTrue(waitForValue("00:00:04:00 / 00:00:04:00", of: timecode, timeout: 5))
            // Replay must seek to the first trimmed in-point after sequence end.
            play.click()
            XCTAssertTrue(waitForValue("ui-test-fixture.\(container)", of: selected, timeout: 5))
            let replayAdvances = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@ AND value != %@",
                                       "00:00:00:00 / 00:00:04:00", "00:00:04:00 / 00:00:04:00"), object: timecode
            )
            XCTAssertEqual(XCTWaiter.wait(for: [replayAdvances], timeout: 5), .completed)
            play.click()
            XCTAssertTrue(waitForLabel("Play sequence", of: play, timeout: 5))
            let paused = try XCTUnwrap(timecode.value as? String)
            let remainsPaused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", paused), object: timecode
            )
            remainsPaused.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [remainsPaused], timeout: 1), .completed)
            attachWindowScreenshot(named: "\(expectedBackend) stitching playback - \(attempt)")
            element("group.done").click()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        }
    }

    @MainActor
    func testNormalTrimHandleHitAreas() throws {
        launchApp(generatedFixture: true, previewContainer: "mp4")
        defer { terminateAndCleanFixtures() }
        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 30))
        app.activate()
        queueItem.rightClick()
        app.menuItems["Preview / Trim"].click()
        XCTAssertTrue(waitForValue("AVPlayer ready", of: element("preview.media"), timeout: 30))

        let timeline = element("trim.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let start = element("trim.timeline.start")
        let end = element("trim.timeline.end")
        func waitForTrim(_ seconds: Double, of slider: XCUIElement) -> Bool {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let value = slider.value as? NSNumber else { return false }
                return abs(value.doubleValue - seconds) < 0.01
            }, object: slider)
            return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
        }

        // Grab the transparent padding, not just the two-point visible line.
        // Edge handles must win over scrubbing even when no trim is set yet.
        for compact in [false, true] {
            if compact {
                element("trim.cropControls").click()
            }
            for offset: CGFloat in [-10, 10] {
                if !compact {
                    element("trim.reset").click()
                } else {
                    app.typeKey("i", modifierFlags: .option)
                    app.typeKey("o", modifierFlags: .option)
                }
                let origin = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                let width = timeline.frame.width
                origin.withOffset(CGVector(dx: 10, dy: 0)).click(forDuration: 0.1, thenDragTo:
                    origin.withOffset(CGVector(dx: 10 + width * 0.25, dy: 0)))
                XCTAssertTrue(waitForTrim(1.5, of: start))
                XCTAssertTrue(waitForTrim(6.0, of: end))

                origin.withOffset(CGVector(dx: width - 10, dy: 0)).click(forDuration: 0.1, thenDragTo:
                    origin.withOffset(CGVector(dx: width * 0.75 - 10, dy: 0)))
                XCTAssertTrue(waitForTrim(4.5, of: end))
                XCTAssertTrue(waitForTrim(1.5, of: start))

                // Both sides of an interior handle must adjust that endpoint.
                origin.withOffset(CGVector(dx: width * 0.25 + offset, dy: 0)).click(forDuration: 0.1, thenDragTo:
                    origin.withOffset(CGVector(dx: width * 0.35 + offset, dy: 0)))
                XCTAssertTrue(waitForTrim(2.1, of: start))
                XCTAssertTrue(waitForTrim(4.5, of: end))

                origin.withOffset(CGVector(dx: width * 0.75 + offset, dy: 0)).click(forDuration: 0.1, thenDragTo:
                    origin.withOffset(CGVector(dx: width * 0.65 + offset, dy: 0)))
                XCTAssertTrue(waitForTrim(3.9, of: end))
                XCTAssertTrue(waitForTrim(2.1, of: start))
            }
            attachWindowScreenshot(named: compact ? "Compact trim handle drag" : "Normal trim handle drag")
        }
        element("preview.close").click()
    }

    @MainActor
    private func exercisePreview(container: String, expectedBackend: String) throws {
        launchApp(generatedFixture: true, previewContainer: container)
        defer { terminateAndCleanFixtures() }
        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 30))

        for attempt in 0..<2 {
            app.activate()
            queueItem.rightClick()
            let preview = app.menuItems["Preview / Trim"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            preview.click()
            let media = element("preview.media")
            XCTAssertTrue(media.waitForExistence(timeout: 10))
            XCTAssertTrue(waitForValue("\(expectedBackend) ready", of: media, timeout: 30))
            let timecode = element("trim.timecode")
            XCTAssertTrue(timecode.waitForExistence(timeout: 5))
            timecode.click()
            let input = element("trim.timecodeInput")
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.click()
            let audioMeter = element("trim.audioMeter")
            let meterValue = try XCTUnwrap(audioMeter.value as? NSNumber)
            // Collapse any automatic initial selection before exercising Select All.
            input.typeKey(.rightArrow, modifierFlags: [])
            input.typeKey("a", modifierFlags: .command)
            input.typeText("00:00:01:00")
            XCTAssertTrue(waitForValue("00:00:01:00", of: input, timeout: 5),
                          "Select All must replace the timecode without triggering preview shortcuts")
            XCTAssertEqual(audioMeter.value as? NSNumber, meterValue)
            input.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForValue("00:00:01:00", of: timecode, timeout: 10))
            if attempt == 0 {
                let reveal = element("trim.revealScreenshot")
                XCTAssertFalse(reveal.isEnabled)
                element("trim.captureFrame").click()
                XCTAssertTrue(waitForEnabled(true, of: reveal, timeout: 30))
                // A preview sheet may extend beyond its parent window; capture
                // the full app so attachments do not crop the sheet's controls.
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(expectedBackend) preview after seek and screenshot"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.typeKey("l", modifierFlags: [])
            let advances = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", "00:00:01:00"), object: timecode
            )
            XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 5), .completed)
            app.typeKey("k", modifierFlags: [])
            let pausedTimecode = try XCTUnwrap(timecode.value as? String)
            let staysPaused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", pausedTimecode), object: timecode
            )
            staysPaused.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [staysPaused], timeout: 1), .completed)
            element("preview.close").click()
            XCTAssertTrue(media.waitForNonExistence(timeout: 10))
        }
        XCTAssertEqual(queueItem.value as? String, "waiting")
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
    func testRenamesOutputFromDoubleClickAndContextMenu() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC")
        defer { terminateAndCleanFixtures() }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        let outputName = element("queue.item.outputName")
        XCTAssertTrue(outputName.waitForExistence(timeout: 5))

        outputName.doubleClick()
        let editor = element("queue.item.outputNameEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("double-click-name.mp4")
        editor.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("double-click-name.mp4", of: outputName, timeout: 5))

        queueItem.rightClick()
        let rename = app.menuItems["Rename Output"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("context-menu-name.mp4")
        editor.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("context-menu-name.mp4", of: outputName, timeout: 5))
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

        XCTAssertTrue(
            waitForValue("converting", of: queueItem, timeout: 10),
            queueItem.debugDescription
        )
        let jobOrigin = element("queue.item.jobOrigin")
        XCTAssertTrue(jobOrigin.waitForExistence(timeout: 5))
        XCTAssertEqual(jobOrigin.label, "Manual job")
        XCTAssertTrue(waitForLabel("Cancel Conversion", of: conversionButton, timeout: 5))
        conversionButton.click()

        XCTAssertTrue(waitForValue("cancelled", of: queueItem, timeout: 10))
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
    }

    @MainActor
    func testCancelledConversionCanRetryAndConvertAgainUsingKeyboard() throws {
        launchApp(
            generatedFixture: true,
            defaultPreset: "H.264 / AVC",
            realtimeInput: true
        )
        defer { terminateAndCleanFixtures() }

        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        let conversionButton = element("toolbar.conversion")
        XCTAssertTrue(waitForEnabled(true, of: conversionButton, timeout: 5))
        app.activate()
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForValue("converting", of: queueItem, timeout: 10))
        XCTAssertTrue(waitForLabel("Cancel Conversion", of: conversionButton, timeout: 5))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForValue("cancelled", of: queueItem, timeout: 10))
        XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))

        // Exercise reset and retry after cancellation, then repeat with an
        // existing successful output through the normal app collision policy.
        for attempt in 1...2 {
            app.typeKey("r", modifierFlags: [.command, .shift])
            XCTAssertTrue(waitForValue("waiting", of: queueItem, timeout: 5))
            XCTAssertTrue(waitForEnabled(true, of: conversionButton, timeout: 5))
            app.typeKey(.return, modifierFlags: .command)
            XCTAssertTrue(waitForValue("converting", of: queueItem, timeout: 10))
            XCTAssertTrue(waitForValue("done", of: queueItem, timeout: 45))
            XCTAssertTrue(waitForLabel("Start Conversion", of: conversionButton, timeout: 5))
            XCTAssertTrue(waitForEnabled(false, of: conversionButton, timeout: 5))
            attachWindowScreenshot(named: "Keyboard conversion recovery - attempt \(attempt)")
        }
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

        XCTAssertTrue(element("queue.item.acceptedSettings").waitForExistence(timeout: 10))
        element("queue.item.acceptedSettings").click()
        let acceptedSettings = element("queue.acceptedSettings.text")
        XCTAssertTrue(acceptedSettings.waitForExistence(timeout: 5))
        XCTAssertTrue((acceptedSettings.value as? String ?? "").contains("Preset: H.264"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForValue("done", of: queueItem, timeout: 20),
            queueItem.debugDescription
        )
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
        additionalArguments: [String] = [],
        damagedSchedules: Bool = false,
        damagedHistory: Bool = false,
        previewContainer: String? = nil,
        stitching: Bool = false,
        cameraCard: Bool = false,
        delayedStitchingLoad: Bool = false,
        missingStitchingSource: Bool = false,
        resetAgentAccess: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            // Keep first-launch update permission prompts out of test sessions.
            "-SUEnableAutomaticChecks", "NO",
            // The installed app and UI-test host share a bundle identifier. Do not
            // inherit a persisted state in which every main window was closed.
            "-ApplePersistenceIgnoreState", "YES",
            "-ffmpegBinarySource", "app",
            "-defaultExportPreset", defaultPreset
        ]
        app.launchArguments += additionalArguments
        app.launchEnvironment["AMC_UI_TEST_SESSION"] = "1"
        app.launchEnvironment["AMC_UI_TEST_APPLICATION_JOB_STORE_ID"] = UUID().uuidString
        app.launchEnvironment["AMC_UI_TEST_AGENT_PORT_ID"] = UUID().uuidString
        if resetAgentAccess {
            app.launchEnvironment["AMC_UI_TEST_RESET_AGENT_ACCESS"] = "1"
        }
        if stitching {
            app.launchEnvironment["AMC_UI_TEST_STITCHING"] = "1"
            app.launchEnvironment["AMC_UI_TEST_STITCHING_PRESET"] = defaultPreset
        }
        if cameraCard {
            app.launchEnvironment["AMC_UI_TEST_CAMERA_CARD"] = "1"
        }
        if delayedStitchingLoad {
            app.launchEnvironment["AMC_UI_TEST_DELAY_STITCHING_LOAD"] = "1"
        }
        if missingStitchingSource {
            app.launchEnvironment["AMC_UI_TEST_MISSING_STITCHING_SOURCE"] = "1"
        }
        if let previewContainer {
            app.launchEnvironment["AMC_UI_TEST_PREVIEW_CONTAINER"] = previewContainer
        }
        if damagedHistory {
            app.launchEnvironment["AMC_UI_TEST_DAMAGED_HISTORY"] = "1"
        }
        if damagedSchedules {
            app.launchEnvironment["AMC_UI_TEST_DAMAGED_SCHEDULES"] = "1"
        }
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
        // A fresh test installation may show the first-open usage choice. Make
        // the explicit no-reporting choice before tests interact with the window.
        let declineUsage = element("anonymousUsage.decline")
        if declineUsage.exists {
            declineUsage.click()
        }
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
    private func waitForLabelOrValue(
        _ text: String,
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForTextContaining(
        _ text: String,
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
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
