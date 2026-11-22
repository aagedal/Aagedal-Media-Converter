// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a shortcut applies. Each context has its own shortcuts, so a key can run
/// different commands in the main window, the trim view and the fullscreen player.
enum ShortcutContext: String, CaseIterable, Identifiable, Sendable {
    case main, trim, fullscreen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .main: String(localized: "Main Window")
        case .trim: String(localized: "Trim View")
        case .fullscreen: String(localized: "Fullscreen Player")
        }
    }
}

/// Groups commands in the shortcut editor's list and colours them on its keyboard.
enum ShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case playback, navigation, trimming, items, views, crop, encoding, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playback: String(localized: "Playback")
        case .navigation: String(localized: "Navigation")
        case .trimming: String(localized: "Trimming")
        case .items: String(localized: "Items")
        case .views: String(localized: "Views")
        case .crop: String(localized: "Crop")
        case .encoding: String(localized: "Encoding")
        case .general: String(localized: "General")
        }
    }
}

private func bind(_ key: String, _ modifiers: ShortcutModifiers = []) -> ShortcutBinding {
    ShortcutBinding(key: key, modifiers: modifiers)
}

/// Every action that a keyboard shortcut can run. Raw values are stored in settings and
/// preset files, so they must not change.
enum ShortcutCommand: String, CaseIterable, Identifiable, Sendable {
    // Main window, handled by ContentView's key monitor.
    case newEncodingGroup = "main.newEncodingGroup"
    case importFiles = "main.importFiles"
    case importCameraCard = "main.importCameraCard"
    case showURLInput = "main.showURLInput"
    case openCapture = "main.openCapture"
    case showShortcuts = "main.showShortcuts"
    case toggleConversion = "main.toggleConversion"
    case resetAll = "main.resetAll"
    case toggleMerge = "main.toggleMerge"
    case toggleWatchFolder = "main.toggleWatchFolder"
    case selectOutputFolder = "main.selectOutputFolder"
    case showPresetQuickSelect = "main.showPresetQuickSelect"
    case selectPreset1 = "main.selectPreset1", selectPreset2 = "main.selectPreset2", selectPreset3 = "main.selectPreset3"
    case selectPreset4 = "main.selectPreset4", selectPreset5 = "main.selectPreset5", selectPreset6 = "main.selectPreset6"
    case selectPreset7 = "main.selectPreset7", selectPreset8 = "main.selectPreset8", selectPreset9 = "main.selectPreset9"
    case selectPreset10 = "main.selectPreset10"
    // Main window, handled by the queue's key monitor while no overlay is open.
    case openTrim = "main.openTrim"
    case playFullscreen = "main.playFullscreen"
    case openTimecode = "main.openTimecode"
    case openAudioRouting = "main.openAudioRouting"
    case openMetadata = "main.openMetadata"
    case openCrop = "main.openCrop"
    case removeSelected = "main.removeSelected"
    case resetSelected = "main.resetSelected"
    case toggleTranscription = "main.toggleTranscription"
    case toggleDateTag = "main.toggleDateTag"
    case toggleMute = "main.toggleMute"
    case toggleUpload = "main.toggleUpload"
    case toggleSourceUpload = "main.toggleSourceUpload"
    case toggleAutoEncode = "main.toggleAutoEncode"
    case selectPrevious = "main.selectPrevious"
    case selectNext = "main.selectNext"
    case moveItemsUp = "main.moveItemsUp"
    case moveItemsDown = "main.moveItemsDown"
    case deselectAll = "main.deselectAll"
    case cycleSort = "main.cycleSort"
    case nextComment = "main.nextComment"
    case previousComment = "main.previousComment"
    case showRandomTip = "main.showRandomTip"
    // Trim view.
    case trimTogglePlayback = "trim.togglePlayback"
    case trimPlayReverse = "trim.playReverse"
    case trimPlayForward = "trim.playForward"
    case trimSlowReverse = "trim.slowReverse"
    case trimSlowForward = "trim.slowForward"
    case trimToggleLoop = "trim.toggleLoop"
    case trimPreviousFrame = "trim.previousFrame"
    case trimNextFrame = "trim.nextFrame"
    case trimBackTenFrames = "trim.backTenFrames"
    case trimForwardTenFrames = "trim.forwardTenFrames"
    case trimSetIn = "trim.setIn"
    case trimSetOut = "trim.setOut"
    case trimClearIn = "trim.clearIn"
    case trimClearOut = "trim.clearOut"
    case trimClearBoth = "trim.clearBoth"
    case trimGoToIn = "trim.goToIn"
    case trimGoToOut = "trim.goToOut"
    case trimToggleTimecodeMode = "trim.toggleTimecodeMode"
    case trimToggleAudioMeter = "trim.toggleAudioMeter"
    case trimCaptureScreenshot = "trim.captureScreenshot"
    case trimOpenFullscreen = "trim.openFullscreen"
    case trimToggleCrop = "trim.toggleCrop"
    case trimCropFree = "trim.cropFree"
    case trimCrop21x9 = "trim.crop21x9"
    case trimCrop16x9 = "trim.crop16x9"
    case trimCrop3x2 = "trim.crop3x2"
    case trimCrop4x3 = "trim.crop4x3"
    case trimCrop1x1 = "trim.crop1x1"
    case trimCrop3x4 = "trim.crop3x4"
    case trimCrop2x3 = "trim.crop2x3"
    case trimCrop9x16 = "trim.crop9x16"
    case trimResetCrop = "trim.resetCrop"
    case trimCropLarger = "trim.cropLarger"
    case trimCropSmaller = "trim.cropSmaller"
    case trimMoveCropLeft = "trim.moveCropLeft"
    case trimMoveCropRight = "trim.moveCropRight"
    case trimMoveCropUp = "trim.moveCropUp"
    case trimMoveCropDown = "trim.moveCropDown"
    // Fullscreen player.
    case fullscreenTogglePlayback = "fullscreen.togglePlayback"
    case fullscreenPlayReverse = "fullscreen.playReverse"
    case fullscreenFastForward = "fullscreen.fastForward"
    case fullscreenSlowReverse = "fullscreen.slowReverse"
    case fullscreenSlowForward = "fullscreen.slowForward"
    case fullscreenPreviousFrame = "fullscreen.previousFrame"
    case fullscreenNextFrame = "fullscreen.nextFrame"
    case fullscreenBackTenFrames = "fullscreen.backTenFrames"
    case fullscreenForwardTenFrames = "fullscreen.forwardTenFrames"
    case fullscreenPreviousItem = "fullscreen.previousItem"
    case fullscreenNextItem = "fullscreen.nextItem"
    case fullscreenSetIn = "fullscreen.setIn"
    case fullscreenSetOut = "fullscreen.setOut"
    case fullscreenClearIn = "fullscreen.clearIn"
    case fullscreenClearOut = "fullscreen.clearOut"
    case fullscreenClearBoth = "fullscreen.clearBoth"
    case fullscreenGoToIn = "fullscreen.goToIn"
    case fullscreenGoToOut = "fullscreen.goToOut"
    case fullscreenToggleAutoNext = "fullscreen.toggleAutoNext"
    case fullscreenToggleLoopQueue = "fullscreen.toggleLoopQueue"
    case fullscreenToggleTimecodeMode = "fullscreen.toggleTimecodeMode"
    case fullscreenToggleMute = "fullscreen.toggleMute"
    case fullscreenVolumeUp = "fullscreen.volumeUp"
    case fullscreenVolumeDown = "fullscreen.volumeDown"
    case fullscreenCaptureScreenshot = "fullscreen.captureScreenshot"

    var id: String { rawValue }

    private struct Info {
        let category: ShortcutCategory
        let title: String
        /// A few words that fit on a key of the shortcut editor's keyboard.
        let shortTitle: String
        let defaults: [ShortcutBinding]
    }

    private var info: Info {
        switch self {
        case .newEncodingGroup: return Info(category: .general, title: String(localized: "New encoding group"), shortTitle: String(localized: "New Group"), defaults: [bind("n", .command)])
        case .importFiles: return Info(category: .general, title: String(localized: "Open import dialogue"), shortTitle: String(localized: "Import"), defaults: [bind("i", .command)])
        case .importCameraCard: return Info(category: .general, title: String(localized: "Import camera card"), shortTitle: String(localized: "Camera Card"), defaults: [bind("i", [.command, .shift])])
        case .showURLInput: return Info(category: .general, title: String(localized: "Show URL input overlay (for downloading)"), shortTitle: String(localized: "Download"), defaults: [bind("d", .command)])
        case .openCapture: return Info(category: .general, title: String(localized: "Open Capture Mode"), shortTitle: String(localized: "Capture"), defaults: [bind("c", [.command, .shift])])
        case .showShortcuts: return Info(category: .general, title: String(localized: "Open Shortcuts help"), shortTitle: String(localized: "Shortcuts"), defaults: [bind("k", .control)])
        case .showRandomTip: return Info(category: .general, title: String(localized: "Show new random tip"), shortTitle: String(localized: "Random Tip"), defaults: [bind("r", .control)])
        case .toggleConversion: return Info(category: .encoding, title: String(localized: "Start/Stop encoding"), shortTitle: String(localized: "Encode"), defaults: [bind("return", .command)])
        case .resetAll: return Info(category: .encoding, title: String(localized: "Reset conversion status of all items"), shortTitle: String(localized: "Reset All"), defaults: [bind("r", [.command, .shift])])
        case .toggleMerge: return Info(category: .encoding, title: String(localized: "Toggle merging of clips"), shortTitle: String(localized: "Merge"), defaults: [bind("m", .option)])
        case .toggleWatchFolder: return Info(category: .encoding, title: String(localized: "Toggle watch folder"), shortTitle: String(localized: "Watch Folder"), defaults: [bind("w", .option)])
        case .selectOutputFolder: return Info(category: .encoding, title: String(localized: "Select output folder"), shortTitle: String(localized: "Output Folder"), defaults: [bind("f", .option)])
        case .showPresetQuickSelect: return Info(category: .encoding, title: String(localized: "Open preset quick-select overlay"), shortTitle: String(localized: "Presets"), defaults: [bind("p", .command)])
        case .selectPreset1, .selectPreset2, .selectPreset3, .selectPreset4, .selectPreset5,
             .selectPreset6, .selectPreset7, .selectPreset8, .selectPreset9, .selectPreset10:
            let number = (presetIndex ?? 0) + 1
            return Info(category: .encoding, title: String(localized: "Select preset \(number)"), shortTitle: String(localized: "Preset \(number)"),
                        defaults: [bind(String(number % 10), .command)])
        case .openTrim: return Info(category: .views, title: String(localized: "Open trim view"), shortTitle: String(localized: "Trim"), defaults: [bind("t", .command), bind("return")])
        case .playFullscreen: return Info(category: .views, title: String(localized: "Open fullscreen player"), shortTitle: String(localized: "Fullscreen"), defaults: [bind("f", .command), bind("space")])
        case .openTimecode: return Info(category: .views, title: String(localized: "Open Timecode override view"), shortTitle: String(localized: "Timecode"), defaults: [bind("t", .option)])
        case .openAudioRouting: return Info(category: .views, title: String(localized: "Open Audio Routing view"), shortTitle: String(localized: "Audio Routing"), defaults: [bind("a", .option)])
        case .openMetadata: return Info(category: .views, title: String(localized: "Open metadata view"), shortTitle: String(localized: "Metadata"), defaults: [bind("i", .option)])
        case .openCrop: return Info(category: .views, title: String(localized: "Open Crop mode"), shortTitle: String(localized: "Crop"), defaults: [bind("c", .option)])
        case .removeSelected: return Info(category: .items, title: String(localized: "Remove selected items from queue"), shortTitle: String(localized: "Remove"), defaults: [bind("delete"), bind("delete", .command)])
        case .resetSelected: return Info(category: .items, title: String(localized: "Reset conversion status of selected items"), shortTitle: String(localized: "Reset"), defaults: [bind("r", .command)])
        case .toggleTranscription: return Info(category: .items, title: String(localized: "Toggle transcription on selected items"), shortTitle: String(localized: "Transcribe"), defaults: [bind("t", [.command, .option])])
        case .toggleDateTag: return Info(category: .items, title: String(localized: "Toggle metadata date tag on selected items"), shortTitle: String(localized: "Date Tag"), defaults: [bind("d", .control)])
        case .toggleMute: return Info(category: .items, title: String(localized: "Toggle mute on selected items"), shortTitle: String(localized: "Mute"), defaults: [bind("m", .control)])
        case .toggleUpload: return Info(category: .items, title: String(localized: "Toggle upload on selected items"), shortTitle: String(localized: "Upload"), defaults: [bind("u", .command)])
        case .toggleSourceUpload: return Info(category: .items, title: String(localized: "Toggle source file upload on selected items"), shortTitle: String(localized: "Source Upload"), defaults: [bind("u", [.command, .option])])
        case .toggleAutoEncode: return Info(category: .items, title: String(localized: "Toggle auto-encode on selected items"), shortTitle: String(localized: "Auto-Encode"), defaults: [bind("e", .command)])
        case .selectPrevious: return Info(category: .navigation, title: String(localized: "Move selection up"), shortTitle: String(localized: "Previous Item"), defaults: [bind("up")])
        case .selectNext: return Info(category: .navigation, title: String(localized: "Move selection down"), shortTitle: String(localized: "Next Item"), defaults: [bind("down")])
        case .moveItemsUp: return Info(category: .navigation, title: String(localized: "Move selected item(s) up in queue"), shortTitle: String(localized: "Move Up"), defaults: [bind("up", .command)])
        case .moveItemsDown: return Info(category: .navigation, title: String(localized: "Move selected item(s) down in queue"), shortTitle: String(localized: "Move Down"), defaults: [bind("down", .command)])
        case .deselectAll: return Info(category: .navigation, title: String(localized: "Deselect all items"), shortTitle: String(localized: "Deselect"), defaults: [bind("d", .option)])
        case .cycleSort: return Info(category: .navigation, title: String(localized: "Cycle through sort modes"), shortTitle: String(localized: "Sort"), defaults: [bind("s", .control)])
        case .nextComment: return Info(category: .navigation, title: String(localized: "Select comment field of first clip, or cycle to next"), shortTitle: String(localized: "Next Comment"), defaults: [bind("tab")])
        case .previousComment: return Info(category: .navigation, title: String(localized: "Select comment field of last clip, or cycle to previous"), shortTitle: String(localized: "Previous Comment"), defaults: [bind("tab", .shift)])

        case .trimTogglePlayback: return Info(category: .playback, title: String(localized: "Toggle play/pause"), shortTitle: String(localized: "Play / Pause"), defaults: [bind("space"), bind("k")])
        case .trimPlayReverse: return Info(category: .playback, title: String(localized: "Play backwards"), shortTitle: String(localized: "Reverse"), defaults: [bind("j")])
        case .trimPlayForward: return Info(category: .playback, title: String(localized: "Play forwards"), shortTitle: String(localized: "Forward"), defaults: [bind("l")])
        case .trimSlowReverse: return Info(category: .playback, title: String(localized: "Slow reverse"), shortTitle: String(localized: "Slow Reverse"), defaults: [bind("j", .option)])
        case .trimSlowForward: return Info(category: .playback, title: String(localized: "Slow forward"), shortTitle: String(localized: "Slow Forward"), defaults: [bind("l", .option)])
        case .trimToggleLoop: return Info(category: .playback, title: String(localized: "Toggle loop mode"), shortTitle: String(localized: "Loop"), defaults: [bind("l", .command)])
        case .trimPreviousFrame: return Info(category: .navigation, title: String(localized: "Go to previous frame"), shortTitle: String(localized: "Previous Frame"), defaults: [bind("left")])
        case .trimNextFrame: return Info(category: .navigation, title: String(localized: "Go to next frame"), shortTitle: String(localized: "Next Frame"), defaults: [bind("right")])
        case .trimBackTenFrames: return Info(category: .navigation, title: String(localized: "Seek back 10 frames"), shortTitle: String(localized: "−10 Frames"), defaults: [bind("up")])
        case .trimForwardTenFrames: return Info(category: .navigation, title: String(localized: "Seek forward 10 frames"), shortTitle: String(localized: "+10 Frames"), defaults: [bind("down")])
        case .trimSetIn: return Info(category: .trimming, title: String(localized: "Set in point"), shortTitle: String(localized: "Mark In"), defaults: [bind("i")])
        case .trimSetOut: return Info(category: .trimming, title: String(localized: "Set out point"), shortTitle: String(localized: "Mark Out"), defaults: [bind("o")])
        case .trimClearIn: return Info(category: .trimming, title: String(localized: "Clear trim start (reset to beginning)"), shortTitle: String(localized: "Clear In"), defaults: [bind("i", .option)])
        case .trimClearOut: return Info(category: .trimming, title: String(localized: "Clear trim end (reset to end)"), shortTitle: String(localized: "Clear Out"), defaults: [bind("o", .option)])
        case .trimClearBoth: return Info(category: .trimming, title: String(localized: "Clear both trim points"), shortTitle: String(localized: "Clear In/Out"), defaults: [bind("x", .option)])
        case .trimGoToIn: return Info(category: .trimming, title: String(localized: "Jump to trim in-point"), shortTitle: String(localized: "Go to In"), defaults: [bind("i", .shift)])
        case .trimGoToOut: return Info(category: .trimming, title: String(localized: "Jump to trim out-point"), shortTitle: String(localized: "Go to Out"), defaults: [bind("o", .shift)])
        case .trimToggleTimecodeMode: return Info(category: .views, title: String(localized: "Toggle timecode display mode"), shortTitle: String(localized: "Timecode"), defaults: [bind("t")])
        case .trimToggleAudioMeter: return Info(category: .views, title: String(localized: "Toggle audio meter"), shortTitle: String(localized: "Audio Meter"), defaults: [bind("a", .command)])
        case .trimCaptureScreenshot: return Info(category: .general, title: String(localized: "Capture screenshot"), shortTitle: String(localized: "Screenshot"), defaults: [bind("s", .command)])
        case .trimOpenFullscreen: return Info(category: .views, title: String(localized: "Toggle fullscreen"), shortTitle: String(localized: "Fullscreen"), defaults: [bind("f", .command)])
        case .trimToggleCrop: return Info(category: .crop, title: String(localized: "Enter crop tool"), shortTitle: String(localized: "Crop"), defaults: [bind("c")])
        case .trimCropFree: return Info(category: .crop, title: String(localized: "Free aspect ratio"), shortTitle: String(localized: "Free"), defaults: [bind("1", .command)])
        case .trimCrop21x9: return Info(category: .crop, title: String(localized: "21:9 aspect ratio"), shortTitle: "21:9", defaults: [bind("2", .command)])
        case .trimCrop16x9: return Info(category: .crop, title: String(localized: "16:9 aspect ratio"), shortTitle: "16:9", defaults: [bind("3", .command)])
        case .trimCrop3x2: return Info(category: .crop, title: String(localized: "3:2 aspect ratio"), shortTitle: "3:2", defaults: [bind("4", .command)])
        case .trimCrop4x3: return Info(category: .crop, title: String(localized: "4:3 aspect ratio"), shortTitle: "4:3", defaults: [bind("5", .command)])
        case .trimCrop1x1: return Info(category: .crop, title: String(localized: "1:1 (Square) aspect ratio"), shortTitle: "1:1", defaults: [bind("6", .command)])
        case .trimCrop3x4: return Info(category: .crop, title: String(localized: "3:4 aspect ratio"), shortTitle: "3:4", defaults: [bind("7", .command)])
        case .trimCrop2x3: return Info(category: .crop, title: String(localized: "2:3 aspect ratio"), shortTitle: "2:3", defaults: [bind("8", .command)])
        case .trimCrop9x16: return Info(category: .crop, title: String(localized: "9:16 (Vertical) aspect ratio"), shortTitle: "9:16", defaults: [bind("9", .command)])
        case .trimResetCrop: return Info(category: .crop, title: String(localized: "Reset crop"), shortTitle: String(localized: "Reset Crop"), defaults: [bind("0", .command)])
        case .trimCropLarger: return Info(category: .crop, title: String(localized: "Scale crop box larger"), shortTitle: String(localized: "Crop Larger"), defaults: [bind("=", .command)])
        case .trimCropSmaller: return Info(category: .crop, title: String(localized: "Scale crop box smaller"), shortTitle: String(localized: "Crop Smaller"), defaults: [bind("-", .command)])
        case .trimMoveCropLeft: return Info(category: .crop, title: String(localized: "Move crop box left"), shortTitle: String(localized: "Crop ←"), defaults: [bind("left", .command)])
        case .trimMoveCropRight: return Info(category: .crop, title: String(localized: "Move crop box right"), shortTitle: String(localized: "Crop →"), defaults: [bind("right", .command)])
        case .trimMoveCropUp: return Info(category: .crop, title: String(localized: "Move crop box up"), shortTitle: String(localized: "Crop ↑"), defaults: [bind("up", .command)])
        case .trimMoveCropDown: return Info(category: .crop, title: String(localized: "Move crop box down"), shortTitle: String(localized: "Crop ↓"), defaults: [bind("down", .command)])

        case .fullscreenTogglePlayback: return Info(category: .playback, title: String(localized: "Toggle playback"), shortTitle: String(localized: "Play / Pause"), defaults: [bind("space"), bind("k")])
        case .fullscreenPlayReverse: return Info(category: .playback, title: String(localized: "Start reverse playback"), shortTitle: String(localized: "Reverse"), defaults: [bind("j")])
        case .fullscreenFastForward: return Info(category: .playback, title: String(localized: "Fast forward"), shortTitle: String(localized: "Forward"), defaults: [bind("l")])
        case .fullscreenSlowReverse: return Info(category: .playback, title: String(localized: "Slow reverse"), shortTitle: String(localized: "Slow Reverse"), defaults: [bind("j", .option)])
        case .fullscreenSlowForward: return Info(category: .playback, title: String(localized: "Slow forward"), shortTitle: String(localized: "Slow Forward"), defaults: [bind("l", .option)])
        case .fullscreenPreviousFrame: return Info(category: .navigation, title: String(localized: "Seek back 1 frame"), shortTitle: String(localized: "Previous Frame"), defaults: [bind("left")])
        case .fullscreenNextFrame: return Info(category: .navigation, title: String(localized: "Seek forward 1 frame"), shortTitle: String(localized: "Next Frame"), defaults: [bind("right")])
        case .fullscreenBackTenFrames: return Info(category: .navigation, title: String(localized: "Seek back 10 frames"), shortTitle: String(localized: "−10 Frames"), defaults: [bind("up")])
        case .fullscreenForwardTenFrames: return Info(category: .navigation, title: String(localized: "Seek forward 10 frames"), shortTitle: String(localized: "+10 Frames"), defaults: [bind("down")])
        case .fullscreenPreviousItem: return Info(category: .navigation, title: String(localized: "Go to previous item in queue"), shortTitle: String(localized: "Previous Item"), defaults: [bind("b", .command)])
        case .fullscreenNextItem: return Info(category: .navigation, title: String(localized: "Go to next item in queue"), shortTitle: String(localized: "Next Item"), defaults: [bind("n", .command)])
        case .fullscreenSetIn: return Info(category: .trimming, title: String(localized: "Set in point"), shortTitle: String(localized: "Mark In"), defaults: [bind("i")])
        case .fullscreenSetOut: return Info(category: .trimming, title: String(localized: "Set out point"), shortTitle: String(localized: "Mark Out"), defaults: [bind("o")])
        case .fullscreenClearIn: return Info(category: .trimming, title: String(localized: "Clear trim start (reset to beginning)"), shortTitle: String(localized: "Clear In"), defaults: [bind("i", .option)])
        case .fullscreenClearOut: return Info(category: .trimming, title: String(localized: "Clear trim end (reset to end)"), shortTitle: String(localized: "Clear Out"), defaults: [bind("o", .option)])
        case .fullscreenClearBoth: return Info(category: .trimming, title: String(localized: "Clear both trim points"), shortTitle: String(localized: "Clear In/Out"), defaults: [bind("x", .option)])
        case .fullscreenGoToIn: return Info(category: .trimming, title: String(localized: "Jump to trim in-point"), shortTitle: String(localized: "Go to In"), defaults: [bind("i", .shift)])
        case .fullscreenGoToOut: return Info(category: .trimming, title: String(localized: "Jump to trim out-point"), shortTitle: String(localized: "Go to Out"), defaults: [bind("o", .shift)])
        case .fullscreenToggleAutoNext: return Info(category: .playback, title: String(localized: "Toggle Auto Next mode"), shortTitle: String(localized: "Auto Next"), defaults: [bind("a")])
        case .fullscreenToggleLoopQueue: return Info(category: .playback, title: String(localized: "Toggle Loop Queue (requires Auto Next)"), shortTitle: String(localized: "Loop Queue"), defaults: [bind("l", .command)])
        case .fullscreenToggleTimecodeMode: return Info(category: .views, title: String(localized: "Toggle timecode mode"), shortTitle: String(localized: "Timecode"), defaults: [bind("t")])
        case .fullscreenToggleMute: return Info(category: .views, title: String(localized: "Toggle mute"), shortTitle: String(localized: "Mute"), defaults: [bind("m")])
        case .fullscreenVolumeUp: return Info(category: .views, title: String(localized: "Raise volume by 10 percent"), shortTitle: String(localized: "Volume Up"), defaults: [bind("up", .command)])
        case .fullscreenVolumeDown: return Info(category: .views, title: String(localized: "Lower volume by 10 percent"), shortTitle: String(localized: "Volume Down"), defaults: [bind("down", .command)])
        case .fullscreenCaptureScreenshot: return Info(category: .general, title: String(localized: "Capture screenshot"), shortTitle: String(localized: "Screenshot"), defaults: [bind("s", .command)])
        }
    }

    var context: ShortcutContext {
        if rawValue.hasPrefix("trim.") { return .trim }
        if rawValue.hasPrefix("fullscreen.") { return .fullscreen }
        return .main
    }
    var category: ShortcutCategory { info.category }
    var title: String { info.title }
    var shortTitle: String { info.shortTitle }
    /// The shortcuts a command starts with; the second slot is often free for the user.
    var defaultBindings: [ShortcutBinding] { info.defaults }

    /// Main-window commands that the queue's key monitor runs. It stands aside while an
    /// overlay is open, so these may use keys that overlays also need.
    var isQueueCommand: Bool {
        switch self {
        case .openTrim, .playFullscreen, .openTimecode, .openAudioRouting, .openMetadata, .openCrop, .removeSelected,
             .resetSelected, .toggleTranscription, .toggleDateTag, .toggleMute, .toggleUpload, .toggleSourceUpload,
             .toggleAutoEncode, .selectPrevious, .selectNext, .moveItemsUp, .moveItemsDown, .deselectAll, .cycleSort,
             .nextComment, .previousComment, .showRandomTip:
            return true
        default:
            return false
        }
    }
    /// Commands that may use a bare or Shift-only key. The players have no text entry
    /// apart from timecode, and queue keys are left to focused text.
    var allowsUnmodifiedKey: Bool { context != .main || isQueueCommand }
    /// Whether a shortcut runs this command while a text field has focus. Tab moves
    /// between the queue's comment fields, so the comment commands take it from inside them;
    /// any other key bound to them stays with the text.
    func runsWhileEditingText(_ binding: ShortcutBinding) -> Bool {
        ((self == .nextComment || self == .previousComment) && binding.normalized.key == "tab") || binding.isSafeDuringTextEditing
    }

    /// The preset position (0 for the first) that a Select Preset command picks.
    var presetIndex: Int? {
        let presets: [ShortcutCommand] = [.selectPreset1, .selectPreset2, .selectPreset3, .selectPreset4, .selectPreset5,
                                          .selectPreset6, .selectPreset7, .selectPreset8, .selectPreset9, .selectPreset10]
        return presets.firstIndex(of: self)
    }
    /// The aspect ratio a trim-view crop command locks to.
    var cropAspectRatio: AspectRatio? {
        switch self {
        case .trimCropFree: .free
        case .trimCrop21x9: .ratio21_9
        case .trimCrop16x9: .ratio16_9
        case .trimCrop3x2: .ratio3_2
        case .trimCrop4x3: .ratio4_3
        case .trimCrop1x1: .ratio1_1
        case .trimCrop3x4: .ratio3_4
        case .trimCrop2x3: .ratio2_3
        case .trimCrop9x16: .ratio9_16
        default: nil
        }
    }
}
