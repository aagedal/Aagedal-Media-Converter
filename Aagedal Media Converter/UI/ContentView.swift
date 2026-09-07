// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AVFoundation
import AppKit
import Carbon.HIToolbox
import OSLog

private final class MergeCompatibilityScheduler: ObservableObject {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func schedule(after delayNanoseconds: UInt64 = 200_000_000, action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await action()
        }
    }
}

@MainActor
final class FileImportTaskCoordinator: ObservableObject {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func start(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.tasks.removeValue(forKey: id)
        }
        tasks[id] = task
    }

    func cancelAll() {
        let activeTasks = Array(tasks.values)
        tasks.removeAll()
        for task in activeTasks {
            task.cancel()
        }
    }
}

struct ContentView: View {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ContentView")
    @Environment(\.openSettings) private var openSettings
    @State private var droppedFiles: [VideoItem] = []
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path {
        didSet {
            // Update the currentOutputFolder when outputFolder changes
            currentOutputFolder = URL(fileURLWithPath: outputFolder)
        }
    }
    @State private var currentOutputFolder: URL = AppConstants.defaultOutputDirectory {
        didSet {
            // Update the stored path when currentOutputFolder changes programmatically
            if currentOutputFolder.path != outputFolder {
                outputFolder = currentOutputFolder.path
            }
            refreshExpectedOutputURLs(for: selectedPreset)
        }
    }
    @AppStorage(AppConstants.downloadFolderKey) private var downloadFolder = AppConstants.defaultDownloadDirectory.path

    @State private var isConverting: Bool = false
    @State private var overallProgress: Double = 0.0
    @State private var isFileImporterPresented = false
#if DEBUG
    @State private var hasHandledUITestFixtureLaunch = false
#endif
    /// Set when a convert App Intent opened the file importer with no file input
    /// (Spotlight/Siri phrase). After the user picks files, conversion starts.
    @State private var pendingConvertAfterImport = false
    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue
    @AppStorage(AppConstants.animatedStillFormatKey) private var animatedStillFormat = AppConstants.defaultAnimatedStillFormat
    @AppStorage(AppConstants.audioOnlyFormatKey) private var audioOnlyFormat = AppConstants.defaultAudioOnlyFormat
    @State private var selectedPreset: ExportPreset = .videoLoop
    @State private var hasInitializedPreset = false
    @State private var hasUserChangedPreset = false
    @State private var dockProgressUpdater = DockProgressUpdater()
    @State private var progressTask: Task<Void, Never>?
    @StateObject private var fileImportTaskCoordinator = FileImportTaskCoordinator()
    private let presetManager = PresetManager.shared
    @AppStorage(AppConstants.videoLoopDefaultMutedKey) private var videoLoopDefaultMuted = AppConstants.defaultVideoLoopMuted
    @AppStorage(AppConstants.watchFolderModeKey) private var watchFolderModeEnabled = false
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @AppStorage(AppConstants.watchFolderAutoActivateOnLaunchKey) private var watchFolderAutoActivateOnLaunch = false
    @State private var hasAppliedWatchFolderLaunchActivation = false
    @StateObject private var watchFolderCoordinator = WatchFolderCoordinator()
    @State private var mergeClipsEnabled = false
    @State private var mergeClipsAvailable = false
    @State private var mergeClipsTooltip = "Add at least two compatible clips to enable merging."
    @StateObject private var mergeCompatibilityScheduler = MergeCompatibilityScheduler()
    
    @State private var encodingGroups: [EncodingGroup] = []
    @State private var queueOrder: [UUID] = []

    @StateObject private var updateChecker = UpdateChecker.shared
    @State private var showUpdateNotification = false
    @State private var updateNotificationTask: Task<Void, Never>?
    @State private var settingsSyncNotice: String?
    @State private var settingsSyncNoticeTask: Task<Void, Never>?
    @State private var settingsImportAlertMessage: String?
    @State private var showSettingsImportAlert = false
    @State private var showURLInputOverlay = false
    @State private var showPresetQuickSelect = false
    @State private var showYTDLPNotConfiguredAlert = false
    // showCaptureSheet removed — capture mode now uses CaptureOverlayWindowController

    // Keyboard shortcut sheet states - using optional UUID directly for item-based sheet presentation
    // When non-nil, the corresponding sheet is presented. Set to nil to dismiss.
    @State private var trimSheetItemID: UUID?
    @State private var trimWithCropSheetItemID: UUID?
    @State private var timecodeSheetItemID: UUID?
    @State private var audioConfigSheetItemID: UUID?
    @State private var dcpMetadataSheetItemID: UUID?
    @State private var imfMetadataSheetItemID: UUID?
    
    // Using shared AppConstants for supported file types
    private var supportedVideoTypes: [UTType] {
        var types = AppConstants.supportedVideoTypes.compactMap { UTType($0) }
        // Allow folder selection for image sequence imports
        types.append(.folder)
        // Allow image file selection for image sequence imports
        if let pngType = UTType("public.png") { types.append(pngType) }
        if let jpegType = UTType("public.jpeg") { types.append(jpegType) }
        if let tiffType = UTType("public.tiff") { types.append(tiffType) }
        types.append(.image)
        return types
    }
    
    // Only allow starting conversion when at least one item is still waiting
    private var canStartConversion: Bool {
        droppedFiles.contains { $0.status == .waiting }
        || encodingGroups.contains { $0.items.contains { $0.status == .waiting } }
    }

    private var hasResettableItems: Bool {
        droppedFiles.contains { $0.status != .waiting }
        || encodingGroups.contains { $0.items.contains { $0.status != .waiting } }
    }

    private var allConversionItems: [VideoItem] {
        droppedFiles + encodingGroups.flatMap { $0.items }
    }

    /// Whether a VideoItem with the given ID exists in either the ungrouped queue or any encoding group.
    private func itemExists(id: UUID) -> Bool {
        droppedFiles.contains(where: { $0.id == id }) ||
            encodingGroups.contains(where: { $0.items.contains(where: { $0.id == id }) })
    }

    /// Brings the main app window to the front so a SwiftUI `.sheet` attached to
    /// ContentView is actually visible when triggered from a secondary window
    /// (e.g. the Group Editor). The Group Editor uses `setFrameAutosaveName`
    /// "GroupEditorWindow" so we exclude it explicitly; any other titled,
    /// canBecomeMain window is treated as the host.
    private func bringMainWindowForward() {
        let main = NSApp.windows.first { window in
            guard window.canBecomeMain, window.isVisible else { return false }
            if window.frameAutosaveName == "GroupEditorWindow" { return false }
            return window.styleMask.contains(.titled)
        }
        main?.makeKeyAndOrderFront(nil)
    }

    /// Whether any modal sheet or overlay is currently presented.
    private var anySheetOrOverlayOpen: Bool {
        trimSheetItemID != nil ||
            trimWithCropSheetItemID != nil ||
            timecodeSheetItemID != nil ||
            audioConfigSheetItemID != nil ||
            dcpMetadataSheetItemID != nil ||
            imfMetadataSheetItemID != nil ||
            CaptureOverlayWindowController.shared.isShowing ||
            showURLInputOverlay ||
            showPresetQuickSelect
    }

    /// Applies a preset change with all associated side effects (output URL refresh, merge evaluation, auto-mute).
    private func applyPresetChange(_ preset: ExportPreset) {
        let oldValue = selectedPreset
        hasUserChangedPreset = true
        selectedPreset = preset
        refreshExpectedOutputURLs(for: preset)
        Task { @MainActor in
            await Task.yield()
            self.scheduleMergeCompatibilityEvaluation()
        }
        presetManager.applyAutoMuteSettings(
            to: &droppedFiles,
            oldPreset: oldValue,
            newPreset: preset,
            videoLoopDefaultMuted: videoLoopDefaultMuted
        )
    }

    private var currentConvertingItem: VideoItem? {
        allConversionItems.first { $0.status == .converting }
    }

    private var completedFileCount: Int {
        allConversionItems.filter { $0.status == .done }.count
    }

    private var totalActiveFileCount: Int {
        allConversionItems.filter { $0.status != .cancelled && $0.status != .failed }.count
    }

    private var computedOverallProgress: Double {
        let activeItems = allConversionItems.filter { $0.status != .cancelled && $0.status != .failed }
        guard !activeItems.isEmpty else { return 0.0 }
        let totalDuration = activeItems.reduce(0.0) { $0 + $1.trimmedDuration }
        guard totalDuration > 0 else { return 0.0 }
        let completedDuration = activeItems.reduce(0.0) { sum, file in
            switch file.status {
            case .done: return sum + file.trimmedDuration
            case .converting: return sum + file.trimmedDuration * file.progress
            default: return sum
            }
        }
        return min(max(completedDuration / totalDuration, 0.0), 1.0)
    }

    /// Ensures queueOrder is in sync with droppedFiles and encodingGroups.
    /// Removes stale IDs and appends any missing ones.
    private func sanitizeQueueOrder() {
        let validIDs = Set(droppedFiles.map(\.id)).union(encodingGroups.map(\.id))
        queueOrder.removeAll { !validIDs.contains($0) }
        let ordered = Set(queueOrder)
        for item in droppedFiles where !ordered.contains(item.id) {
            queueOrder.append(item.id)
        }
        for group in encodingGroups where !ordered.contains(group.id) {
            queueOrder.append(group.id)
        }
    }

    /// Presets that are currently visible in the picker
    private var visiblePresets: [ExportPreset] {
        presetManager.visiblePresets
    }

    private var downloadFolderURL: URL {
        let url = URL(fileURLWithPath: downloadFolder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var fileListView: some View {
        VideoFileListView(
            droppedFiles: $droppedFiles,
            encodingGroups: $encodingGroups,
            currentProgress: $overallProgress,
            onFileImport: { isFileImporterPresented = true },
            onDoubleClick: { isFileImporterPresented = true },
            onDelete: handleFileDeletion,
            onReset: handleFileReset,
            preset: selectedPreset,
            mergeClipsEnabled: mergeClipsEnabled,
            mergeClipsAvailable: mergeClipsAvailable,
            onOpenTrim: { [self] id in
                guard itemExists(id: id) else { return }
                trimSheetItemID = id
            },
            onOpenTrimWithCrop: { [self] id in
                guard itemExists(id: id) else { return }
                trimWithCropSheetItemID = id
            },
            onOpenTimecode: { [self] id in
                guard itemExists(id: id) else { return }
                timecodeSheetItemID = id
            },
            onOpenAudioConfig: { [self] id in
                guard itemExists(id: id) else { return }
                audioConfigSheetItemID = id
            },
            onOpenMetadata: { [self] ids in
                // Gather all items from both ungrouped queue and encoding groups
                let allItems = droppedFiles + encodingGroups.flatMap { $0.items }
                let validIDs = ids.filter { id in allItems.contains(where: { $0.id == id }) }
                guard !validIDs.isEmpty else { return }
                MetadataWindowState.shared.selectedItemIDs = Set(validIDs)
                MetadataWindowState.shared.allItems = allItems
                MetadataWindowController.shared.showWindow()
            },
            onOpenDCPMetadata: { [self] id in
                guard itemExists(id: id) else { return }
                dcpMetadataSheetItemID = id
            },
            onOpenIMFMetadata: { [self] id in
                guard itemExists(id: id) else { return }
                imfMetadataSheetItemID = id
            },
            onToggleDateTag: { index in
                droppedFiles[index].includeDateTag.toggle()
            },
            onPlayFullscreen: { [self] id in
                let allItems = droppedFiles + encodingGroups.flatMap { $0.items }
                if let selectedItem = allItems.first(where: { $0.id == id }) {
                    if FullscreenPlayerWindowController.shared.isCurrentlyPlaying(itemID: selectedItem.id) {
                        return
                    }
                    FullscreenPlayerWindowController.shared.openFullscreenPlayer(
                        for: selectedItem,
                        in: droppedFiles,
                        onItemTrimChanged: { [self] itemID, trimStart, trimEnd in
                            if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                                droppedFiles[idx].trimStart = trimStart
                                droppedFiles[idx].trimEnd = trimEnd
                            }
                        }
                    )
                }
            },
            onURLDrop: { urlString in
                handleURLDownload(urlString, liveFromStart: false, audioOnly: false)
            },
            onRenameOutputFileName: { id, newName in
                handleOutputFileNameOverride(itemID: id, newName: newName)
            },
            encodeOnly: { itemID in
                await encodeOnlyItem(itemID: itemID)
            },
            encodeOnlyGroup: { groupID in
                await encodeOnlyGroup(groupID: groupID)
            },
            onDeleteGroup: { groupID in
                // Cancel any in-flight uploads for items in this group before
                // removing the group. Without this, rclone keeps running and its
                // progress callback fires into an items array that no longer
                // contains the uploading item (caused index-out-of-range crash).
                if let group = encodingGroups.first(where: { $0.id == groupID }) {
                    for item in group.items where item.uploadStatus.isActive {
                        Task { await UploadManager.shared.cancelUpload(itemID: item.id) }
                    }
                }
                encodingGroups.removeAll { $0.id == groupID }
                queueOrder.removeAll { $0 == groupID }
            },
            onCancelGroupUpload: { groupID in
                guard let group = encodingGroups.first(where: { $0.id == groupID }) else { return }
                for item in group.items where item.uploadStatus.isActive {
                    Task { await UploadManager.shared.cancelUpload(itemID: item.id) }
                }
            },
            onAddFilesToGroup: { groupID in
                Task { await addFilesToGroup(groupID: groupID) }
            },
            onResetGroup: { groupID in
                guard !isConverting else { return }
                if let gi = encodingGroups.firstIndex(where: { $0.id == groupID }) {
                    for ii in encodingGroups[gi].items.indices where encodingGroups[gi].items[ii].status != .waiting {
                        encodingGroups[gi].items[ii].resetConversionState()
                    }
                }
            },
            onFileDropToGroup: { groupID, urls in
                Task { await addURLsToGroup(groupID: groupID, urls: urls) }
            },
            queueOrder: $queueOrder,
            onReorder: { movedIDs, destIndex in
                // Remove moved IDs from current position
                queueOrder.removeAll { movedIDs.contains($0) }
                // Insert at destination (clamped)
                let insertAt = max(0, min(destIndex, queueOrder.count))
                queueOrder.insert(contentsOf: movedIDs, at: insertAt)
            },
            onQueueSync: { sanitizeQueueOrder() },
            onOpenGroupEditor: { groupID in
                GroupEditorWindowController.shared.open(
                    groupID: groupID,
                    groups: $encodingGroups,
                    droppedFiles: $droppedFiles,
                    queueOrder: $queueOrder,
                    globalPreset: selectedPreset,
                    onAddFiles: { id in
                        Task { await addFilesToGroup(groupID: id) }
                    },
                    onOpenTrim: { itemID in
                        guard itemExists(id: itemID) else { return }
                        // Trim is presented as a SwiftUI .sheet on ContentView
                        // (the main window). When invoked from the editor window
                        // the sheet would open behind it — bring the main window
                        // forward so the sheet is actually visible.
                        bringMainWindowForward()
                        trimSheetItemID = itemID
                    },
                    onPlayFullscreen: { itemID in
                        let allItems = droppedFiles + encodingGroups.flatMap { $0.items }
                        guard let selected = allItems.first(where: { $0.id == itemID }) else { return }
                        if FullscreenPlayerWindowController.shared.isCurrentlyPlaying(itemID: selected.id) {
                            return
                        }
                        FullscreenPlayerWindowController.shared.openFullscreenPlayer(
                            for: selected,
                            in: droppedFiles,
                            onItemTrimChanged: { changedID, trimStart, trimEnd in
                                if let idx = droppedFiles.firstIndex(where: { $0.id == changedID }) {
                                    droppedFiles[idx].trimStart = trimStart
                                    droppedFiles[idx].trimEnd = trimEnd
                                }
                            }
                        )
                    },
                    onOpenMetadata: { ids in
                        let allItems = droppedFiles + encodingGroups.flatMap { $0.items }
                        let validIDs = ids.filter { id in allItems.contains(where: { $0.id == id }) }
                        guard !validIDs.isEmpty else { return }
                        MetadataWindowState.shared.selectedItemIDs = Set(validIDs)
                        MetadataWindowState.shared.allItems = allItems
                        MetadataWindowController.shared.showWindow()
                    }
                )
            },
            onOpenSettingsTab: { tab in
                UserDefaults.standard.set(tab, forKey: AppConstants.settingsTabToOpenKey)
                openSettings()
            },
            disableKeyboardNavigation: anySheetOrOverlayOpen
        )
    }

    private func handleFileDeletion(_ indexSet: IndexSet) {
        let itemsToRemove = indexSet.compactMap { index -> VideoItem? in
            guard index < droppedFiles.count else { return nil }
            return droppedFiles[index]
        }

        for item in itemsToRemove {
            if item.isDownloading {
                DownloadManager.shared.cancelDownload(itemID: item.id)
            } else if let _ = item.scheduledDownloadTime {
                DownloadManager.shared.cancelScheduledDownload(itemID: item.id)
            }
            if item.subtitleStatus.isInProgress {
                cancelSubtitleGeneration(for: item)
            }
            // Cancel in-progress preview generation (thumbnails/waveforms) to free CPU
            Task { await PreviewAssetGenerator.shared.cancelGeneration(for: item.url) }
            if item.analyticsStatus.isInProgress {
                Task { await AnalyticsService.shared.cancelAnalysis() }
            }
            if item.uploadStatus == .uploading {
                Task { await UploadManager.shared.cancelUpload(itemID: item.id) }
            }
        }

        // Note: Cache cleanup is handled by the user's cleanup policy (on app launch or manually)
        // We don't delete cache immediately when files are removed, allowing re-import to reuse cached assets
        let removedIDs = Set(itemsToRemove.map(\.id))
        queueOrder.removeAll { removedIDs.contains($0) }
        droppedFiles.remove(atOffsets: indexSet)
    }

    private func handleFileReset(_ index: Int, optionKeyPressed: Bool = false) {
        if index < droppedFiles.count {
            droppedFiles[index].resetConversionState()
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)

            // Determine whether to clear settings based on preference and Option key
            let resetClearsSettings = UserDefaults.standard.bool(forKey: AppConstants.resetClearsSettingsKey)
            let shouldClearSettings = optionKeyPressed ? !resetClearsSettings : resetClearsSettings

            if shouldClearSettings {
                droppedFiles[index].clearUserSettings(resetNameOverride: true)
            }
        }
    }

    var body: some View {
        mainContentView
            .overlay(alignment: .bottom) { updateNotificationOverlay }
            .overlay(alignment: .top) { settingsSyncNoticeOverlay }
            .frame(minWidth: 860)
            .modifier(ContentViewSheets(
                droppedFiles: $droppedFiles,
                encodingGroups: $encodingGroups,
                trimSheetItemID: $trimSheetItemID,
                trimWithCropSheetItemID: $trimWithCropSheetItemID,
                timecodeSheetItemID: $timecodeSheetItemID,
                audioConfigSheetItemID: $audioConfigSheetItemID,
                dcpMetadataSheetItemID: $dcpMetadataSheetItemID,
                imfMetadataSheetItemID: $imfMetadataSheetItemID,
                selectedPreset: selectedPreset,
                showCaptureSheet: .constant(false)
            ))
            .background(keyboardShortcutHandler)
            .modifier(ContentViewLifecycle(
                hasInitializedPreset: $hasInitializedPreset,
                hasUserChangedPreset: $hasUserChangedPreset,
                selectedPreset: $selectedPreset,
                currentOutputFolder: $currentOutputFolder,
                isConverting: $isConverting,
                storedDefaultPresetRawValue: storedDefaultPresetRawValue,
                outputFolder: outputFolder,
                scheduleMergeCompatibilityEvaluation: scheduleMergeCompatibilityEvaluation,
                refreshExpectedOutputURLs: refreshExpectedOutputURLs,
                updateChecker: updateChecker
            ))
            .modifier(ContentViewChangeHandlers(
                showUpdateNotification: $showUpdateNotification,
                updateNotificationTask: $updateNotificationTask,
                selectedPreset: $selectedPreset,
                hasUserChangedPreset: $hasUserChangedPreset,
                currentOutputFolder: $currentOutputFolder,
                isFileImporterPresented: $isFileImporterPresented,
                mergeClipsEnabled: mergeClipsEnabled,
                watchFolderModeEnabled: watchFolderModeEnabled,
                isConverting: isConverting,
                droppedFilesCount: droppedFiles.count,
                updateChecker: updateChecker,
                outputFolder: outputFolder,
                storedDefaultPresetRawValue: storedDefaultPresetRawValue,
                refreshExpectedOutputURLs: refreshExpectedOutputURLs,
                scheduleMergeCompatibilityEvaluation: scheduleMergeCompatibilityEvaluation,
                handleWatchFolderToggle: handleWatchFolderToggle,
                scheduleAutoEncode: scheduleAutoEncode
            ))
            .onChange(of: droppedFiles) { _, _ in
                // Keep the display-order array in sync with the source list.
                // Without this, items appended outside the drag-drop path (e.g.
                // downloads started by DownloadManager) never become visible
                // because VideoQueueTableView only renders IDs present in queueOrder.
                sanitizeQueueOrder()
                if mergeClipsEnabled {
                    refreshExpectedOutputURLs(for: selectedPreset)
                }
                scheduleMergeCompatibilityEvaluation()
            }
            .onChange(of: animatedStillFormat) { _, _ in
                if selectedPreset == .animatedStill {
                    refreshExpectedOutputURLs(for: selectedPreset)
                }
            }
            .onChange(of: audioOnlyFormat) { _, _ in
                if selectedPreset == .audioOnly {
                    refreshExpectedOutputURLs(for: selectedPreset)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCameraCardImporter)) { _ in
                Task { await handleCameraCardFolderSelection() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .createEncodingGroup)) { _ in
                let defaultMerge = UserDefaults.standard.object(forKey: AppConstants.defaultGroupMergeEnabledKey) as? Bool
                    ?? AppConstants.defaultGroupMergeEnabled
                let defaultSequential = UserDefaults.standard.object(forKey: AppConstants.defaultGroupSequentialNamingEnabledKey) as? Bool
                    ?? AppConstants.defaultGroupSequentialNamingEnabled
                let defaultPresetRaw = UserDefaults.standard.string(forKey: AppConstants.defaultGroupPresetKey)
                    ?? AppConstants.defaultGroupPreset
                let defaultPreset = ExportPreset(rawValue: defaultPresetRaw)
                // Mutual exclusion: if both flags somehow ended up true (e.g. from
                // an older defaults plist), prefer merge — matches the historical
                // behavior where new groups were merge-on by default.
                let mergeEnabled = defaultMerge && !(defaultMerge && defaultSequential)
                let sequentialEnabled = defaultSequential && !mergeEnabled
                var group = EncodingGroup(
                    name: "New Group",
                    preset: defaultPreset,
                    concatEnabled: mergeEnabled,
                    sequentialNamingEnabled: sequentialEnabled
                )
                if sequentialEnabled { group.normalizeSequentialNaming() }
                encodingGroups.append(group)
                queueOrder.append(group.id)
                // Let the list view show a "group created" toast + scroll affordance,
                // since Cmd+N appends at the end where the user may not see it.
                NotificationCenter.default.post(
                    name: .encodingGroupCreated,
                    object: nil,
                    userInfo: ["groupID": group.id]
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsSyncedFromRemote)) { note in
                let device = note.userInfo?["deviceName"] as? String ?? "another Mac"
                showSettingsSyncNotice("Settings updated from \(device)")
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportSettingsRequested)) { _ in
                exportSettingsFromMenu()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importSettingsRequested)) { _ in
                importSettingsFromMenu()
            }
            .alert("Settings", isPresented: $showSettingsImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(settingsImportAlertMessage ?? "")
            }
            .sheet(item: $cameraCardImportState) { state in
                CameraCardImportView(
                    clipCount: state.videoURLs.count,
                    folderName: state.folderURL.lastPathComponent,
                    masterName: $cameraCardMasterName,
                    selectedPreset: cameraCardPresetBinding,
                    concatEnabled: $cameraCardConcatEnabled,
                    uploadEnabled: $cameraCardUploadEnabled,
                    autoEncodeEnabled: $cameraCardAutoEncodeEnabled,
                    mergeCompatibilityResult: cardMergeCompatibilityResult,
                    isCheckingCompatibility: isCheckingCardCompatibility,
                    onImport: {
                        cancelCardMergeCompatibilityCheck()
                        Task { await performCameraCardImport() }
                    },
                    onCancel: {
                        cancelCardMergeCompatibilityCheck()
                        cameraCardImportState = nil
                    },
                    onAutoSplit: {
                        cancelCardMergeCompatibilityCheck()
                        Task { await performCameraCardAutoSplit() }
                    },
                    onForceMerge: {
                        showCardConformanceMergeDialog = true
                    }
                )
                .onAppear { checkCardMergeCompatibility() }
                .onDisappear { cancelCardMergeCompatibilityCheck() }
                .onChange(of: cameraCardPresetRaw) { _, _ in checkCardMergeCompatibility() }
                .sheet(isPresented: $showCardConformanceMergeDialog) {
                    if cameraCardImportState != nil {
                        ConformanceMergeDialog(
                            items: cardConformanceItems,
                            metadata: cardConformanceMetadata,
                            onConfirm: { referenceID in
                                showCardConformanceMergeDialog = false
                                Task { await performCameraCardForceMerge(referenceItemID: referenceID) }
                            },
                            onCancel: {
                                showCardConformanceMergeDialog = false
                            }
                        )
                    }
                }
            }
            .modifier(ContentViewNotificationHandlers(
                droppedFiles: $droppedFiles,
                queueOrder: $queueOrder,
                currentOutputFolder: $currentOutputFolder,
                outputFolder: $outputFolder,
                isFileImporterPresented: $isFileImporterPresented,
                pendingConvertAfterImport: $pendingConvertAfterImport,
                selectedPreset: selectedPreset,
                videoLoopDefaultMuted: videoLoopDefaultMuted,
                startConversion: startConversion,
                applyPreset: applyPresetChange
            ))
    }

    // MARK: - Body Subviews

    private var mainContentView: some View {
        VStack {
            fileListView
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: supportedVideoTypes,
                    allowsMultipleSelection: true
                ) { result in
                    fileImportTaskCoordinator.start {
                        await handleFileSelection(result: result)
                    }
                }
                .task {
                    await startProgressUpdates()
#if DEBUG
                    await importUITestFixtureIfRequested()
#endif
                }
#if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    guard ProcessInfo.processInfo.environment["AMC_UI_TEST_SESSION"] == "1" else { return }
                    try? FileManager.default.removeItem(at: UITestFixtureConfiguration.directory)
                }
#endif
                .onDisappear {
                    fileImportTaskCoordinator.cancelAll()
                }
                .onAppear {
                    setupScheduledDownloads()
                    applyWatchFolderLaunchActivationIfNeeded()
                    // Replay any App Intent request that arrived before this
                    // window's notification receivers were ready (cold launch).
                    PendingAppIntentRequests.shared.drain()
                }
                .toolbar {
                    conversionToolbar
                }
                .background(LiquidGlassToolbarConfigurator())

            if isConverting {
                OverallProgressView(
                    progress: computedOverallProgress,
                    currentFileName: currentConvertingItem?.name,
                    completedCount: completedFileCount,
                    totalCount: totalActiveFileCount,
                    currentFileETA: currentConvertingItem?.eta
                )
            }
        }
        .overlay {
            if showURLInputOverlay {
                URLInputOverlay(
                    isPresented: $showURLInputOverlay,
                    onSubmit: { urlString, liveFromStart, audioOnly, wholePlaylist in
                        handleURLDownload(urlString, liveFromStart: liveFromStart, audioOnly: audioOnly, wholePlaylist: wholePlaylist)
                    },
                    onSchedule: { urlString, scheduledDate, liveFromStart, audioOnly, _ in
                        // Scheduling for whole-playlist isn't supported yet — submit() in
                        // URLInputOverlay routes the playlist case through onSubmit instead.
                        handleScheduledDownload(urlString, at: scheduledDate, liveFromStart: liveFromStart, audioOnly: audioOnly)
                    }
                )
            }
        }
        .sheet(isPresented: $showPresetQuickSelect) {
            PresetQuickSelectOverlay(
                isPresented: $showPresetQuickSelect,
                presets: visiblePresets,
                currentPreset: selectedPreset,
                displayName: { displayName(for: $0) },
                onSelect: { preset in
                    applyPresetChange(preset)
                }
            )
        }
        .alert("yt-dlp Not Available", isPresented: $showYTDLPNotConfiguredAlert) {
            Button("Open Settings") {
                openSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To download videos from URLs, you need yt-dlp. Install with Homebrew (brew install yt-dlp) or configure a custom path in Settings > Downloads.")
        }
    }

    /// Opens the URL download overlay, but only if yt-dlp is configured.
    /// If not, shows the not-available alert instead — avoids the dead-end
    /// where a user types a URL into the overlay and only then learns yt-dlp
    /// isn't installed.
    private func openURLInputOverlay() {
        Task {
            if await DownloadManager.shared.isYTDLPConfigured() {
                showURLInputOverlay = true
            } else {
                showYTDLPNotConfiguredAlert = true
            }
        }
    }

    /// Handles URL download from the overlay
    private func handleURLDownload(_ urlString: String, liveFromStart: Bool, audioOnly: Bool, wholePlaylist: Bool = false) {
        Task {
            // Check if yt-dlp is configured
            guard await DownloadManager.shared.isYTDLPConfigured() else {
                showYTDLPNotConfiguredAlert = true
                return
            }

            if wholePlaylist {
                await DownloadManager.shared.startPlaylistDownload(
                    url: urlString,
                    items: $droppedFiles,
                    outputFolder: downloadFolderURL,
                    audioOnly: audioOnly
                )
            } else {
                await DownloadManager.shared.startDownload(
                    url: urlString,
                    items: $droppedFiles,
                    outputFolder: downloadFolderURL,
                    liveFromStart: liveFromStart,
                    audioOnly: audioOnly
                )
            }
        }
    }

    /// Handles scheduling a download for later
    private func handleScheduledDownload(_ urlString: String, at date: Date, liveFromStart: Bool, audioOnly: Bool) {
        Task {
            await DownloadManager.shared.scheduleDownload(
                url: urlString,
                at: date,
                items: $droppedFiles,
                outputFolder: downloadFolderURL,
                liveFromStart: liveFromStart,
                audioOnly: audioOnly
            )
        }
    }

    /// Sets up the download manager references for scheduled downloads
    private func setupScheduledDownloads() {
        // Store references in DownloadManager so scheduled downloads can access them
        DownloadManager.shared.videoItems = $droppedFiles
        DownloadManager.shared.outputFolder = downloadFolderURL

        // Store references in UploadManager for upload functionality
        UploadManager.shared.videoItems = $droppedFiles

        // Set up auto-encode callback for downloads
        DownloadManager.shared.onAutoEncode = { [self] _ in
            Task { @MainActor in
                // Only start if not already converting
                if !isConverting {
                    await startConversion()
                }
            }
        }

        // Re-add any scheduled downloads that were persisted from a previous launch.
        DownloadManager.shared.restoreScheduledDownloads(
            items: $droppedFiles,
            outputFolder: downloadFolderURL
        )
    }

    @ViewBuilder
    private var updateNotificationOverlay: some View {
        if showUpdateNotification {
            UpdateNotificationView(
                latestVersion: updateChecker.latestVersion,
                installSource: InstallSource.current,
                onReleaseNotes: {
                    updateChecker.openReleaseNotes()
                    withAnimation {
                        showUpdateNotification = false
                    }
                },
                onDownload: {
                    updateChecker.openDownloadAsset()
                    withAnimation {
                        showUpdateNotification = false
                    }
                },
                onDismiss: {
                    withAnimation {
                        showUpdateNotification = false
                    }
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var settingsSyncNoticeOverlay: some View {
        if let notice = settingsSyncNotice {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.icloud")
                Text(notice)
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 4, y: 2)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func showSettingsSyncNotice(_ message: String) {
        settingsSyncNoticeTask?.cancel()
        withAnimation { settingsSyncNotice = message }
        settingsSyncNoticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { settingsSyncNotice = nil } }
        }
    }

    private func exportSettingsFromMenu() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Aagedal Media Converter Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsSyncService.shared.exportSnapshot(to: url)
        } catch {
            settingsImportAlertMessage = error.localizedDescription
            showSettingsImportAlert = true
        }
    }

    private func importSettingsFromMenu() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = try SettingsSyncService.shared.importSnapshot(from: url, notify: false)
            settingsImportAlertMessage = "Imported settings from \(snapshot.deviceName) (\(snapshot.modifiedAt.formatted(date: .abbreviated, time: .shortened)))."
        } catch {
            settingsImportAlertMessage = error.localizedDescription
        }
        showSettingsImportAlert = true
    }

    private var keyboardShortcutHandler: some View {
        GlobalKeyboardShortcutHandler(
            onToggleWatchFolder: { watchFolderModeEnabled.toggle() },
            onSelectOutputFolder: {
                Task {
                    if let folder = await selectOutputFolder() {
                        currentOutputFolder = folder
                    }
                }
            },
            onToggleMerge: {
                if mergeClipsAvailable {
                    mergeClipsEnabled.toggle()
                }
            },
            onResetAll: {
                resetAllFiles()
            },
            onToggleConversion: handleConversionToggle,
            onShowURLInput: {
                openURLInputOverlay()
            },
            onShowCapture: {
                CaptureOverlayWindowController.shared.showCaptureOverlay()
            },
            onShowPresetQuickSelect: {
                showPresetQuickSelect = true
            },
            onSelectPresetByIndex: { index in
                guard !anySheetOrOverlayOpen else { return false }
                guard index < visiblePresets.count else { return false }
                applyPresetChange(visiblePresets[index])
                return true
            },
            onShowShortcuts: {
                // Set the tab to open before opening Settings
                UserDefaults.standard.set("shortcuts", forKey: AppConstants.settingsTabToOpenKey)
                openSettings()
            }
        )
    }

    // Helper function for folder selection
    @MainActor
    private func selectOutputFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        // Set the starting directory to the current output folder if it exists
        if FileManager.default.fileExists(atPath: currentOutputFolder.path) {
            panel.directoryURL = currentOutputFolder
        }
        
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        
        if response == .OK, let url = panel.url {
            // Ensure the directory exists
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Persist a writable bookmark so the folder survives across launches.
            _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)
            return url
        }
        return nil
    }

    @AppStorage("cameraCardUploadEnabled") private var cameraCardUploadEnabled = false
    @AppStorage("cameraCardConcatEnabled") private var cameraCardConcatEnabled = true
    @AppStorage("cameraCardMasterName") private var cameraCardMasterName = ""
    @AppStorage("cameraCardPreset") private var cameraCardPresetRaw = ExportPreset.streamCopy.rawValue
    @AppStorage("cameraCardAutoEncodeEnabled") private var cameraCardAutoEncodeEnabled = false

    private var cameraCardPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy },
            set: { cameraCardPresetRaw = $0.rawValue }
        )
    }
    @State private var cameraCardImportState: CameraCardImportState?
    @State private var cardMergeCompatibilityResult: ConversionManager.MergeCompatibilityResult?
    @State private var isCheckingCardCompatibility = false
    @State private var cardCompatibilityCheckTask: Task<Void, Never>?
    @State private var cardCompatibilityCheckID: UUID?
    @State private var showCardConformanceMergeDialog = false
    @State private var cardConformanceItems: [VideoItem] = []
    @State private var cardConformanceMetadata: [UUID: VideoMetadata] = [:]

    private struct CameraCardImportState: Identifiable {
        let id = UUID()
        let folderURL: URL
        let videoURLs: [URL]
    }

    @MainActor
    private func handleCameraCardFolderSelection() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Camera Card or Folder"
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")

        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }

        guard response == .OK, let folderURL = panel.url else { return }

        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: folderURL)

        // Scan off the main actor: the picker opens at /Volumes and lets the user
        // choose any directory (including a large external drive or deep tree), so the
        // recursive FileManager walk can take seconds. Keeping it on @MainActor would
        // freeze the UI for the duration.
        let videoURLs = await Task.detached(priority: .userInitiated) {
            CameraCardScanner.scanForVideoFiles(in: folderURL)
        }.value

        if hasAccess { folderURL.stopAccessingSecurityScopedResource() }

        guard !videoURLs.isEmpty else { return }

        cameraCardImportState = CameraCardImportState(folderURL: folderURL, videoURLs: videoURLs)
    }

    @MainActor
    private func performCameraCardImport() async {
        guard let state = cameraCardImportState else { return }
        cameraCardImportState = nil

        let concatEnabled = cameraCardConcatEnabled
        let uploadEnabled = cameraCardUploadEnabled
        let masterName = cameraCardMasterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardPreset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy

        let hasAccess = state.folderURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { state.folderURL.stopAccessingSecurityScopedResource() }
        }

        for url in state.videoURLs {
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }

        // Build VideoItems for the group
        var groupItems: [VideoItem] = []
        for url in state.videoURLs {
            if var item = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: cardPreset
            ) {
                if uploadEnabled {
                    item.uploadEnabled = true
                }
                if !masterName.isEmpty {
                    let processedName = FileNameProcessor.processFileName(masterName)
                    if concatEnabled {
                        // For concat, only the first item needs the master name override
                        if groupItems.isEmpty {
                            item.outputFileNameOverride = processedName
                            item.outputURL = expectedOutputURL(for: item, preset: cardPreset)
                        }
                    } else {
                        let sequenceName = String(format: "%@_%03d", processedName, groupItems.count + 1)
                        item.outputFileNameOverride = sequenceName
                        item.outputURL = expectedOutputURL(for: item, preset: cardPreset)
                    }
                }
                groupItems.append(item)
            }
        }

        guard !groupItems.isEmpty else { return }

        let groupName = masterName.isEmpty ? state.folderURL.lastPathComponent : masterName

        let group = EncodingGroup(
            name: groupName,
            items: groupItems,
            preset: cardPreset,
            concatEnabled: concatEnabled,
            uploadEnabled: uploadEnabled
        )

        encodingGroups.append(group)
        queueOrder.append(group.id)

        // Load details (thumbnails, duration, metadata) in background
        let itemIDs = groupItems.map { $0.id }
        Task {
            await loadGroupItemDetails(groupID: group.id, itemIDs: itemIDs, preset: cardPreset)
        }

        if cameraCardAutoEncodeEnabled {
            let createdGroupID = group.id
            Task { await encodeOnlyGroup(groupID: createdGroupID) }
        }
    }

    /// Runs merge compatibility check for the card import dialog in background.
    private func checkCardMergeCompatibility() {
        cancelCardMergeCompatibilityCheck()
        cardMergeCompatibilityResult = nil

        guard let state = cameraCardImportState, state.videoURLs.count >= 2 else {
            cardMergeCompatibilityResult = .insufficientItems(cameraCardImportState?.videoURLs.count ?? 0)
            return
        }

        isCheckingCardCompatibility = true
        let urls = state.videoURLs
        let folderURL = state.folderURL
        let preset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy
        let checkID = UUID()
        cardCompatibilityCheckID = checkID

        cardCompatibilityCheckTask = Task {
            let hasAccess = folderURL.startAccessingSecurityScopedResource()
            defer { if hasAccess { folderURL.stopAccessingSecurityScopedResource() } }

            var tempItems = urls.compactMap {
                VideoFileUtils.makePlaceholderItem(from: $0, outputFolder: outputFolder, preset: preset)
            }
            var metadataMap: [UUID: VideoMetadata] = [:]

            do {
                let metadataByURL = try await BoundedVideoMetadataProbe.availableMetadata(for: tempItems.map(\.url))
                for index in tempItems.indices {
                    if let metadata = metadataByURL[tempItems[index].url] {
                        tempItems[index].metadata = metadata
                        metadataMap[tempItems[index].id] = metadata
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Per-file failures are omitted by availableMetadata; no other error is expected.
            }

            guard !Task.isCancelled else { return }

            let result = ConversionManager.checkMergeCompatibility(items: tempItems, metadata: metadataMap)
            await MainActor.run {
                guard cardCompatibilityCheckID == checkID else { return }
                cardMergeCompatibilityResult = result
                isCheckingCardCompatibility = false
                cardCompatibilityCheckTask = nil
                cardCompatibilityCheckID = nil
                // Store for conformance merge dialog
                cardConformanceItems = tempItems
                cardConformanceMetadata = metadataMap
            }
        }
    }

    private func cancelCardMergeCompatibilityCheck() {
        cardCompatibilityCheckTask?.cancel()
        cardCompatibilityCheckTask = nil
        cardCompatibilityCheckID = nil
        isCheckingCardCompatibility = false
    }

    @MainActor
    private func performCameraCardAutoSplit() async {
        guard let state = cameraCardImportState else { return }
        cameraCardImportState = nil

        let uploadEnabled = cameraCardUploadEnabled
        let masterName = cameraCardMasterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardPreset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy

        let hasAccess = state.folderURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { state.folderURL.stopAccessingSecurityScopedResource() } }

        for url in state.videoURLs {
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }

        // Build items and gather their independent metadata probes concurrently so the
        // operation has one 15-second probe window regardless of card size.
        var allItems = state.videoURLs.compactMap {
            VideoFileUtils.makePlaceholderItem(from: $0, outputFolder: outputFolder, preset: cardPreset)
        }
        if uploadEnabled {
            for index in allItems.indices {
                allItems[index].uploadEnabled = true
            }
        }
        var metadataMap: [UUID: VideoMetadata] = [:]

        do {
            let metadataByURL = try await BoundedVideoMetadataProbe.availableMetadata(for: allItems.map(\.url))
            for index in allItems.indices {
                if let metadata = metadataByURL[allItems[index].url] {
                    allItems[index].metadata = metadata
                    metadataMap[allItems[index].id] = metadata
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // Per-file failures are omitted by availableMetadata; no other error is expected.
        }

        guard !allItems.isEmpty else { return }

        let compatibleGroups = ConversionManager.groupByCompatibility(items: allItems, metadata: metadataMap)
        let baseName = masterName.isEmpty ? state.folderURL.lastPathComponent : masterName

        // First pass: compute a tentative name for each group from its format signature.
        // Includes height + scan type + frame rate + audio channels + video codec, since
        // codec is one of the criteria that splits clips into different groups (see
        // ConversionManager.checkMergeCompatibility) but isn't reflected in res/fps/ch.
        var tentativeNames: [String] = compatibleGroups.map { groupItems in
            guard compatibleGroups.count > 1,
                  let first = groupItems.first,
                  let meta = metadataMap[first.id] else { return baseName }
            var parts: [String] = []
            if let video = meta.primaryVideoStream, let h = video.height {
                let scanType = (video.isInterlaced == true) ? "i" : "p"
                let fr = video.frameRate?.value.map { String(Int($0.rounded())) } ?? ""
                parts.append("\(h)\(scanType)\(fr)")
            }
            if let audio = meta.audioStreams.first, let ch = audio.channels {
                parts.append("\(ch)ch")
            }
            if let codec = meta.primaryVideoStream?.codec?.lowercased(), !codec.isEmpty {
                parts.append(codec)
            }
            let suffix = parts.isEmpty ? "" : "_" + parts.joined(separator: "_")
            return "\(baseName)\(suffix)"
        }

        // Tie-breaker pass: any tentative name that appears more than once gets
        // `_g2`, `_g3`, … appended in creation order (the first occurrence keeps the
        // clean name). Catches the metadata-missing case (empty suffix collapses two
        // groups to bare baseName) and any future splitting criterion that doesn't
        // make it into the suffix above.
        let totalOccurrences = tentativeNames.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var occurrenceIndex: [String: Int] = [:]
        for idx in tentativeNames.indices {
            let name = tentativeNames[idx]
            guard (totalOccurrences[name] ?? 0) > 1 else { continue }
            let occurrence = (occurrenceIndex[name] ?? 0) + 1
            occurrenceIndex[name] = occurrence
            if occurrence > 1 {
                tentativeNames[idx] = "\(name)_g\(occurrence)"
            }
        }

        var createdGroupIDs: [UUID] = []
        for (groupIdx, groupItems) in compatibleGroups.enumerated() {
            let groupName = tentativeNames[groupIdx]

            // Apply sequential naming within each group
            var namedItems = groupItems
            for i in namedItems.indices {
                if !masterName.isEmpty {
                    let processedName = FileNameProcessor.processFileName(groupName)
                    if namedItems.count > 1 {
                        // Concat group — only first item gets the name override
                        if i == 0 {
                            namedItems[i].outputFileNameOverride = processedName
                            namedItems[i].outputURL = expectedOutputURL(for: namedItems[i], preset: cardPreset)
                        }
                    } else {
                        namedItems[i].outputFileNameOverride = processedName
                        namedItems[i].outputURL = expectedOutputURL(for: namedItems[i], preset: cardPreset)
                    }
                }
            }

            let group = EncodingGroup(
                name: groupName,
                items: namedItems,
                preset: cardPreset,
                concatEnabled: namedItems.count >= 2,
                uploadEnabled: uploadEnabled
            )

            encodingGroups.append(group)
            queueOrder.append(group.id)
            createdGroupIDs.append(group.id)

            let itemIDs = namedItems.map { $0.id }
            Task {
                await loadGroupItemDetails(groupID: group.id, itemIDs: itemIDs, preset: cardPreset)
            }
        }

        if cameraCardAutoEncodeEnabled {
            Task {
                for gid in createdGroupIDs {
                    await encodeOnlyGroup(groupID: gid)
                }
            }
        }
    }

    @MainActor
    private func performCameraCardForceMerge(referenceItemID: UUID) async {
        guard let state = cameraCardImportState else { return }
        cameraCardImportState = nil

        let uploadEnabled = cameraCardUploadEnabled
        let masterName = cameraCardMasterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardPreset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy

        let hasAccess = state.folderURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { state.folderURL.stopAccessingSecurityScopedResource() } }

        for url in state.videoURLs {
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }

        // Use the items and metadata from the compatibility check
        var groupItems = cardConformanceItems
        for i in groupItems.indices {
            if uploadEnabled { groupItems[i].uploadEnabled = true }
            if !masterName.isEmpty {
                let processedName = FileNameProcessor.processFileName(masterName)
                if i == 0 {
                    groupItems[i].outputFileNameOverride = processedName
                    groupItems[i].outputURL = expectedOutputURL(for: groupItems[i], preset: cardPreset)
                }
            }
        }

        guard !groupItems.isEmpty else { return }

        let groupName = masterName.isEmpty ? state.folderURL.lastPathComponent : masterName

        // Find the reference item ID in our items (it may have a different UUID from the temp items)
        let group = EncodingGroup(
            name: groupName,
            items: groupItems,
            preset: cardPreset,
            concatEnabled: true,
            uploadEnabled: uploadEnabled,
            conformanceMergeEnabled: true,
            conformanceReferenceItemID: referenceItemID
        )

        encodingGroups.append(group)
        queueOrder.append(group.id)

        let itemIDs = groupItems.map { $0.id }
        Task {
            await loadGroupItemDetails(groupID: group.id, itemIDs: itemIDs, preset: cardPreset)
        }

        if cameraCardAutoEncodeEnabled {
            let createdGroupID = group.id
            Task { await encodeOnlyGroup(groupID: createdGroupID) }
        }
    }

    @MainActor
    private func addFilesToGroup(groupID: UUID) async {
        guard let groupIndex = encodingGroups.firstIndex(where: { $0.id == groupID }) else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AppConstants.supportedVideoTypes.compactMap { UTType($0) }
        panel.title = "Add Files to Group"

        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }

        guard response == .OK, !panel.urls.isEmpty else { return }

        let groupPreset = encodingGroups[groupIndex].preset ?? selectedPreset
        var newItemIDs: [UUID] = []

        for url in panel.urls {
            let hasAccess = url.startAccessingSecurityScopedResource()
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
            if hasAccess { url.stopAccessingSecurityScopedResource() }

            if let item = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: groupPreset
            ) {
                newItemIDs.append(item.id)
                encodingGroups[groupIndex].items.append(item)
            }
        }

        // Load details asynchronously for added items
        await loadGroupItemDetails(groupID: groupID, itemIDs: newItemIDs, preset: groupPreset)
    }

    /// Appends files dropped from Finder directly onto a group header.
    /// Mirrors `addFilesToGroup(groupID:)` but skips the NSOpenPanel since the URLs
    /// are already provided by the drag session. Handles security-scoped access
    /// and skips files already present in the group or in the ungrouped queue.
    @MainActor
    private func addURLsToGroup(groupID: UUID, urls: [URL]) async {
        guard let groupIndex = encodingGroups.firstIndex(where: { $0.id == groupID }) else { return }

        let supported = AppConstants.supportedVideoExtensions
        let groupPreset = encodingGroups[groupIndex].preset ?? selectedPreset
        var newItemIDs: [UUID] = []

        // Union of everything already in the queue — drag-drop should be idempotent.
        let existingURLs: Set<URL> = {
            var urls = Set(droppedFiles.map(\.url))
            for group in encodingGroups {
                for item in group.items { urls.insert(item.url) }
            }
            return urls
        }()

        for url in urls {
            guard supported.contains(url.pathExtension.lowercased()) else { continue }
            guard !existingURLs.contains(url) else { continue }

            let hadAccess = url.startAccessingSecurityScopedResource()
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
            if hadAccess { url.stopAccessingSecurityScopedResource() }

            if let item = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: groupPreset
            ) {
                newItemIDs.append(item.id)
                // Re-lookup each iteration: earlier loads above are awaited but the
                // array is only mutated on the main actor, so the index stays valid
                // within this loop.
                encodingGroups[groupIndex].items.append(item)
            }
        }

        guard !newItemIDs.isEmpty else { return }

        if encodingGroups[groupIndex].sequentialNamingEnabled {
            encodingGroups[groupIndex].normalizeSequentialNaming()
        }

        await loadGroupItemDetails(groupID: groupID, itemIDs: newItemIDs, preset: groupPreset)
    }

    @MainActor
    private func loadGroupItemDetails(groupID: UUID, itemIDs: [UUID], preset: ExportPreset) async {
        for itemID in itemIDs {
            guard let gi = encodingGroups.firstIndex(where: { $0.id == groupID }),
                  let ii = encodingGroups[gi].items.firstIndex(where: { $0.id == itemID }) else { continue }

            let url = encodingGroups[gi].items[ii].url
            let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: preset)
            if let gi2 = encodingGroups.firstIndex(where: { $0.id == groupID }),
               let ii2 = encodingGroups[gi2].items.firstIndex(where: { $0.id == itemID }) {
                encodingGroups[gi2].items[ii2].apply(details: details)
                encodingGroups[gi2].items[ii2].detailsLoaded = true
            }
        }
    }

    // Handle file selection from file picker
    private func handleFileSelection(result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            for url in urls {
                // Check for duplicates before creating placeholder
                guard !droppedFiles.contains(where: { $0.url == url }) else {
                    continue
                }

                // Check if URL is a directory — detect image sequences
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    let sequences = await ImageSequenceDetector.detectSequences(
                        inFolder: url,
                        securityScopedAccessURL: url
                    )
                    _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
                    if hasAccess { url.stopAccessingSecurityScopedResource() }
                    guard !Task.isCancelled else { return }
                    for config in sequences {
                        guard !containsImageSequence(config) else { continue }
                        let item = VideoFileUtils.makePlaceholderItem(
                            fromImageSequence: config,
                            outputFolder: outputFolder,
                            preset: selectedPreset
                        )
                        droppedFiles.append(item)
                        queueOrder.append(item.id)
                    }
                    continue
                }

                // Check if it's a single image file that could be part of a sequence
                let ext = url.pathExtension.lowercased()
                if AppConstants.supportedImageSequenceExtensions.contains(ext) {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    let parentDir = url.deletingLastPathComponent()
                    let parentAccess = SecurityScopedBookmarkManager.shared.startAccessing(url: parentDir)
                    defer { SecurityScopedBookmarkManager.shared.stopAccessing(parentAccess) }
                    let parentScopedURL: URL?
                    switch parentAccess {
                    case .direct(let scopedURL):
                        parentScopedURL = scopedURL
                    case .bookmark(let bookmarkedURL):
                        parentScopedURL = SecurityScopedBookmarkManager.shared.resolveBookmark(for: bookmarkedURL)
                    case .none:
                        parentScopedURL = nil
                    }
                    if let config = await ImageSequenceDetector.detectSequence(
                        fromFile: url,
                        securityScopedAccessURL: parentScopedURL,
                        detectsAssociatedAudio: parentScopedURL != nil
                    ) {
                        guard !Task.isCancelled else { return }
                        _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: parentDir)
                        guard !containsImageSequence(config) else { continue }
                        let item = VideoFileUtils.makePlaceholderItem(
                            fromImageSequence: config,
                            outputFolder: outputFolder,
                            preset: selectedPreset
                        )
                        droppedFiles.append(item)
                        queueOrder.append(item.id)
                        continue
                    }
                    continue // Single image without sequence, skip
                }

                guard let placeholder = VideoFileUtils.makePlaceholderItem(
                    from: url,
                    outputFolder: outputFolder,
                    preset: selectedPreset
                ) else {
                    Self.logger.info("Skipping unsupported file: \(url.lastPathComponent, privacy: .public)")
                    continue
                }

                droppedFiles.append(placeholder)
                queueOrder.append(placeholder.id)
                // Auto-mute if VideoLoop preset is selected and setting is enabled
                if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                    droppedFiles[droppedFiles.count - 1].isMuted = true
                }
                let placeholderID = placeholder.id

                // Load details asynchronously in background
                Task(priority: .utility) {
                    let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: selectedPreset)
                    await MainActor.run {
                        if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                            self.droppedFiles[index].apply(details: details)
                            self.droppedFiles[index].detailsLoaded = true
                        }
                    }
                }
            }

            // A convert App Intent (Spotlight/Siri phrase) opened this importer
            // with no file input; now that the user has picked files, start
            // converting. Guard on a non-empty selection so cancelling is a no-op.
            if pendingConvertAfterImport {
                pendingConvertAfterImport = false
                if !urls.isEmpty {
                    Task { await startConversionWithValidation() }
                }
            }
        case .failure(let error):
            pendingConvertAfterImport = false
            Self.logger.error("Error selecting files: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func containsImageSequence(_ config: ImageSequenceConfig) -> Bool {
        droppedFiles.contains { item in
            guard let existing = item.imageSequenceConfig else { return false }
            return existing.pattern == config.pattern
                && existing.directory.standardizedFileURL == config.directory.standardizedFileURL
        }
    }

#if DEBUG
    @MainActor
    private func importUITestFixtureIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard !hasHandledUITestFixtureLaunch,
              environment["AMC_UI_TEST_SESSION"] == "1" else {
            return
        }
        hasHandledUITestFixtureLaunch = true

        do {
            let directory = UITestFixtureConfiguration.directory
            // Also recover artifacts after force termination, which may bypass
            // willTerminateNotification. Ordinary app launches never touch this folder.
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            guard environment["AMC_UI_TEST_GENERATED_FIXTURE"] == "1" else { return }

            currentOutputFolder = directory

            let fixtureURL = try await Self.generateUITestFixture(in: directory)
            await handleFileSelection(result: .success([fixtureURL]))
            if environment["AMC_UI_TEST_REMOVE_FIXTURE_AFTER_IMPORT"] == "1" {
                try FileManager.default.removeItem(at: fixtureURL)
            }
        } catch {
            Self.logger.error("Unable to prepare UI test fixture: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func generateUITestFixture(in directory: URL) async throws -> URL {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            throw UITestFixtureError.missingFFmpeg
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureURL = directory.appendingPathComponent("ui-test-fixture.mp4")
        let fixtureDuration = ProcessInfo.processInfo.environment["AMC_UI_TEST_REALTIME_INPUT"] == "1"
            ? 15
            : 2

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=\(fixtureDuration)",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(fixtureDuration)",
                "-map", "0:v:0", "-map", "1:a:0",
                "-c:v", "mpeg4", "-q:v", "5", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-shortest", fixtureURL.path,
            ],
            timeout: .seconds(30),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 8 * 1024,
            sensitiveValues: [directory.path, fixtureURL.path]
        )
        let result = try await SubprocessRunner().run(request)
        guard result.succeeded,
              FileManager.default.fileExists(atPath: fixtureURL.path) else {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "UITestFixture").error("UI test fixture FFmpeg diagnostic: \(request.redactedDiagnostic(result.standardErrorText), privacy: .public)")
            throw UITestFixtureError.generationFailed(result.terminationStatus)
        }
        return fixtureURL
    }

    private enum UITestFixtureError: LocalizedError {
        case missingFFmpeg
        case generationFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .missingFFmpeg:
                return "The bundled FFmpeg executable could not be resolved."
            case .generationFailed(let status):
                return "FFmpeg exited with status \(status)."
            }
        }
    }
#endif

    private func startProgressUpdates() async {
        progressTask?.cancel()
        progressTask = Task {
            for await progress in await ConversionManager.shared.progressUpdates() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    overallProgress = progress
                    dockProgressUpdater.updateProgress(progress)
                }
            }
        }
    }
    
    @MainActor
    private func startConversion() async {
        isConverting = true
        // Initialize dock progress with 0% to show it immediately
        dockProgressUpdater.updateProgress(0.0)
        sanitizeQueueOrder()

        // Convert in queue order: batch consecutive ungrouped items, then groups
        var i = 0
        while i < queueOrder.count {
            guard isConverting else { break }
            let id = queueOrder[i]

            if let groupIndex = encodingGroups.firstIndex(where: { $0.id == id }) {
                // Encoding group entry
                let group = encodingGroups[groupIndex]
                if group.items.contains(where: { $0.status == .waiting }) {
                    // Apply sequential naming if enabled
                    if group.sequentialNamingEnabled {
                        let processedName = FileNameProcessor.processFileName(group.name)
                        for itemIndex in encodingGroups[groupIndex].items.indices {
                            let sequenceName = String(format: "%@_%03d", processedName, itemIndex + 1)
                            encodingGroups[groupIndex].items[itemIndex].outputFileNameOverride = sequenceName
                        }
                    }
                    let groupPreset = group.preset ?? selectedPreset
                    // Build conformance metadata if needed
                    var conformanceMeta: [UUID: VideoMetadata]?
                    if group.conformanceMergeEnabled, group.conformanceReferenceItemID != nil {
                        var metaMap: [UUID: VideoMetadata] = [:]
                        for item in encodingGroups[groupIndex].items {
                            if let m = item.metadata { metaMap[item.id] = m }
                        }
                        conformanceMeta = metaMap
                    }

                    await ConversionManager.shared.convertGroup(
                        items: $encodingGroups[groupIndex].items,
                        outputFolder: currentOutputFolder.path,
                        preset: groupPreset,
                        concatEnabled: group.concatEnabled,
                        groupName: group.name,
                        transcriptionEnabled: group.transcriptionEnabled,
                        uploadEnabled: group.uploadEnabled,
                        analyticsEnabled: group.analyticsEnabled,
                        conformanceMergeEnabled: group.conformanceMergeEnabled,
                        conformanceReferenceItemID: group.conformanceReferenceItemID,
                        conformanceMetadata: conformanceMeta
                    )
                }
                i += 1
            } else {
                // Consecutive ungrouped items — collect IDs for this batch
                var batchIDs = Set<UUID>()
                while i < queueOrder.count && !encodingGroups.contains(where: { $0.id == queueOrder[i] }) {
                    batchIDs.insert(queueOrder[i])
                    i += 1
                }
                if droppedFiles.contains(where: { $0.status == .waiting && batchIDs.contains($0.id) }) {
                    await ConversionManager.shared.startConversion(
                        droppedFiles: $droppedFiles,
                        outputFolder: currentOutputFolder.path,
                        preset: selectedPreset,
                        mergeClipsEnabled: mergeClipsEnabled,
                        limitToIDs: batchIDs
                    )
                }
            }
        }

        isConverting = false
        SoundManager.shared.playSuccess()
        watchFolderCoordinator.startConversion()
    }

    /// Encodes a single item immediately (Option+click on encode button).
    @MainActor
    private func encodeOnlyItem(itemID: UUID) async {
        guard !isConverting else { return }
        guard droppedFiles.contains(where: { $0.id == itemID && $0.status == .waiting }) else { return }
        isConverting = true
        dockProgressUpdater.updateProgress(0.0)
        await ConversionManager.shared.startConversion(
            droppedFiles: $droppedFiles,
            outputFolder: currentOutputFolder.path,
            preset: selectedPreset,
            mergeClipsEnabled: false,
            limitToIDs: [itemID]
        )
        isConverting = false
        SoundManager.shared.playSuccess()
    }

    /// Encodes all waiting items in a single group immediately (Option+click on the
    /// group's encode button). Mirrors `encodeOnlyItem` but routes through
    /// `convertGroup` so concat/sequential-naming/conformance settings are honoured.
    @MainActor
    private func encodeOnlyGroup(groupID: UUID) async {
        guard !isConverting else { return }
        guard let groupIndex = encodingGroups.firstIndex(where: { $0.id == groupID }) else { return }
        guard encodingGroups[groupIndex].items.contains(where: { $0.status == .waiting }) else { return }

        isConverting = true
        dockProgressUpdater.updateProgress(0.0)

        let group = encodingGroups[groupIndex]
        if group.sequentialNamingEnabled {
            let processedName = FileNameProcessor.processFileName(group.name)
            for itemIndex in encodingGroups[groupIndex].items.indices {
                let sequenceName = String(format: "%@_%03d", processedName, itemIndex + 1)
                encodingGroups[groupIndex].items[itemIndex].outputFileNameOverride = sequenceName
            }
        }
        let groupPreset = group.preset ?? selectedPreset
        var conformanceMeta: [UUID: VideoMetadata]?
        if group.conformanceMergeEnabled, group.conformanceReferenceItemID != nil {
            var metaMap: [UUID: VideoMetadata] = [:]
            for item in encodingGroups[groupIndex].items {
                if let m = item.metadata { metaMap[item.id] = m }
            }
            conformanceMeta = metaMap
        }

        await ConversionManager.shared.convertGroup(
            items: $encodingGroups[groupIndex].items,
            outputFolder: currentOutputFolder.path,
            preset: groupPreset,
            concatEnabled: group.concatEnabled,
            groupName: group.name,
            transcriptionEnabled: group.transcriptionEnabled,
            uploadEnabled: group.uploadEnabled,
            analyticsEnabled: group.analyticsEnabled,
            conformanceMergeEnabled: group.conformanceMergeEnabled,
            conformanceReferenceItemID: group.conformanceReferenceItemID,
            conformanceMetadata: conformanceMeta
        )

        isConverting = false
        SoundManager.shared.playSuccess()
    }

    @MainActor
    private func cancelConversion() async {
        await ConversionManager.shared.cancelAllConversions()

        // Cancel waiting group items too (they won't be reached since isConverting is cleared)
        for gi in encodingGroups.indices {
            for ii in encodingGroups[gi].items.indices {
                if encodingGroups[gi].items[ii].status == .converting {
                    encodingGroups[gi].items[ii].status = .cancelled
                    encodingGroups[gi].items[ii].progress = 0
                }
            }
        }

        isConverting = false
        dockProgressUpdater.reset()
        watchFolderCoordinator.cancelConversion()
    }
    
    private func refreshExpectedOutputURLs(for preset: ExportPreset) {
        for index in droppedFiles.indices where droppedFiles[index].status == .waiting {
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: preset)
        }
    }

    private func displayName(for preset: ExportPreset) -> String {
        presetManager.displayName(for: preset)
    }

    /// Creates a Binding<Bool> from a Binding<UUID?> for sheet presentation.
    /// The sheet is presented when the UUID is non-nil, and dismissing sets it to nil.
    private func sheetBinding(for itemID: Binding<UUID?>) -> Binding<Bool> {
        Binding(
            get: { itemID.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    itemID.wrappedValue = nil
                }
            }
        )
    }

    private func expectedOutputURL(for item: VideoItem, preset: ExportPreset) -> URL? {
        if mergeClipsEnabled && mergeClipsAvailable, let mergedURL = mergedOutputURL(for: preset) {
            return mergedURL
        }

        let resolvedExtension = preset.outputExtension(for: item.url)
        let outputBaseName = outputBaseName(for: item, preset: preset)
        let outputFileName = outputBaseName + "." + resolvedExtension
        return currentOutputFolder.appendingPathComponent(outputFileName)
    }

    private func mergedOutputURL(for preset: ExportPreset) -> URL? {
        guard let referenceItem = droppedFiles.first(where: { $0.status == .waiting }) else {
            return nil
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(referenceItem.url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: referenceItem.url)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        let outputFileName = sanitizedBaseName + suffixPart + "_merge" + "." + resolvedExtension
        return currentOutputFolder.appendingPathComponent(outputFileName)
    }

    private func outputBaseName(for item: VideoItem, preset: ExportPreset) -> String {
        if let override = item.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let baseName = (override as NSString).deletingPathExtension
            return FileNameProcessor.processFileName(baseName)
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(item.url.deletingPathExtension().lastPathComponent)
        let templatedBaseName = FileNameProcessor.applyCustomTemplate(sourceName: sanitizedBaseName, counter: item.customCounterValue, preset: preset)
        let suppressAutoSuffix = FileNameProcessor.customTemplateUsesPresetSuffix
        let suffixPart = (FileNameProcessor.includePresetSuffix && !suppressAutoSuffix) ? preset.fileSuffix : ""
        return templatedBaseName + suffixPart
    }

    private func handleOutputFileNameOverride(itemID: UUID, newName: String?) {
        guard let index = droppedFiles.firstIndex(where: { $0.id == itemID }) else { return }
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            droppedFiles[index].outputFileNameOverride = nil
        } else {
            let baseName = (trimmed as NSString).deletingPathExtension
            droppedFiles[index].outputFileNameOverride = FileNameProcessor.processFileName(baseName)
        }
        droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
    }

    private var toolbarPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { selectedPreset },
            set: { newValue in
                let oldValue = selectedPreset
                hasUserChangedPreset = true
                selectedPreset = newValue
                refreshExpectedOutputURLs(for: newValue)

                // Defer merge evaluation to avoid modifying state during view update
                Task { @MainActor in
                    await Task.yield()
                    self.scheduleMergeCompatibilityEvaluation()
                }

                // Apply auto-mute settings via PresetManager
                presetManager.applyAutoMuteSettings(
                    to: &droppedFiles,
                    oldPreset: oldValue,
                    newPreset: newValue,
                    videoLoopDefaultMuted: videoLoopDefaultMuted
                )
            }
        )
    }

    private var conversionToolbar: some ToolbarContent {
        ConversionToolbarView(
            isConverting: isConverting,
            canStartConversion: canStartConversion,
            hasFiles: !droppedFiles.isEmpty || !encodingGroups.isEmpty,
            watchFolderModeEnabled: $watchFolderModeEnabled,
            watchFolderPath: watchFolderPath,
            selectedPreset: toolbarPresetBinding,
            presets: visiblePresets,
            displayName: { displayName(for: $0) },
            mergeClipsEnabled: $mergeClipsEnabled,
            mergeClipsAvailable: mergeClipsAvailable,
            onToggleConversion: handleConversionToggle,
            onImport: { isFileImporterPresented = true },
            onShowDownload: { openURLInputOverlay() },
            onShowCapture: { CaptureOverlayWindowController.shared.showCaptureOverlay() },
            onResetAll: resetAllFiles,
            hasResettableItems: hasResettableItems,
            onClear: clearAllFiles
        )
    }
    
    // MARK: - Watch Folder Management

    @MainActor
    private func addFilesFromWatchFolder(_ urls: [URL]) async {
        for url in urls {
            // Check if file already exists in the list
            guard !droppedFiles.contains(where: { $0.url == url }) else {
                continue
            }

            guard let placeholder = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: selectedPreset
            ) else {
                Self.logger.info("Skipping unsupported file from watch folder: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            droppedFiles.append(placeholder)
            queueOrder.append(placeholder.id)
            // Auto-mute if VideoLoop preset is selected and setting is enabled
            if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                droppedFiles[droppedFiles.count - 1].isMuted = true
            }
            let placeholderID = placeholder.id

            // Load details asynchronously in background
            Task(priority: .utility) {
                let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: selectedPreset)
                await MainActor.run {
                    if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        self.droppedFiles[index].apply(details: details)
                        self.droppedFiles[index].detailsLoaded = true
                    }
                }
            }
        }
    }

    private func scheduleAutoEncode() {
        Task { @MainActor in
            watchFolderCoordinator.scheduleAutoEncode {
                let shouldStart = await MainActor.run { !isConverting && canStartConversion }
                if shouldStart {
                    await evaluateMergeClipsState()
                    await startConversion()
                }
            }
        }
    }

    private func scheduleMergeCompatibilityEvaluation() {
        mergeCompatibilityScheduler.schedule {
            await evaluateMergeClipsState()
        }
    }

    @MainActor
    private func evaluateMergeClipsState() async {
        await Task.yield()

        if isConverting {
            mergeClipsAvailable = false
            mergeClipsEnabled = false
            mergeClipsTooltip = "Cannot toggle merging while conversion is running."
            return
        }

        let result = await ConversionManager.shared.evaluateMergeCompatibility(for: droppedFiles, preset: selectedPreset)

        guard !Task.isCancelled else { return }

        switch result {
        case .compatible:
            let waitingCount = droppedFiles.filter { $0.status == .waiting }.count
            mergeClipsAvailable = true
            mergeClipsTooltip = mergeClipsEnabled ? "Clips will be merged into a single export." : "Enable to merge \(waitingCount) compatible clips into one export."
        case .cancelled:
            return
        default:
            mergeClipsAvailable = false
            mergeClipsEnabled = false
            mergeClipsTooltip = result.tooltip
        }
    }

    @MainActor
    private func promptForWatchFolderSelection() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Watch Folder"
        panel.message = "Choose a folder to watch for new video files"
        if !watchFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: watchFolderPath)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func handleConversionToggle(_ optionKeyPressed: Bool) {
        Task { @MainActor in
            if isConverting {
                await cancelConversion()
                return
            }

            // If Option key is pressed, let user select output folder first
            if optionKeyPressed {
                if let folder = await selectOutputFolder() {
                    currentOutputFolder = folder
                }
                // Start conversion after folder selection (even if cancelled, use current folder)
                await startConversionWithValidation()
            } else {
                await startConversionWithValidation()
            }
        }
    }

    /// Validates output folder and starts conversion, prompting for folder if needed
    @MainActor
    private func startConversionWithValidation() async {
        // Check if "save next to original" is enabled
        let saveNextToOriginal = UserDefaults.standard.bool(forKey: AppConstants.saveNextToOriginalKey)

        if saveNextToOriginal {
            // For "save next to original" mode, validate access to each unique output directory
            let accessGranted = await validateSaveNextToOriginalAccess()
            if !accessGranted {
                return
            }
        } else {
            // Validate the current output folder is writable
            let isWritable = isOutputFolderWritable(currentOutputFolder)

            if !isWritable {
                // Prompt user to select a valid folder
                if let folder = await selectOutputFolder() {
                    currentOutputFolder = folder
                } else {
                    // User cancelled, don't start conversion
                    return
                }

                // Verify the newly selected folder is writable
                if !isOutputFolderWritable(currentOutputFolder) {
                    return
                }
            }
        }

        await startConversion()
    }

    /// Validates that we have write access to all output directories when "save next to original" is enabled.
    /// Prompts the user to grant access to directories we cannot write to.
    /// - Returns: true if all directories are accessible, false if user cancelled
    @MainActor
    private func validateSaveNextToOriginalAccess() async -> Bool {
        let waitingItems = droppedFiles.filter { $0.status == .waiting }
        guard !waitingItems.isEmpty else { return true }

        // Collect unique output directories
        var uniqueDirectories = Set<URL>()
        for item in waitingItems {
            if let outputFolder = VideoFileUtils.resolveOutputFolder(
                for: item.url,
                defaultOutputFolder: currentOutputFolder.path,
                preset: selectedPreset
            ) {
                uniqueDirectories.insert(URL(fileURLWithPath: outputFolder))
            }
        }

        // Check each directory for write access
        var directoriesNeedingAccess: [URL] = []
        for directory in uniqueDirectories {
            // First try: check if writable directly
            if isOutputFolderWritable(directory) {
                continue
            }

            // Second try: try to access via existing bookmark
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: directory) {
                if isOutputFolderWritable(directory) {
                    // Keep the bookmark active - ConversionManager will stop accessing later
                    continue
                }
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: directory)
            }

            // Third try: try parent directory bookmark (for new subdirectories)
            let parentDirectory = directory.deletingLastPathComponent()
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: parentDirectory) {
                // Try to create the directory now that we have parent access
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if isOutputFolderWritable(directory) {
                    // Save a bookmark for this directory too
                    _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: directory)
                    continue
                }
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: parentDirectory)
            }

            // Directory needs user access
            directoriesNeedingAccess.append(directory)
        }

        // Prompt user for access to inaccessible directories
        for directory in directoriesNeedingAccess {
            let granted = await promptForDirectoryAccess(directory)
            if !granted {
                return false
            }
        }

        return true
    }

    /// Prompts the user to grant access to a directory via NSOpenPanel
    /// - Returns: true if access was granted, false if user cancelled
    @MainActor
    private func promptForDirectoryAccess(_ directory: URL) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Please grant access to save files in:\n\(directory.path)"

        // Try to start at the directory or its parent if it doesn't exist
        if FileManager.default.fileExists(atPath: directory.path) {
            panel.directoryURL = directory
        } else {
            panel.directoryURL = directory.deletingLastPathComponent()
        }

        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }

        if response == .OK, let url = panel.url {
            // User selected a folder - save a writable bookmark
            _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)

            // If user selected a parent folder, also save bookmark for the target directory
            if url != directory && directory.path.hasPrefix(url.path) {
                // Start accessing the parent, then create and bookmark the target
                if url.startAccessingSecurityScopedResource() {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: directory)
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return true
        }
        return false
    }

    /// Checks if a folder exists and is writable
    private func isOutputFolderWritable(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        let path = folder.path

        // Check if folder exists, if not try to create it
        if !fileManager.fileExists(atPath: path) {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }

        // Check if writable
        return fileManager.isWritableFile(atPath: path)
    }

    @MainActor
    private func clearAllFiles() {
        guard !isConverting else { return }

        Task { @MainActor in
            // Invalidate manager-owned mux attempts before removing their rows so a
            // completed-but-not-yet-published subtitle embed cannot replace a file late.
            await ConversionManager.shared.cancelAllSubtitleEmbeddings()
            guard !isConverting else { return }
            clearAllFilesAfterEmbeddingCancellation()
        }
    }

    @MainActor
    private func clearAllFilesAfterEmbeddingCancellation() {
        let allItems = droppedFiles + encodingGroups.flatMap(\.items)

        for item in allItems {
            if item.isDownloading {
                DownloadManager.shared.cancelDownload(itemID: item.id)
            } else if let _ = item.scheduledDownloadTime {
                DownloadManager.shared.cancelScheduledDownload(itemID: item.id)
            }
            if item.subtitleStatus.isInProgress {
                cancelSubtitleGeneration(for: item)
            }
            // Cancel in-progress preview generation (thumbnails/waveforms) to free CPU
            Task { await PreviewAssetGenerator.shared.cancelGeneration(for: item.url) }
            if item.analyticsStatus.isInProgress {
                Task { await AnalyticsService.shared.cancelAnalysis() }
            }
            if item.uploadStatus == .uploading {
                Task { await UploadManager.shared.cancelUpload(itemID: item.id) }
            }
        }

        // Note: Cache cleanup is handled by the user's cleanup policy (on app launch or manually)
        // We don't delete cache immediately when files are removed, allowing re-import to reuse cached assets
        droppedFiles.removeAll()
        encodingGroups.removeAll()
        queueOrder.removeAll()
        overallProgress = 0.0
        dockProgressUpdater.reset()
    }

    private func cancelSubtitleGeneration(for item: VideoItem) {
        switch item.subtitleMethod {
        case .ocr:
            if let operationID = item.subtitleOperationID {
                Task { await TesseractService.shared.cancelGeneration(operationID: operationID) }
            }
        case .whisper:
            if let operationID = item.subtitleOperationID {
                Task { await WhisperService.shared.cancelGeneration(operationID: operationID) }
            }
        case .parakeet:
            if let operationID = item.subtitleOperationID {
                Task { await ParakeetService.shared.cancelGeneration(operationID: operationID) }
            }
        }
    }

    private func resetAllFiles(optionKeyPressed: Bool = false) {
        guard !isConverting else { return }

        // Determine whether to clear settings based on preference and Option key
        let resetClearsSettings = UserDefaults.standard.bool(forKey: AppConstants.resetClearsSettingsKey)
        let shouldClearSettings = optionKeyPressed ? !resetClearsSettings : resetClearsSettings

        var didReset = false
        for index in droppedFiles.indices where droppedFiles[index].status != .waiting {
            droppedFiles[index].resetConversionState()
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
            if shouldClearSettings {
                droppedFiles[index].clearUserSettings()
            }
            didReset = true
        }

        // Reset group items too
        for gi in encodingGroups.indices {
            for ii in encodingGroups[gi].items.indices where encodingGroups[gi].items[ii].status != .waiting {
                encodingGroups[gi].items[ii].resetConversionState()
                didReset = true
            }
        }

        if didReset {
            overallProgress = 0.0
            dockProgressUpdater.reset()
            // Defer merge evaluation to be safe
            Task { @MainActor in
                await Task.yield()
                self.scheduleMergeCompatibilityEvaluation()
            }
        }
    }

    private func applyWatchFolderLaunchActivationIfNeeded() {
        guard !hasAppliedWatchFolderLaunchActivation else { return }
        hasAppliedWatchFolderLaunchActivation = true

        let shouldActivate = watchFolderAutoActivateOnLaunch && !watchFolderPath.isEmpty

        if shouldActivate {
            if watchFolderModeEnabled {
                // State persisted as on, but the coordinator hasn't started monitoring
                // yet this launch. onChange won't fire for an unchanged value, so kick
                // the coordinator directly.
                handleWatchFolderToggle(true)
            } else {
                watchFolderModeEnabled = true
            }
        } else if watchFolderModeEnabled {
            // Auto-activate is off (or folder is gone) — don't carry stale "on" state
            // from a previous session into this launch.
            watchFolderModeEnabled = false
        }
    }

    private func handleWatchFolderToggle(_ enabled: Bool) {
        Task { @MainActor in
            if enabled {
                let success = await watchFolderCoordinator.enableWatchMode(
                    currentPath: watchFolderPath,
                    promptForFolder: { await promptForWatchFolderSelection() },
                    updatePath: { newPath in
                        Task { @MainActor in
                            watchFolderPath = newPath
                        }
                    },
                    onNewFiles: { urls in await addFilesFromWatchFolder(urls) }
                )

                if !success {
                    watchFolderModeEnabled = false
                }
            } else {
                await watchFolderCoordinator.disableWatchMode()
            }
        }
    }
    

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(minWidth: 800, minHeight: 400)
    }
}

// MARK: - Global Keyboard Shortcut Handler

private struct GlobalKeyboardShortcutHandler: NSViewRepresentable {
    var onToggleWatchFolder: () -> Void
    var onSelectOutputFolder: () -> Void
    var onToggleMerge: () -> Void
    var onResetAll: () -> Void
    var onToggleConversion: (_ optionKeyPressed: Bool) -> Void
    var onShowURLInput: () -> Void
    var onShowCapture: () -> Void
    var onShowPresetQuickSelect: () -> Void
    var onSelectPresetByIndex: (Int) -> Bool
    var onShowShortcuts: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onToggleWatchFolder: onToggleWatchFolder,
            onSelectOutputFolder: onSelectOutputFolder,
            onToggleMerge: onToggleMerge,
            onResetAll: onResetAll,
            onToggleConversion: onToggleConversion,
            onShowURLInput: onShowURLInput,
            onShowCapture: onShowCapture,
            onShowPresetQuickSelect: onShowPresetQuickSelect,
            onSelectPresetByIndex: onSelectPresetByIndex,
            onShowShortcuts: onShowShortcuts
        )
    }
    
    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onToggleWatchFolder = onToggleWatchFolder
        context.coordinator.onSelectOutputFolder = onSelectOutputFolder
        context.coordinator.onToggleMerge = onToggleMerge
        context.coordinator.onResetAll = onResetAll
        context.coordinator.onToggleConversion = onToggleConversion
        context.coordinator.onShowURLInput = onShowURLInput
        context.coordinator.onShowCapture = onShowCapture
        context.coordinator.onShowPresetQuickSelect = onShowPresetQuickSelect
        context.coordinator.onSelectPresetByIndex = onSelectPresetByIndex
        context.coordinator.onShowShortcuts = onShowShortcuts
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }
    
    final class Coordinator {
        var onToggleWatchFolder: () -> Void
        var onSelectOutputFolder: () -> Void
        var onToggleMerge: () -> Void
        var onResetAll: () -> Void
        var onToggleConversion: (_ optionKeyPressed: Bool) -> Void
        var onShowURLInput: () -> Void
        var onShowCapture: () -> Void
        var onShowPresetQuickSelect: () -> Void
        var onSelectPresetByIndex: (Int) -> Bool
        var onShowShortcuts: () -> Void
        private var monitor: Any?

        init(
            onToggleWatchFolder: @escaping () -> Void,
            onSelectOutputFolder: @escaping () -> Void,
            onToggleMerge: @escaping () -> Void,
            onResetAll: @escaping () -> Void,
            onToggleConversion: @escaping (_ optionKeyPressed: Bool) -> Void,
            onShowURLInput: @escaping () -> Void,
            onShowCapture: @escaping () -> Void,
            onShowPresetQuickSelect: @escaping () -> Void,
            onSelectPresetByIndex: @escaping (Int) -> Bool,
            onShowShortcuts: @escaping () -> Void
        ) {
            self.onToggleWatchFolder = onToggleWatchFolder
            self.onSelectOutputFolder = onSelectOutputFolder
            self.onToggleMerge = onToggleMerge
            self.onResetAll = onResetAll
            self.onToggleConversion = onToggleConversion
            self.onShowURLInput = onShowURLInput
            self.onShowCapture = onShowCapture
            self.onShowPresetQuickSelect = onShowPresetQuickSelect
            self.onSelectPresetByIndex = onSelectPresetByIndex
            self.onShowShortcuts = onShowShortcuts
        }
        
        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                
                let hasCommand = event.modifierFlags.contains(.command)
                let hasOption = event.modifierFlags.contains(.option)
                let hasShift = event.modifierFlags.contains(.shift)
                let hasControl = event.modifierFlags.contains(.control)
                
                // Option+W: Toggle Watch Folder
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_W {
                    self.onToggleWatchFolder()
                    return nil
                }
                
                // Option+F: Select Output Folder
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_F {
                    self.onSelectOutputFolder()
                    return nil
                }
                
                // Option+M: Toggle Merge
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_M {
                    self.onToggleMerge()
                    return nil
                }
                
                // Cmd+Shift+R: Reset All
                if hasCommand && hasShift && !hasOption && !hasControl && event.keyCode == kVK_ANSI_R {
                    self.onResetAll()
                    return nil
                }

                // Cmd+Return: Start/Stop Conversion
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_Return {
                    self.onToggleConversion(false)
                    return nil
                }

                // Cmd+D: Show URL Input Overlay (D for Download)
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_D {
                    self.onShowURLInput()
                    return nil
                }

                // Cmd+Shift+C: Open Capture Mode
                if hasCommand && hasShift && !hasOption && !hasControl && event.keyCode == kVK_ANSI_C {
                    self.onShowCapture()
                    return nil
                }

                // Cmd+P: Show Preset Quick Select
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_P {
                    self.onShowPresetQuickSelect()
                    return nil
                }

                // Control+K: Show Shortcuts (opens Settings to Shortcuts tab)
                if hasControl && !hasCommand && !hasOption && !hasShift && event.keyCode == kVK_ANSI_K {
                    self.onShowShortcuts()
                    return nil
                }

                // Cmd+1 through Cmd+0: Quick select preset by index (only when no sheets are open)
                if hasCommand && !hasOption && !hasShift && !hasControl {
                    let numberKeyCodes: [UInt16] = [
                        UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
                        UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
                        UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
                        UInt16(kVK_ANSI_0)  // 0 = 10th preset
                    ]
                    if let index = numberKeyCodes.firstIndex(of: event.keyCode) {
                        // Only consume event if it was actually handled
                        if self.onSelectPresetByIndex(index) {
                            return nil
                        }
                        // Otherwise pass through to let sheets handle it
                        return event
                    }
                }

                return event
            }
        }
        
        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

// MARK: - Content View Modifiers

/// ViewModifier for all sheet presentations
private struct ContentViewSheets: ViewModifier {
    @Binding var droppedFiles: [VideoItem]
    @Binding var encodingGroups: [EncodingGroup]
    @Binding var trimSheetItemID: UUID?
    @Binding var trimWithCropSheetItemID: UUID?
    @Binding var timecodeSheetItemID: UUID?
    @Binding var audioConfigSheetItemID: UUID?
    @Binding var dcpMetadataSheetItemID: UUID?
    @Binding var imfMetadataSheetItemID: UUID?
    let selectedPreset: ExportPreset
    @Binding var showCaptureSheet: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding(for: $trimSheetItemID)) {
                trimSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $trimWithCropSheetItemID)) {
                trimWithCropSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $timecodeSheetItemID)) {
                timecodeSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $audioConfigSheetItemID)) {
                audioConfigSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $dcpMetadataSheetItemID)) {
                dcpMetadataSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $imfMetadataSheetItemID)) {
                imfMetadataSheetContent
            }
            // Capture mode now uses CaptureOverlayWindowController instead of a sheet
    }

    /// Returns a SwiftUI binding into `droppedFiles` or any `encodingGroups[*].items`
    /// for the given ID. Sheets opened from the Group Editor window can target items
    /// that live inside a group, not only ungrouped singles — without this lookup the
    /// sheet renders blank because the original `droppedFiles.firstIndex` returns nil.
    private func itemBinding(id: UUID) -> Binding<VideoItem>? {
        if let idx = droppedFiles.firstIndex(where: { $0.id == id }) {
            return $droppedFiles[idx]
        }
        for gIdx in encodingGroups.indices {
            if let iIdx = encodingGroups[gIdx].items.firstIndex(where: { $0.id == id }) {
                return $encodingGroups[gIdx].items[iIdx]
            }
        }
        return nil
    }

    @ViewBuilder
    private var trimSheetContent: some View {
        if let id = trimSheetItemID, let binding = itemBinding(id: id) {
            PreviewPlayerView(item: binding)
        }
    }

    @ViewBuilder
    private var trimWithCropSheetContent: some View {
        if let id = trimWithCropSheetItemID, let binding = itemBinding(id: id) {
            PreviewPlayerView(item: binding, initialCropExpanded: true)
        }
    }

    @ViewBuilder
    private var timecodeSheetContent: some View {
        if let id = timecodeSheetItemID, let binding = itemBinding(id: id) {
            TimecodeView(item: binding)
        }
    }

    @ViewBuilder
    private var audioConfigSheetContent: some View {
        if let id = audioConfigSheetItemID, let binding = itemBinding(id: id) {
            AudioRoutingView(item: binding, preset: selectedPreset)
        }
    }

    @ViewBuilder
    private var dcpMetadataSheetContent: some View {
        if let id = dcpMetadataSheetItemID, let binding = itemBinding(id: id) {
            DCPMetadataView(item: binding)
        }
    }

    @ViewBuilder
    private var imfMetadataSheetContent: some View {
        if let id = imfMetadataSheetItemID, let binding = itemBinding(id: id) {
            IMFMetadataView(item: binding)
        }
    }

    private func sheetBinding(for itemID: Binding<UUID?>) -> Binding<Bool> {
        Binding(
            get: { itemID.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    itemID.wrappedValue = nil
                }
            }
        )
    }
}

/// ViewModifier for onAppear lifecycle
private struct ContentViewLifecycle: ViewModifier {
    @Binding var hasInitializedPreset: Bool
    @Binding var hasUserChangedPreset: Bool
    @Binding var selectedPreset: ExportPreset
    @Binding var currentOutputFolder: URL
    @Binding var isConverting: Bool
    let storedDefaultPresetRawValue: String
    let outputFolder: String
    let scheduleMergeCompatibilityEvaluation: () -> Void
    let refreshExpectedOutputURLs: (ExportPreset) -> Void
    let updateChecker: UpdateChecker

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !hasInitializedPreset {
                    selectedPreset = ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
                    hasInitializedPreset = true
                    hasUserChangedPreset = false
                }
                let storedFolderURL = URL(fileURLWithPath: outputFolder)
                if storedFolderURL.path != currentOutputFolder.path {
                    currentOutputFolder = storedFolderURL
                } else {
                    refreshExpectedOutputURLs(selectedPreset)
                }
                Task {
                    if !isConverting {
                        isConverting = await ConversionManager.shared.isConvertingStatus()
                    }
                }
                scheduleMergeCompatibilityEvaluation()
                updateChecker.checkForUpdatesIfNeeded()
                // One-time policy notice on first launch under Sparkle. No-op
                // afterwards; no-op for Homebrew installs.
                DispatchQueue.main.async {
                    SparkleUpdater.shared.presentFirstLaunchNoticeIfNeeded()
                }
            }
    }
}

/// ViewModifier for onChange handlers
private struct ContentViewChangeHandlers: ViewModifier {
    @Binding var showUpdateNotification: Bool
    @Binding var updateNotificationTask: Task<Void, Never>?
    @Binding var selectedPreset: ExportPreset
    @Binding var hasUserChangedPreset: Bool
    @Binding var currentOutputFolder: URL
    @Binding var isFileImporterPresented: Bool
    let mergeClipsEnabled: Bool
    let watchFolderModeEnabled: Bool
    let isConverting: Bool
    let droppedFilesCount: Int
    let updateChecker: UpdateChecker
    let outputFolder: String
    let storedDefaultPresetRawValue: String
    let refreshExpectedOutputURLs: (ExportPreset) -> Void
    let scheduleMergeCompatibilityEvaluation: () -> Void
    let handleWatchFolderToggle: (Bool) -> Void
    let scheduleAutoEncode: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: updateChecker.updateAvailable) { _, available in
                handleUpdateAvailable(available)
            }
            .onChange(of: storedDefaultPresetRawValue) { _, newValue in
                selectedPreset = ExportPreset(rawValue: newValue) ?? .videoLoop
                hasUserChangedPreset = false
            }
            .onChange(of: outputFolder) { _, newValue in
                handleOutputFolderChange(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showFileImporter)) { _ in
                isFileImporterPresented = true
            }
            .onChange(of: watchFolderModeEnabled) { _, newValue in
                handleWatchFolderToggle(newValue)
            }
            .onChange(of: mergeClipsEnabled) { _, _ in
                refreshExpectedOutputURLs(selectedPreset)
            }
            .onChange(of: isConverting) { _, _ in
                scheduleMergeCompatibilityEvaluation()
            }
            .onChange(of: droppedFilesCount) { oldCount, newCount in
                if watchFolderModeEnabled && newCount > oldCount {
                    scheduleAutoEncode()
                }
            }
    }

    private func handleUpdateAvailable(_ available: Bool) {
        if available {
            withAnimation {
                showUpdateNotification = true
            }
            updateNotificationTask?.cancel()
            updateNotificationTask = Task {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation {
                    showUpdateNotification = false
                }
            }
        }
    }

    private func handleOutputFolderChange(_ newValue: String) {
        let updatedFolderURL = URL(fileURLWithPath: newValue)
        if updatedFolderURL.path != currentOutputFolder.path {
            currentOutputFolder = updatedFolderURL
        } else {
            refreshExpectedOutputURLs(selectedPreset)
        }
    }
}

/// ViewModifier for notification handlers (enqueue and convert immediately)
private struct ContentViewNotificationHandlers: ViewModifier {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ContentViewNotificationHandlers")

    @Binding var droppedFiles: [VideoItem]
    @Binding var queueOrder: [UUID]
    @Binding var currentOutputFolder: URL
    @Binding var outputFolder: String
    @Binding var isFileImporterPresented: Bool
    @Binding var pendingConvertAfterImport: Bool
    let selectedPreset: ExportPreset
    let videoLoopDefaultMuted: Bool
    let startConversion: () async -> Void
    /// Switches the app to a given preset (with the usual side effects) before a
    /// per-preset "Convert Immediately" App Intent starts conversion.
    let applyPreset: (ExportPreset) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .enqueueFileURL)) { notification in
                handleEnqueueNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .convertImmediately)) { notification in
                handleConvertImmediatelyNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .convertPickFiles)) { notification in
                handleConvertPickFilesNotification(notification)
            }
    }

    /// Handles a convert/enqueue App Intent that ran without any file input
    /// (e.g. a Spotlight/Siri phrase, which can't attach files): switch to the
    /// carried preset, bring the window forward, and present the file importer.
    /// For convert intents (`startConversion` flag absent or true), conversion
    /// starts once the user picks files; the enqueue intent only queues them.
    private func handleConvertPickFilesNotification(_ notification: Notification) {
        // Mark the buffered request handled so a later drain() won't replay it.
        if let requestID = notification.userInfo?[PendingAppIntentRequests.requestIDKey] as? UUID {
            PendingAppIntentRequests.shared.consume(id: requestID)
        }

        if let rawValue = notification.userInfo?["presetRawValue"] as? String,
           let preset = ExportPreset(rawValue: rawValue), preset != selectedPreset {
            applyPreset(preset)
        }

        pendingConvertAfterImport = (notification.userInfo?["startConversion"] as? Bool) ?? true
        NSApp.activate(ignoringOtherApps: true)
        isFileImporterPresented = true
    }

    private func handleEnqueueNotification(_ notification: Notification) {
        // Mark the buffered request handled so a later drain() won't replay it.
        if let requestID = notification.userInfo?[PendingAppIntentRequests.requestIDKey] as? UUID {
            PendingAppIntentRequests.shared.consume(id: requestID)
        }

        let urls: [URL]
        if let singleURL = notification.object as? URL {
            urls = [singleURL]
        } else if let multipleURLs = notification.object as? [URL] {
            urls = multipleURLs
        } else {
            return
        }

        for url in urls {
            guard !droppedFiles.contains(where: { $0.url == url }) else { continue }

            guard let placeholder = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: selectedPreset
            ) else {
                Self.logger.info("Skipping unsupported file from AppIntent: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            droppedFiles.append(placeholder)
            queueOrder.append(placeholder.id)
            if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                droppedFiles[droppedFiles.count - 1].isMuted = true
            }
            let placeholderID = placeholder.id

            Task(priority: .utility) {
                let details = await VideoFileUtils.loadDetails(
                    for: url,
                    outputFolder: outputFolder,
                    preset: selectedPreset,
                    generateRowThumbnailIfMissing: false
                )

                await MainActor.run {
                    if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        droppedFiles[index].apply(details: details)
                        droppedFiles[index].detailsLoaded = true
                    }
                }

                if details.thumbnailData == nil {
                    Task.detached(priority: .background) {
                        let thumbnailData = await VideoFileUtils.getCachedThumbnail(url: url, generateRowThumbnailIfMissing: true)
                        guard let thumbnailData else { return }
                        await MainActor.run {
                            if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }),
                               droppedFiles[index].thumbnailData == nil {
                                droppedFiles[index].thumbnailData = thumbnailData
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleConvertImmediatelyNotification(_ notification: Notification) {
        guard let info = notification.userInfo,
              let folderURL = info["outputFolderURL"] as? URL else { return }

        // Mark the buffered request handled so a later drain() won't replay it.
        if let requestID = info[PendingAppIntentRequests.requestIDKey] as? UUID {
            PendingAppIntentRequests.shared.consume(id: requestID)
        }

        let fileURLs: [URL]
        if let singleURL = info["fileURL"] as? URL {
            fileURLs = [singleURL]
        } else if let multipleURLs = info["fileURLs"] as? [URL] {
            fileURLs = multipleURLs
        } else {
            return
        }

        // Per-preset intents carry the preset to convert with; fall back to the
        // app's currently selected preset (e.g. the legacy ConvertImmediatelyIntent).
        let preset: ExportPreset
        if let rawValue = info["presetRawValue"] as? String,
           let requested = ExportPreset(rawValue: rawValue) {
            preset = requested
        } else {
            preset = selectedPreset
        }

        Task {
            await MainActor.run {
                currentOutputFolder = folderURL
                outputFolder = folderURL.path
                // Switch the app to the requested preset before converting so
                // startConversion() (which reads selectedPreset) uses it too.
                if preset != selectedPreset {
                    applyPreset(preset)
                }
            }

            for fileURL in fileURLs {
                if var videoItem = await VideoFileUtils.createVideoItem(
                    from: fileURL,
                    outputFolder: folderURL.path,
                    preset: preset
                ) {
                    await MainActor.run {
                        if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                            if preset == .videoLoop && videoLoopDefaultMuted {
                                videoItem.isMuted = true
                            }
                            droppedFiles.append(videoItem)
                            queueOrder.append(videoItem.id)
                        }
                    }
                }
            }
            await startConversion()
        }
    }
}

#if DEBUG
/// The app owns all fixture filesystem operations; the UI runner's temporary
/// directory is private to its sandbox and cannot be shared with bundled FFmpeg.
enum UITestFixtureConfiguration {
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterUITestFixtures", isDirectory: true)
    }

    static func configureLaunchDefaults() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AMC_UI_TEST_SESSION"] == "1" else { return }
        // Settings audits must not inspect personal upload destinations or
        // touch their Keychain credentials. A volatile fixture also prevents
        // the Upload pane's first-run path from persisting a default profile.
        let profile = UploadProfile(
            id: UUID(uuidString: "84A6535B-CE10-4DE4-AE11-ED740CA1A420")!,
            name: "UI Test Upload"
        )
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[AppConstants.uploadProfilesKey] = try? JSONEncoder().encode([profile])
        arguments[AppConstants.uploadSelectedProfileIDKey] = profile.id.uuidString
        arguments[AppConstants.uploadProfileMigrationV2Key] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        if environment["AMC_UI_TEST_CLEANUP_FIXTURES"] == "1" {
            // Runs in App.init, before XCUIApplication.launch() returns.
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "UITestFixture")
                        .error("Unable to clean UI test fixtures: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        guard environment["AMC_UI_TEST_GENERATED_FIXTURE"] == "1" else { return }
        // Configure before any @AppStorage is constructed, so syncing the view's
        // current folder cannot write the fixture path into the saved preferences.
        arguments["outputFolder"] = directory.path
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
#endif
