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
    func testInstagramCarouselPickerAllowsMultipleVideoSelection() throws {
        launchApp(additionalArguments: ["-ytdlpBinarySource", "app", "-denoBinarySource", "app"], instagramPicker: true)
        defer { terminateAndCleanFixtures() }
        let field = element("downloadURLField")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("https://www.instagram.com/p/DeKeT1to6s3/")
        XCTAssertTrue(element("instagramSlide10").waitForExistence(timeout: 15))
        XCTAssertFalse(element("instagramSlide1").exists)
        let download = element("downloadSubmitButton")
        XCTAssertFalse(download.isEnabled)
        element("instagramSlide4").click()
        element("instagramSlide10").click()
        XCTAssertTrue(download.isEnabled)
        XCTAssertEqual(download.label, "Download Selected (2)")
        attachWindowScreenshot(named: "Instagram carousel video selection")
        element("postVideoSelectAll").click()
        XCTAssertEqual(download.label, "Download Selected (5)")
        element("postVideoSelectAll").click()
        XCTAssertFalse(download.isEnabled)
        // Editing the post clears the previous choices.
        element("instagramSlide10").click()
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("https://www.instagram.com/p/DeKeT1to6s3/?utm_source=test")
        XCTAssertTrue(element("instagramSlide10").waitForExistence(timeout: 15))
        XCTAssertFalse(download.isEnabled)
    }

    @MainActor
    func testTwitterPostPickerAllowsMultipleVideoSelection() throws {
        launchApp(additionalArguments: ["-ytdlpBinarySource", "app", "-denoBinarySource", "app"], twitterPicker: true)
        defer { terminateAndCleanFixtures() }
        let field = element("downloadURLField")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("https://x.com/example/status/1600649710662213632")
        XCTAssertTrue(element("twitterVideo2").waitForExistence(timeout: 15))
        let download = element("downloadSubmitButton")
        XCTAssertFalse(download.isEnabled)
        element("twitterVideo1").click()
        element("twitterVideo2").click()
        XCTAssertEqual(download.label, "Download Selected (2)")
        attachWindowScreenshot(named: "Twitter X post video selection")
        element("postVideoSelectAll").click()
        XCTAssertFalse(download.isEnabled)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("https://twitter.com/example/status/1600649710662213632/video/2")
        XCTAssertTrue(download.isEnabled)
        XCTAssertEqual(download.label, "Download")
        XCTAssertFalse(element("twitterVideo2").exists)
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
    func testMetadataEditorPrefillsFieldsAndKeepsEditsAcrossTabs() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", additionalArguments: [
            "-AMC_UI_TEST_TEXT_METADATA", "YES", "-showCommentField", "YES",
            "-preserveMetadataByDefault", "NO"
        ])
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.item").waitForExistence(timeout: 20))
        app.activate()
        let openEditor = element("queue.item.metadataEditor")
        XCTAssertTrue(openEditor.waitForExistence(timeout: 10))
        openEditor.click()
        let comment = element("metadata.editor.comment.value")
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        XCTAssertEqual(comment.value as? String, "Source comment")
        attachWindowScreenshot(named: "Metadata editor - source comment")

        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Description")).firstMatch.click()
        let description = element("metadata.editor.description.value")
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        XCTAssertEqual(description.value as? String, "Source description\nSecond line 日本語 🎬")
        attachWindowScreenshot(named: "Metadata editor - source description")

        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Title")).firstMatch.click()
        let title = element("metadata.editor.title.value")
        XCTAssertEqual(title.value as? String, "Source title")
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Edited title")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Artist")).firstMatch.click()
        XCTAssertEqual(element("metadata.editor.artist.value").value as? String, "Source artist")
        app.typeKey(.escape, modifierFlags: [])
        openEditor.click()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Title")).firstMatch.click()
        XCTAssertEqual(element("metadata.editor.title.value").value as? String, "Edited title")
    }

    @MainActor
    func testDisablingCommentUpdatesQueueIconAndPersistsAfterReopening() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", additionalArguments: [
            "-AMC_UI_TEST_TEXT_METADATA", "YES", "-showCommentField", "YES",
            "-preserveMetadataByDefault", "NO"
        ])
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.item").waitForExistence(timeout: 20))
        let openEditor = element("queue.item.metadataEditor")
        openEditor.click()
        XCTAssertTrue(element("metadata.editor.comment.value").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Comment override enabled", of: openEditor, timeout: 5))
        let writeComment = app.checkBoxes.matching(identifier: "metadata.editor.comment.enabled").firstMatch
        XCTAssertTrue(writeComment.waitForExistence(timeout: 5))
        writeComment.click()
        XCTAssertTrue(waitForToggle(false, of: writeComment, timeout: 5))
        XCTAssertTrue(waitForValue("Comment override disabled", of: openEditor, timeout: 5))
        XCTAssertFalse(element("metadata.editor.comment.value").isEnabled)
        attachWindowScreenshot(named: "Metadata editor - Comment disabled")
        app.typeKey(.escape, modifierFlags: [])
        openEditor.click()
        XCTAssertTrue(writeComment.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForToggle(false, of: writeComment, timeout: 5))
        XCTAssertEqual(element("metadata.editor.comment.value").value as? String, "Source comment")
    }

    @MainActor
    func testMetadataMasterSwitchDisablesAllOverridesAndRetainsValues() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", additionalArguments: [
            "-AMC_UI_TEST_TEXT_METADATA", "YES", "-showCommentField", "YES"
        ])
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.item").waitForExistence(timeout: 20))
        let openEditor = element("queue.item.metadataEditor")
        openEditor.click()
        let master = app.checkBoxes.matching(identifier: "metadata.editor.enabled").firstMatch
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        master.click()
        XCTAssertTrue(waitForToggle(false, of: master, timeout: 5))
        XCTAssertFalse(element("metadata.editor.comment.value").isEnabled)
        XCTAssertFalse(app.checkBoxes.matching(identifier: "metadata.editor.comment.enabled").firstMatch.isEnabled)
        XCTAssertTrue(waitForValue("Comment override disabled", of: openEditor, timeout: 5))
        attachWindowScreenshot(named: "Metadata editor - All overrides disabled")
        app.typeKey(.escape, modifierFlags: [])
        openEditor.click()
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForToggle(false, of: master, timeout: 5))
        master.click()
        XCTAssertTrue(waitForToggle(true, of: master, timeout: 5))
        attachWindowScreenshot(named: "Metadata editor - Reenabled after reopening")
        let comment = element("metadata.editor.comment.value")
        XCTAssertEqual(comment.value as? String, "Source comment")
        XCTAssertTrue(app.checkBoxes.matching(identifier: "metadata.editor.comment.enabled").firstMatch.isEnabled)
        comment.click()
        comment.typeKey("a", modifierFlags: .command)
        comment.typeText("Restored comment")
        XCTAssertTrue(waitForValue("Restored comment", of: comment, timeout: 5))
        XCTAssertTrue(waitForValue("Comment override enabled", of: openEditor, timeout: 5))
    }

    @MainActor
    func testEmptyQueueTipsWrapAndRefreshInBothLanguages() throws {
        for (language, locale) in [("en", "en_US"), ("nb", "nb_NO")] {
            launchApp(language: language, locale: locale, tipIndex: 15)
            defer { app.terminate() }
            let tip = element("queue.empty.tip")
            XCTAssertTrue(tip.waitForExistence(timeout: 10))
            app.activate()

            // Exercise wrapping at the main window's minimum width and a
            // shorter height, rather than checking only the full AX string.
            let window = app.windows.firstMatch
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(
                dx: 860 - window.frame.width, dy: 525 - window.frame.height
            )))
            XCTAssertGreaterThan(tip.frame.height, 20, "Long tips should occupy several lines")
            XCTAssertGreaterThanOrEqual(tip.frame.minX, window.frame.minX)
            XCTAssertLessThanOrEqual(tip.frame.maxX, window.frame.maxX)
            XCTAssertLessThanOrEqual(tip.frame.maxY, window.frame.maxY)
            attachWindowScreenshot(named: "Wrapped empty queue tip - \(language)")

            let original = tip.value as? String ?? tip.label
            tip.click()
            app.activate()
            app.typeKey("r", modifierFlags: .control)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (tip.value as? String ?? tip.label) != original
            }, object: tip)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            app.terminate()
        }
    }

    @MainActor
    func testNewLanguagesDisplayCameraCardTipAndSettings() throws {
        executionTimeAllowance = 180
        let languages = [
            ("de", "de_DE", "Tipp: Wähle Ablage > Kamerakarte importieren… (⌘⇧I), um auf einer Speicherkarte oder in einem Ordner nach Videoclips zu suchen.", "Allgemein", "Downloads"),
            ("es", "es_ES", "Consejo: Usa Archivo > Importar tarjeta de cámara… (⌘⇧I) para buscar videoclips en una tarjeta de memoria o carpeta.", "General", "Descargas"),
            ("fr", "fr_FR", "Astuce : Utilisez Fichier > Importer une carte caméra… (⌘⇧I) pour rechercher des clips vidéo sur une carte mémoire ou dans un dossier.", "Général", "Téléchargements"),
            ("it", "it_IT", "Suggerimento: Usa File > Importa scheda videocamera… (⌘⇧I) per cercare clip video su una scheda di memoria o in una cartella.", "Generali", "Download"),
            ("ja", "ja_JP", "ヒント：「ファイル」>「カメラカードを読み込む…」（⌘⇧I）で、メモリカードやフォルダ内の動画クリップを検索できます。", "一般", "ダウンロード"),
            ("ko", "ko_KR", "팁: 파일 > 카메라 카드 가져오기…(⌘⇧I)를 사용하여 메모리 카드나 폴더에서 동영상 클립을 검색하세요.", "일반", "다운로드"),
            ("pt-BR", "pt_BR", "Dica: Use Arquivo > Importar cartão de câmera… (⌘⇧I) para procurar clipes de vídeo em um cartão de memória ou pasta.", "Geral", "Downloads"),
            ("zh-Hans", "zh_CN", "提示：用“文件”>“导入相机存储卡…”（⌘⇧I）可扫描存储卡或文件夹中的视频片段。", "通用", "下载")
        ]
        for (language, locale, expectedTip, generalLabel, downloadsLabel) in languages {
            launchApp(language: language, locale: locale, tipIndex: 33)
            defer { app.terminate() }
            let tip = element("queue.empty.tip")
            XCTAssertTrue(tip.waitForExistence(timeout: 10))
            XCTAssertEqual(tip.value as? String ?? tip.label, expectedTip, "Camera-card tip in \(language)")
            app.activate()
            element("toolbar.settings").click()
            let settings = element("settings.root")
            if !settings.waitForExistence(timeout: 3) {
                app.activate()
                element("toolbar.settings").click()
            }
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            for (identifier, expectedLabel) in [("general", generalLabel), ("ytdlp", downloadsLabel)] {
                let tab = element("settings.tab.\(identifier)")
                XCTAssertTrue(tab.label == expectedLabel || tab.value as? String == expectedLabel,
                              "Settings label in \(language): \(expectedLabel)")
                app.activate()
                tab.click()
                XCTAssertTrue(waitForValue(identifier, of: settings, timeout: 5))
            }
            attachWindowScreenshot(named: "Localized Downloads settings - \(language)")
            app.terminate()
        }
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
    func testPresetMetadataPreservationDisplaysIndependentChoices() throws {
        launchApp(defaultPreset: "VideoLoop", additionalArguments: [
            "-preserveMetadata.VideoLoop", "NO",
            "-preserveMetadata.ProRes", "YES"
        ])
        defer { app.terminate() }
        XCTAssertTrue(element("toolbar.settings").waitForExistence(timeout: 10))
        element("toolbar.settings").click()
        XCTAssertTrue(element("settings.root").waitForExistence(timeout: 10))
        element("settings.tab.presets").click()
        let toggle = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
            "preset.metadata.preserve", XCUIElement.ElementType.checkBox.rawValue,
            XCUIElement.ElementType.switch.rawValue)).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForToggle(false, of: toggle, timeout: 5))
        element("settings.preset.ProRes").click()
        XCTAssertTrue(waitForToggle(true, of: toggle, timeout: 5))
        attachWindowScreenshot(named: "ProRes metadata preservation")
        element("settings.preset.VideoLoop").click()
        XCTAssertTrue(waitForToggle(false, of: toggle, timeout: 5))
    }

    @MainActor
    func testSettingsSearchFindsSettingNamesAndCanBeCleared() throws {
        launchApp()
        defer { app.terminate() }
        app.activate()
        let settingsButton = element("toolbar.settings")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()
        let root = element("settings.root")
        if !root.waitForExistence(timeout: 3) {
            // Other desktop UI work can take focus while a click is dispatched.
            app.activate()
            settingsButton.click()
        }
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        let search = element("settings.search")
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("settling")
        XCTAssertTrue(element("settings.tab.watchFolder").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("watchFolder", of: root, timeout: 5))
        XCTAssertFalse(element("settings.tab.general").exists)
        app.activate()
        attachWindowScreenshot(named: "Settings search - file settling time")
        element("settings.search.clear").click()
        XCTAssertTrue(element("settings.tab.general").waitForExistence(timeout: 5))
        search.click()
        search.typeText("zzzzzzzz")
        XCTAssertTrue(element("settings.search.empty").waitForExistence(timeout: 5))
        element("settings.search.clear").click()
        XCTAssertTrue(element("settings.tab.presets").waitForExistence(timeout: 5))
    }

    @MainActor
    func testConversionButtonIsLocalizedInBothLanguages() throws {
        for (language, locale, label) in [
            ("en", "en_US", "Start Conversion"),
            ("nb", "nb_NO", "Start konvertering")
        ] {
            launchApp(language: language, locale: locale)
            XCTAssertTrue(element("toolbar.conversion").waitForExistence(timeout: 10))
            XCTAssertEqual(element("toolbar.conversion").label, label)
            app.terminate()
        }
    }

    @MainActor
    func testShortcutRecorderRejectsReservedCommandsAndCancelsWithoutChanges() throws {
        func recorderText(containing text: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        }
        launchApp()
        defer { terminateAndCleanFixtures() }
        let settingsButton = element("toolbar.settings")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.click()
        XCTAssertTrue(element("settings.root").waitForExistence(timeout: 10))
        element("settings.search").click()
        element("settings.search").typeText("Customize keyboard shortcuts")
        element("settings.tab.shortcuts").click()
        let shortcut = element("settings.shortcuts.download")
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        let originalValue = shortcut.value as? String
        attachWindowScreenshot(named: "Settings - customizable shortcuts")
        shortcut.click()
        XCTAssertTrue(recorderText(containing: "Change Keyboard Shortcut").waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(recorderText(containing: "This combination is reserved for another app or system command. Choose another shortcut.").waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [])
        XCTAssertTrue(recorderText(containing: "Use a letter, number, or Return with Command, Control, or Option.").waitForExistence(timeout: 5))
        attachWindowScreenshot(named: "Settings - shortcut recorder validation")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        XCTAssertEqual(shortcut.value as? String, originalValue)
        XCTAssertFalse(recorderText(containing: "Change Keyboard Shortcut").exists)
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
            let description = element("settings.general.cleanupDescription")
            XCTAssertTrue(description.exists)
            let descriptionText = description.value as? String ?? description.label
            XCTAssertTrue(descriptionText.contains(language == "nb" ? "papirkurven" : "Trash"), descriptionText)
            attachWindowScreenshot(named: "Output cleanup error - \(language)")
            // Selectable SwiftUI text exposes its contents as an accessibility value.
            let cleanupText = cleanupError.value as? String ?? cleanupError.label
            XCTAssertTrue(cleanupText.hasPrefix(cleanupPrefix), cleanupText)
            element("settings.general.retryCleanup").click()
            XCTAssertTrue(cleanupError.waitForExistence(timeout: 10))
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
        let keyframeMarkers = app.descendants(matching: .any).matching(identifier: "stitching.keyframeMarkers")
        XCTAssertTrue(keyframeMarkers.allElementsBoundByIndex.allSatisfy {
            (Int($0.label.components(separatedBy: ": ").last ?? "") ?? 0) == 0
        }, "Reencoded timelines must not show Stream Copy keyframe ticks")
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
    func testStitchingStreamCopyAlwaysShowsKeyframeMarkers() throws {
        launchApp(generatedFixture: true, defaultPreset: "Stream Copy", previewContainer: "mp4", stitching: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("group.edit").waitForExistence(timeout: 30))
        element("group.edit").click()
        XCTAssertTrue(waitForLabel("native ready", of: element("stitching.preview"), timeout: 30))
        element("stitching.fit").click()
        XCTAssertFalse(app.checkBoxes["Snap trims and ranges to keyframes"].exists)
        let markers = app.descendants(matching: .any).matching(identifier: "stitching.keyframeMarkers")
        let visibleMarkers = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            markers.allElementsBoundByIndex.contains { (Int($0.label.components(separatedBy: ": ").last ?? "") ?? 0) > 0 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleMarkers], timeout: 30), .completed,
                       "Stream Copy must show scanned keyframe ticks")
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
        XCTAssertEqual((timecode.value as? String) ?? timecode.label, duration)
        XCTAssertTrue(markers.allElementsBoundByIndex.contains { (Int($0.label.components(separatedBy: ": ").last ?? "") ?? 0) > 0 })
        func frames(_ text: String) -> Int {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 4 else { XCTFail("Unexpected timecode: \(text)"); return -1 }
            return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * 24 + parts[3]
        }
        let initialFrames = frames(String(duration.split(separator: "/").last ?? "").trimmingCharacters(in: .whitespaces))
        let timeline = element("group.timeline")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.19, dy: 0.05)).click()
        let requested = (timecode.value as? String) ?? timecode.label
        let requestedFrames = frames(String(requested.split(separator: "/").first ?? "").trimmingCharacters(in: .whitespaces))
        XCTAssertNotEqual(requestedFrames % 12, 0, "The test must request a cut between keyframes")
        app.typeKey("q", modifierFlags: [])
        let afterTrim = (timecode.value as? String) ?? timecode.label
        let removedFrames = initialFrames - frames(String(afterTrim.split(separator: "/").last ?? "").trimmingCharacters(in: .whitespaces))
        XCTAssertGreaterThan(removedFrames, 0)
        XCTAssertEqual(removedFrames % 12, 0, "Stream Copy must snap the trim to the fixture's 12-frame GOP")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "stitching-stream-copy-keyframe-ticks"
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
    func testSourcePeakRMSAndLUFSMeterInNativeAndMPVPreview() throws {
        for (container, backend) in [("mp4", "AVPlayer"), ("mkv", "MPV")] {
            launchApp(generatedFixture: true, realtimeInput: true, previewContainer: container)
            defer { terminateAndCleanFixtures() }
            let queueItem = element("queue.item")
            XCTAssertTrue(queueItem.waitForExistence(timeout: 30))
            app.activate()
            queueItem.rightClick()
            app.menuItems["Preview / Trim"].click()
            XCTAssertTrue(waitForValue("\(backend) ready", of: element("preview.media"), timeout: 30))
            element("trim.timecode").click()
            let input = element("trim.timecodeInput")
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.click()
            input.typeKey("a", modifierFlags: .command)
            input.typeText("00:00:04:00")
            input.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForValue("00:00:04:00", of: element("trim.timecode"), timeout: 10))
            element("trim.audioMeter").click()
            let momentary = element("preview.audioMeter.momentary")
            let shortTerm = element("preview.audioMeter.shortTerm")
            XCTAssertTrue(momentary.waitForExistence(timeout: 15))
            let measured = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    Double((momentary.value as? String) ?? momentary.label) != nil
                        && Double((shortTerm.value as? String) ?? shortTerm.label) != nil
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 20), .completed,
                           "Source LUFS must be available without starting system-audio capture")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(backend) source peak RMS and LUFS meter"
            attachment.lifetime = .keepAlways
            add(attachment)
            if backend == "MPV" {
                // Restart to establish fresh playback loudness history. The
                // longer fixture keeps the decoder away from final AAC padding.
                element("trim.jumpToStart").click()
                let mode = element("preview.audioMeter.mode")
                XCTAssertTrue(mode.waitForExistence(timeout: 5))
                mode.radioButtons["Playback"].click()
                app.typeKey("l", modifierFlags: [])
                let channelReading = element("preview.audioMeter.channel.0")
                let playbackMeasured = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        let channel = channelReading.label
                        return Double((momentary.value as? String) ?? momentary.label) != nil
                            && Double((shortTerm.value as? String) ?? shortTerm.label) != nil
                            && channel.contains("dBFS") && !channel.contains("−∞")
                    }, object: nil)
                let playbackResult = XCTWaiter.wait(for: [playbackMeasured], timeout: 15)
                let liveAttachment = XCTAttachment(screenshot: app.screenshot())
                liveAttachment.name = "MPV decoded playback peak RMS and LUFS meter"
                liveAttachment.lifetime = .keepAlways
                add(liveAttachment)
                XCTAssertEqual(playbackResult, .completed,
                               "Channel: \(channelReading.label); momentary: \(momentary.label); short-term: \(shortTerm.label)")
                app.typeKey("k", modifierFlags: [])
                let cleared = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        ((momentary.value as? String) ?? momentary.label) == "—"
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
            }
            element("trim.audioMeter").click()
            XCTAssertTrue(momentary.waitForNonExistence(timeout: 5))
            element("preview.close").click()
        }
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
    func testVMAFV1RunsFromAnalysisOverlay() throws {
        launchApp(generatedFixture: true, additionalArguments: [
            "-analyticsEnabledMetrics", "(vmaf)", "-analyticsVMAFModel", "vmaf_v1.0.16_3d0h"
        ])
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        element("toolbar.conversion").click()
        XCTAssertTrue(waitForValue("done", of: element("queue.item"), timeout: 40))
        element("queue.analysis").click()
        let model = element("analysis.vmaf.model")
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.click()
        for label in [
            "VMAF v1.0.16 (Default)", "VMAF v1.0.16 (Phone)", "VMAF v1.0.16 (4K)",
            "VMAF v1.0.16 (50/60 fps)", "VMAF v1.0.16 (Phone, 50/60 fps)",
            "VMAF v1.0.16 (4K, 50/60 fps)", "VMAF v0.6.1 (Legacy)"
        ] {
            XCTAssertTrue(app.menuItems[label].exists, "Missing model: \(label)")
        }
        attachWindowScreenshot(named: "VMAF v1 - available models")
        app.menuItems["VMAF v1.0.16 (Default)"].click()
        XCTAssertTrue(element("analysis.video.run").isEnabled)
        element("analysis.video.run").click()
        XCTAssertTrue(element("analysis.result.vmaf").waitForExistence(timeout: 45),
                      "The bundled VMAF v1 model must produce a report in the sandbox")
        attachWindowScreenshot(named: "VMAF v1 - completed analysis")
    }

    @MainActor
    func testQualityTimelineSeeksPlayerAndSwitchesSource() throws {
        launchApp(generatedFixture: true, additionalArguments: [
            "-analyticsEnabledMetrics", "(vmaf)", "-analyticsVMAFModel", "vmaf_v0.6.1"
        ])
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        element("toolbar.conversion").click()
        XCTAssertTrue(waitForValue("done", of: element("queue.item"), timeout: 40))
        element("queue.analysis").click()
        XCTAssertTrue(element("analysis.video.run").waitForExistence(timeout: 5))
        element("analysis.video.run").click()
        XCTAssertTrue(element("analysis.result.vmaf").waitForExistence(timeout: 45))
        element("analysis.video.inspect").click()
        XCTAssertTrue(element("analysis.inspection.metric").waitForExistence(timeout: 10))
        let play = element("analysis.inspection.play")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        let slider = app.sliders["analysis.inspection.position"]
        XCTAssertTrue(slider.exists)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let time = element("analysis.inspection.time")
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "0.00 s"), object: time)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        let previousTime = try XCTUnwrap(time.value as? String)
        let chart = element("analysis.inspection.chart")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4)).click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", previousTime), object: time)], timeout: 5), .completed)
        XCTAssertEqual(play.label, "Play", "Seeking on the graph must pause playback")
        let low = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "analysis.inspection.low.")).firstMatch
        XCTAssertTrue(low.isHittable)
        low.click()
        let chosenTime = try XCTUnwrap(time.value as? String)
        app.radioButtons["Source"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)], timeout: 20), .completed)
        XCTAssertEqual(time.value as? String, chosenTime, "Source switching must preserve encoded-relative position")
        XCTAssertTrue(element("analysis.inspection.metric").isHittable)
        XCTAssertTrue(element("analysis.inspection.percentile").isHittable)
        XCTAssertTrue(element("analysis.inspection.nearest").isHittable)
        XCTAssertTrue(play.isHittable, "Playback controls must fit inside the window")
        XCTAssertTrue(element("analysis.inspection.close").isHittable)
        let chartFrame = element("analysis.inspection.chart").frame
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(chartFrame.minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(chartFrame.maxX, windowFrame.maxX)
        attachWindowScreenshot(named: "Quality timeline beside source playback")
    }

    @MainActor
    func testBundledSSIMULACRA2RunsFromAnalysisOverlay() throws {
        launchApp(generatedFixture: true, additionalArguments: [
            "-analyticsEnabledMetrics", "(ssimulacra2)", "-ssimulacra2MaxFrames", "5"
        ])
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        element("toolbar.conversion").click()
        XCTAssertTrue(waitForValue("done", of: element("queue.item"), timeout: 40))
        element("queue.analysis").click()
        XCTAssertTrue(element("analysis.ssimulacra2.frames").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Not installed"].exists)
        XCTAssertTrue(element("analysis.video.run").isEnabled)
        element("analysis.video.run").click()
        XCTAssertTrue(element("analysis.result.ssimulacra2").waitForExistence(timeout: 45),
                      "The signed bundled helper must run in the sandbox without any user installation")
        attachWindowScreenshot(named: "Bundled SSIMULACRA2 - completed analysis")
    }

    @MainActor
    func testPeakAnalysisNavigatesAndInvalidatesThreshold() throws {
        launchApp(generatedFixture: true, additionalArguments: ["-AMC_UI_TEST_PEAKS", "YES"], previewContainer: "mp4")
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        app.activate()
        element("queue.analysis").click()
        app.radioButtons["Audio"].click()
        let open = element("analysis.audio.peaks")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.click()
        let run = element("analysis.peaks.run")
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        let export = element("analysis.peaks.export")
        XCTAssertTrue(export.exists)
        XCTAssertFalse(export.isEnabled, "Export requires a complete report")
        run.click()
        XCTAssertTrue(waitForLabelOrValue("Peak intervals: 0", of: element("analysis.peaks.summary"), timeout: 20))
        XCTAssertTrue(waitForLabelOrValue("Channel difference exceeds threshold", of: element("analysis.peaks.balance"), timeout: 5))
        app.activate()
        element("analysis.peaks.threshold").click()
        let thresholdChoice = app.menuItems["-6 dBFS"]
        XCTAssertTrue(thresholdChoice.waitForExistence(timeout: 5))
        thresholdChoice.click()
        XCTAssertFalse(element("analysis.peaks.summary").exists)
        XCTAssertFalse(export.isEnabled, "Changed settings must invalidate the export")
        run.click()
        XCTAssertTrue(waitForLabelOrValue("Peak intervals: 1", of: element("analysis.peaks.summary"), timeout: 20))
        let start = element("analysis.peaks.start.0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)], timeout: 20), .completed)
        start.click()
        let time = element("analysis.peaks.time")
        let atStart = NSPredicate { _, _ in
            let text = (time.value as? String) ?? time.label
            guard let seconds = Double(text.replacingOccurrences(of: " s", with: "")) else { return false }
            return abs(seconds - 1) < 0.2
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: atStart, object: time)], timeout: 5), .completed)
        element("analysis.peaks.end.0").click()
        let atEnd = NSPredicate { _, _ in
            let text = (time.value as? String) ?? time.label
            guard let seconds = Double(text.replacingOccurrences(of: " s", with: "")) else { return false }
            return abs(seconds - 2) < 0.2
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: atEnd, object: time)], timeout: 5), .completed)
        attachWindowScreenshot(named: "Source peak intervals and channel balance")
        XCTAssertTrue(export.isHittable)
        export.click()
        let nameField = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(export.isEnabled, "Cancelling a save must preserve the report")
        XCTAssertTrue(element("analysis.peaks.summary").exists)

        let reportURL = URL(fileURLWithPath: "/private/tmp/amc-peak-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }
        export.click()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(reportURL.lastPathComponent)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let folder = app.textFields["PathTextField"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.typeKey("a", modifierFlags: .command)
        folder.typeText("/private/tmp")
        app.typeKey(.return, modifierFlags: [])
        app.dialogs["save-panel"].buttons["Save"].click()
        let written = NSPredicate { _, _ in FileManager.default.fileExists(atPath: reportURL.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 10), .completed)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        XCTAssertEqual(report["audioRelativeTrackIndex"] as? Int, 0)
        let result = try XCTUnwrap(report["result"] as? [String: Any])
        XCTAssertEqual((result["intervals"] as? [Any])?.count, 1)
        XCTAssertEqual((result["settings"] as? [String: Any])?["thresholdDBFS"] as? Double, -6)
        element("analysis.peaks.close").click()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPeakAnalysisNorwegianControlsAndReport() throws {
        launchApp(generatedFixture: true, language: "nb", locale: "nb_NO",
                  additionalArguments: ["-AMC_UI_TEST_PEAKS", "YES"], previewContainer: "mp4")
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        app.activate()
        element("queue.analysis").click()
        app.radioButtons["Lyd"].click()
        let open = element("analysis.audio.peaks")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.click()
        let run = element("analysis.peaks.run")
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertEqual(run.label, "Analyser lyd")
        XCTAssertEqual(element("analysis.peaks.export").label, "Eksporter JSON")
        run.click()
        XCTAssertTrue(waitForLabelOrValue("Toppintervaller: 0", of: element("analysis.peaks.summary"), timeout: 20))
        XCTAssertTrue(waitForLabelOrValue("Kanalforskjellen overskrider terskelen", of: element("analysis.peaks.balance"), timeout: 5))
        attachWindowScreenshot(named: "Toppnivå og kanalbalanse på norsk")
        element("analysis.peaks.close").click()
    }

    @MainActor
    func testGroupedSilenceSelectionPreviewAndExport() throws {
        try checkGroupedSilence(language: "en", locale: "en_US")
    }

    @MainActor
    func testGroupedSilenceNorwegianSelectionAndPreview() throws {
        try checkGroupedSilence(language: "nb", locale: "nb_NO")
    }

    @MainActor
    private func checkGroupedSilence(language: String, locale: String) throws {
        let norwegian = language == "nb"
        launchApp(generatedFixture: true, language: language, locale: locale,
                  additionalArguments: ["-AMC_UI_TEST_SILENCE", "YES", "-AMC_UI_TEST_GROUPED_SILENCE", "YES"],
                  previewContainer: "mkv")
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        app.activate()
        element("queue.analysis").click()
        app.radioButtons[norwegian ? "Lyd" : "Audio"].click()
        let open = element("analysis.audio.silence")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.click()
        let run = element("analysis.silence.run")
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        let kind = element("analysis.silence.kind")
        kind.click()
        app.menuItems[norwegian ? "Monopar" : "Mono pair"].click()
        XCTAssertTrue(element("analysis.silence.channel.0").exists)
        XCTAssertTrue(element("analysis.silence.channel.1").exists)
        // Each mono track is quiet for longer, but their shared silence is 3–4 s.
        element("analysis.silence.duration").click()
        app.menuItems[norwegian ? "0,50 s" : "0.50 s"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)], timeout: 20), .completed)
        run.click()
        let summary = element("analysis.silence.summary")
        XCTAssertTrue(waitForLabelOrValue(norwegian ? "Oppdagede intervaller: 1" : "Detected intervals: 1", of: summary, timeout: 20))
        let start = element("analysis.silence.start.0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)], timeout: 20), .completed)
        start.click()
        let time = element("analysis.silence.time")
        XCTAssertTrue(waitForLabelOrValue(norwegian ? "3,00 s" : "3.00 s", of: time, timeout: 5))
        XCTAssertFalse(element("analysis.silence.preview.error").exists)
        attachWindowScreenshot(named: "Grouped stereo silence \(language)")

        let export = element("analysis.silence.export")
        XCTAssertTrue(export.isEnabled)
        if !norwegian {
            let reportURL = URL(fileURLWithPath: "/private/tmp/amc-grouped-silence-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: reportURL) }
            export.click()
            let name = app.textFields["saveAsNameTextField"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.click()
            name.typeKey("a", modifierFlags: .command)
            name.typeText(reportURL.lastPathComponent)
            app.typeKey("g", modifierFlags: [.command, .shift])
            let folder = app.textFields["PathTextField"]
            XCTAssertTrue(folder.waitForExistence(timeout: 5))
            folder.typeKey("a", modifierFlags: .command)
            folder.typeText("/private/tmp")
            app.typeKey(.return, modifierFlags: [])
            app.dialogs["save-panel"].buttons["Save"].click()
            let written = NSPredicate { _, _ in FileManager.default.fileExists(atPath: reportURL.path) }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 10), .completed)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
            let context = try XCTUnwrap(report["presentation"] as? [String: Any])
            XCTAssertEqual(context["audioRelativeTrackIndices"] as? [Int], [0, 1])
            XCTAssertEqual(context["channelLayout"] as? String, "stereo")
        }
        kind.click()
        app.menuItems[norwegian ? "5.1 flerkanals mono" : "5.1 multi-mono"].click()
        XCTAssertFalse(summary.exists)
        XCTAssertFalse(export.isEnabled)
        XCTAssertTrue(element("analysis.silence.channel.5").exists)
        // Duplicating a role invalidates both scanning and audition.
        let last = element("analysis.silence.channel.5")
        let first = element("analysis.silence.channel.0")
        let firstTitle = try XCTUnwrap(first.value as? String)
        let lastTitle = try XCTUnwrap(last.value as? String)
        last.click()
        app.menuItems[firstTitle].click()
        XCTAssertFalse(run.isEnabled)
        XCTAssertFalse(export.isEnabled)
        last.click()
        app.menuItems[lastTitle].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: run)], timeout: 20), .completed)
        run.click()
        XCTAssertTrue(summary.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForLabelOrValue(norwegian ? "Oppdagede intervaller: 1" : "Detected intervals: 1", of: summary, timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)], timeout: 20), .completed)
        start.click()
        XCTAssertFalse(element("analysis.silence.preview.error").exists)
        attachWindowScreenshot(named: "Grouped 5.1 silence \(language)")
        kind.click()
        app.menuItems[norwegian ? "Lydspor" : "Audio track"].click()
        XCTAssertFalse(summary.exists)
        XCTAssertTrue(element("analysis.silence.track").exists)
        element("analysis.silence.close").click()
    }

    @MainActor
    func testSilenceAnalysisNavigatesIntervalsAndInvalidatesChangedSettings() throws {
        launchApp(generatedFixture: true, additionalArguments: ["-AMC_UI_TEST_SILENCE", "YES"], previewContainer: "mp4")
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        app.activate()
        element("queue.analysis").click()
        app.radioButtons["Audio"].click()
        let open = element("analysis.audio.silence")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.click()
        let run = element("analysis.silence.run")
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertTrue(element("analysis.silence.track").exists)
        XCTAssertTrue(element("analysis.silence.threshold").exists)
        let export = element("analysis.silence.export")
        XCTAssertTrue(export.exists)
        XCTAssertFalse(export.isEnabled)
        run.click()
        XCTAssertTrue(element("analysis.silence.summary").waitForExistence(timeout: 20))
        XCTAssertTrue(waitForLabelOrValue("Detected intervals: 1", of: element("analysis.silence.summary"), timeout: 5))
        let start = element("analysis.silence.start.0")
        let end = element("analysis.silence.end.0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)], timeout: 20), .completed)
        start.click()
        let time = element("analysis.silence.time")
        let atStart = NSPredicate { _, _ in
            let text = (time.value as? String) ?? time.label
            guard let seconds = Double(text.replacingOccurrences(of: " s", with: "")) else { return false }
            return abs(seconds - 2) < 0.1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: atStart, object: time)], timeout: 5), .completed)
        end.click()
        let atEnd = NSPredicate { _, _ in
            let text = (time.value as? String) ?? time.label
            guard let seconds = Double(text.replacingOccurrences(of: " s", with: "")) else { return false }
            return abs(seconds - 4) < 0.1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: atEnd, object: time)], timeout: 5), .completed)
        attachWindowScreenshot(named: "Silence intervals and paused preview")
        XCTAssertTrue(export.isHittable)
        export.click()
        let nameField = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(export.isEnabled, "Cancelling a save must preserve the report")
        XCTAssertTrue(element("analysis.silence.summary").exists)

        let reportURL = URL(fileURLWithPath: "/private/tmp/amc-silence-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }
        export.click()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(reportURL.lastPathComponent)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let folder = app.textFields["PathTextField"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.typeKey("a", modifierFlags: .command)
        folder.typeText("/private/tmp")
        app.typeKey(.return, modifierFlags: [])
        app.dialogs["save-panel"].buttons["Save"].click()
        let written = NSPredicate { _, _ in FileManager.default.fileExists(atPath: reportURL.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: written, object: nil)], timeout: 10), .completed)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        let presentation = try XCTUnwrap(report["presentation"] as? [String: Any])
        XCTAssertEqual(presentation["audioRelativeTrackIndices"] as? [Int], [0])
        let result = try XCTUnwrap(report["result"] as? [String: Any])
        let intervals = try XCTUnwrap(result["intervals"] as? [[String: Any]])
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(try XCTUnwrap(intervals.first?["start"] as? Double), 2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(intervals.first?["end"] as? Double), 4, accuracy: 0.01)
        XCTAssertEqual((result["settings"] as? [String: Any])?["thresholdDBFS"] as? Double, -50)
        let duration = element("analysis.silence.duration")
        duration.click()
        app.menuItems["5.00 s"].click()
        XCTAssertFalse(element("analysis.silence.summary").exists, "Edited settings must invalidate the old intervals")
        XCTAssertFalse(export.isEnabled)
        run.click()
        XCTAssertTrue(element("analysis.silence.summary").waitForExistence(timeout: 20))
        XCTAssertTrue(waitForLabelOrValue("Detected intervals: 0", of: element("analysis.silence.summary"), timeout: 5))
        XCTAssertFalse(element("analysis.silence.start.0").exists)
        XCTAssertTrue(export.isEnabled, "A complete report with no intervals can be exported")
        element("analysis.silence.close").click()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSilenceAnalysisNorwegianControlsAndReport() throws {
        launchApp(generatedFixture: true, language: "nb", locale: "nb_NO",
                  additionalArguments: ["-AMC_UI_TEST_SILENCE", "YES"], previewContainer: "mp4")
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        app.activate()
        element("queue.analysis").click()
        app.radioButtons["Lyd"].click()
        let open = element("analysis.audio.silence")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        XCTAssertEqual(open.label, "Finn stillhet")
        open.click()
        let run = element("analysis.silence.run")
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        XCTAssertEqual(run.label, "Analyser lyd")
        XCTAssertEqual(element("analysis.silence.export").label, "Eksporter JSON")
        run.click()
        XCTAssertTrue(waitForLabelOrValue("Oppdagede intervaller: 1", of: element("analysis.silence.summary"), timeout: 20))
        XCTAssertTrue(element("analysis.silence.start.0").exists)
        attachWindowScreenshot(named: "Stillhetsanalyse på norsk")
        element("analysis.silence.close").click()
    }

    @MainActor
    func testUnifiedAnalysisPreservesAudioReportAcrossTabsAndEnablesVideoAfterEncoding() throws {
        launchApp(generatedFixture: true)
        defer { terminateAndCleanFixtures() }
        XCTAssertTrue(element("queue.analysis").waitForExistence(timeout: 20))
        app.activate()
        element("queue.analysis").click()
        XCTAssertTrue(element("analysis.tabs").waitForExistence(timeout: 5))
        for metric in ["vmaf", "psnr", "xpsnr", "ssimulacra2"] {
            XCTAssertTrue(element("analysis.metric.\(metric)").exists)
        }
        XCTAssertTrue(element("analysis.vmaf.model").exists)
        XCTAssertFalse(element("analysis.video.run").isEnabled)
        attachWindowScreenshot(named: "Unified analysis - video settings")
        app.radioButtons["Audio"].click()
        let audioRun = element("analysis.audio.run")
        XCTAssertTrue(audioRun.waitForExistence(timeout: 15))
        XCTAssertTrue(element("analysis.audio.kind.1").exists)
        XCTAssertTrue(element("analysis.audio.track.1.0").exists)
        element("analysis.audio.add").click()
        XCTAssertTrue(element("analysis.audio.kind.2").waitForExistence(timeout: 5))
        // The fixture has one audio stream. Adding it twice must be flagged.
        XCTAssertFalse(audioRun.isEnabled)
        element("analysis.audio.remove.2").click()
        XCTAssertFalse(element("analysis.audio.kind.2").exists)
        XCTAssertTrue(audioRun.isEnabled)
        attachWindowScreenshot(named: "Audio analysis - editable card")
        audioRun.click()
        XCTAssertTrue(element("analysis.audio.report").waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Export PDF"].exists)
        attachWindowScreenshot(named: "Unified analysis - audio report")
        app.radioButtons["Video"].click()
        XCTAssertTrue(element("analysis.video.run").exists)
        app.radioButtons["Audio"].click()
        XCTAssertTrue(element("analysis.audio.report").exists, "Switching tabs must preserve completed loudness reports")
        app.sheets.firstMatch.buttons["Close"].click()
        element("toolbar.conversion").click()
        XCTAssertTrue(waitForValue("done", of: element("queue.item"), timeout: 40))
        element("queue.analysis").click()
        let videoRun = element("analysis.video.run")
        XCTAssertTrue(videoRun.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: videoRun)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        attachWindowScreenshot(named: "Unified analysis - ready after encoding")
    }

    @MainActor
    func testRecursiveEncodingCanBeEnabledConfiguredAndDisabled() throws {
        launchApp(generatedFixture: true, defaultPreset: "Lossless (FFV1)")
        defer { terminateAndCleanFixtures() }
        let queueItem = element("queue.item")
        XCTAssertTrue(queueItem.waitForExistence(timeout: 20))
        XCTAssertFalse(element("queue.item.recursiveEncoding").exists)
        app.activate()
        queueItem.rightClick()
        app.menuItems["Recursive Encoding"].click()
        let settings = element("queue.item.recursiveEncoding")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        let count = element("recursiveEncoding.generations")
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        count.click()
        count.typeKey("a", modifierFlags: .command)
        count.typeText("3")
        app.dialogs.buttons["Save"].click()
        XCTAssertTrue(waitForValue("3 generations", of: settings, timeout: 5))
        attachWindowScreenshot(named: "Recursive encoding enabled with lossless preset")
        queueItem.rightClick()
        app.menuItems["Recursive Encoding"].click()
        XCTAssertFalse(settings.exists)
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
    func testIndependentGroupUsesSharedJobsAndCancelsWithoutDuplicateRows() throws {
        launchApp(generatedFixture: true, defaultPreset: "H.264 / AVC", realtimeInput: true,
                  stitching: true, sharedGroup: true)
        defer { terminateAndCleanFixtures() }
        let edit = element("group.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        let conversion = element("toolbar.conversion")
        conversion.click()
        let status = element("group.status")
        XCTAssertTrue(waitForValue("ENCODING", of: status, timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "queue.item").count, 0,
                       "Service updates must claim group items rather than create ordinary queue rows")
        XCTAssertTrue(waitForLabel("Cancel Conversion", of: conversion, timeout: 5))
        conversion.click()
        XCTAssertTrue(waitForValue("CANCELLED", of: status, timeout: 10))
        XCTAssertTrue(waitForLabel("Start Conversion", of: conversion, timeout: 5))
        edit.click()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "group.item."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 2)
        let states = rows.allElementsBoundByIndex.map { $0.identifier.replacingOccurrences(of: "group.item.", with: "") }
        XCTAssertTrue(states.allSatisfy { ["done", "cancelled"].contains($0) }, String(describing: states))
        XCTAssertTrue(states.contains("cancelled"), String(describing: states))
        element("group.done").click()
        app.activate()
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForValue("WAITING", of: status, timeout: 5))
        conversion.click()
        XCTAssertTrue(waitForValue("ENCODING", of: status, timeout: 10))
        conversion.click()
        XCTAssertTrue(waitForValue("CANCELLED", of: status, timeout: 10))


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
    func testFailedDownloadOffersAppManagedUpdatesAndOpensExistingSettingsWindow() throws {
        launchApp(generatedFixture: true, additionalArguments: [
            "-ytdlpBinarySource", "app", "-ytdlpInstalledVersion", "2026.09.01"
        ], ytdlpFailure: true)
        defer { terminateAndCleanFixtures() }

        let updateButton = element("queue.item.ytdlpUpdates")
        XCTAssertTrue(updateButton.waitForExistence(timeout: 20))
        app.activate()
        element("queue.item.errorDetails").click()
        XCTAssertTrue(element("queue.errorDetails.ytdlpUpdates").waitForExistence(timeout: 5))
        attachWindowScreenshot(named: "Failed download update suggestion")
        element("queue.errorDetails.ytdlpUpdates").click()
        let settings = element("settings.root")
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue("ytdlp", of: settings, timeout: 5))

        element("settings.tab.general").click()
        XCTAssertTrue(waitForValue("general", of: settings, timeout: 5))
        updateButton.click()
        XCTAssertTrue(waitForValue("ytdlp", of: settings, timeout: 5))
    }

    @MainActor
    func testFailedDownloadDoesNotOfferAppUpdatesForExternalTools() throws {
        for source in ["homebrew", "custom"] {
            launchApp(generatedFixture: true, additionalArguments: [
                "-ytdlpBinarySource", source,
                "-ytdlpCustomPath", "/usr/bin/true"
            ], ytdlpFailure: true)
            XCTAssertTrue(element("queue.item.errorDetails").waitForExistence(timeout: 20))
            XCTAssertFalse(element("queue.item.ytdlpUpdates").exists)
            app.activate()
            element("queue.item.errorDetails").click()
            XCTAssertTrue(element("queue.errorDetails.text").waitForExistence(timeout: 5))
            XCTAssertFalse(element("queue.errorDetails.ytdlpUpdates").exists)
            app.typeKey(.escape, modifierFlags: [])
            terminateAndCleanFixtures()
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
        sharedGroup: Bool = false,
        cameraCard: Bool = false,
        delayedStitchingLoad: Bool = false,
        missingStitchingSource: Bool = false,
        resetAgentAccess: Bool = false,
        ytdlpFailure: Bool = false,
        instagramPicker: Bool = false,
        twitterPicker: Bool = false,
        tipIndex: Int? = nil
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
        if let tipIndex {
            app.launchEnvironment["AMC_UI_TEST_TIP_INDEX"] = String(tipIndex)
        }
        if twitterPicker {
            app.launchEnvironment["AMC_UI_TEST_TWITTER_PICKER"] = "1"
        }
        if instagramPicker {
            app.launchEnvironment["AMC_UI_TEST_INSTAGRAM_PICKER"] = "1"
        }
        if ytdlpFailure {
            app.launchEnvironment["AMC_UI_TEST_YTDLP_FAILURE"] = "1"
        }
        app.launchEnvironment["AMC_UI_TEST_APPLICATION_JOB_STORE_ID"] = UUID().uuidString
        app.launchEnvironment["AMC_UI_TEST_AGENT_PORT_ID"] = UUID().uuidString
        if resetAgentAccess {
            app.launchEnvironment["AMC_UI_TEST_RESET_AGENT_ACCESS"] = "1"
        }
        if stitching {
            app.launchEnvironment["AMC_UI_TEST_STITCHING"] = "1"
            app.launchEnvironment["AMC_UI_TEST_STITCHING_PRESET"] = defaultPreset
        }
        if sharedGroup { app.launchEnvironment["AMC_UI_TEST_SHARED_GROUP"] = "1" }
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
    private func waitForToggle(_ enabled: Bool, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in
            if let value = element.value as? NSNumber { return value.boolValue == enabled }
            return element.value as? String == (enabled ? "1" : "0")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
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
