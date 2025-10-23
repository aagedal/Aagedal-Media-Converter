// Aagedal VideoLoop Converter 2.0
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

// Custom notification to trigger file importer from menu command
#if !os(iOS)
extension Notification.Name {
    static let showFileImporter = Notification.Name("showFileImporter")
}
#endif

struct ContentView: View {
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
    @State private var isConverting: Bool = false
    @State private var overallProgress: Double = 0.0
    @State private var isFileImporterPresented = false
    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue
    @State private var selectedPreset: ExportPreset = .videoLoop
    @State private var hasInitializedPreset = false
    @State private var hasUserChangedPreset = false
    @State private var dockProgressUpdater = DockProgressUpdater()
    @State private var progressTask: Task<Void, Never>?
    @AppStorage(AppConstants.customPreset1NameKey) private var customPreset1Name = AppConstants.defaultCustomPresetDisplayNames[0]
    @AppStorage(AppConstants.customPreset2NameKey) private var customPreset2Name = AppConstants.defaultCustomPresetDisplayNames[1]
    @AppStorage(AppConstants.customPreset3NameKey) private var customPreset3Name = AppConstants.defaultCustomPresetDisplayNames[2]
    @AppStorage(AppConstants.watchFolderModeKey) private var watchFolderModeEnabled = false
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @State private var watchFolderManager = WatchFolderManager()
    @State private var autoEncodeTask: Task<Void, Never>?
    
    // Using shared AppConstants for supported file types
    private var supportedVideoTypes: [UTType] {
        AppConstants.supportedVideoTypes.compactMap { UTType($0) }
    }
    
    // Only allow starting conversion when at least one item is still waiting
    private var canStartConversion: Bool {
        droppedFiles.contains { $0.status == .waiting }
    }

    var body: some View {
        VStack {
            // File list with drag and drop support
            VideoFileListView(
                droppedFiles: $droppedFiles,
                currentProgress: $overallProgress,
                onFileImport: { isFileImporterPresented = true },
                onDoubleClick: { isFileImporterPresented = true },
                onDelete: { indexSet in
                    droppedFiles.remove(atOffsets: indexSet)
                },
                onReset: { index in
                    if index < droppedFiles.count {
                        droppedFiles[index].status = .waiting
                        droppedFiles[index].progress = 0.0
                        droppedFiles[index].eta = nil
                        droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
                    }
                },
                preset: selectedPreset
            )
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: supportedVideoTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result: result)
            }
            .task {
                await startProgressUpdates()
            }
            .toolbar {
                // Convert/Cancel Button
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { @MainActor in
                            // Determine current conversion state from manager to stay in sync
                            let currentlyConverting = await ConversionManager.shared.isConvertingStatus()
                            isConverting = currentlyConverting
                            if currentlyConverting {
                                // Cancel ongoing conversions
                                await cancelConversion()
                            } else {
                                // Start new conversions
                                await startConversion()
                            }
                        }
                    } label: {
                        if isConverting {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "play.circle")
                                .foregroundStyle((droppedFiles.isEmpty || !canStartConversion) ? .gray : .green)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(droppedFiles.isEmpty || (!canStartConversion && !isConverting))
                    .help(droppedFiles.isEmpty ?
                          "Add files to begin conversion" :
                          (isConverting ? "Cancel all conversions" : (canStartConversion ? "Start converting all files" : "No files ready to convert")))
                }
                
                
                // Watch Folder Mode Toggle
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $watchFolderModeEnabled) {
                        Label("Watch Mode", systemImage: watchFolderModeEnabled ? "eye.fill" : "eye")
                    }
                    .toggleStyle(.button)
                    .help(watchFolderPath.isEmpty ? "Select a watch folder to enable Watch Mode" : (watchFolderModeEnabled ? "Stop watching \(watchFolderPath)" : "Start watching \(watchFolderPath)"))
                }
                
                // Import button
                ToolbarItem(placement: .automatic) {
                    Button(action: { isFileImporterPresented = true }) {
                        Label("Import", systemImage: "plus.circle")
                            .foregroundColor(.accentColor)
                    }
                    .help("Import video files")
                    .keyboardShortcut("i", modifiers: .command)
                }
                
                // Output folder button
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            if let folder = await selectOutputFolder() {
                                // This will trigger the didSet on currentOutputFolder
                                // which will update the @AppStorage value
                                currentOutputFolder = folder
                            }
                        }
                    } label: {
                        Label("Output", systemImage: "folder.badge.gearshape")
                            .foregroundColor(.accentColor)
                    }
                    .help("Select output folder")
                    .keyboardShortcut("o", modifiers: .command)
                }
                
                // Spacer to push remaining items to the right
                ToolbarItem(placement: .automatic) {
                    Spacer()
                }
                
                // Clear List button
                ToolbarItem(placement: .automatic) {
                    Button {
                        // Only allow clearing if not currently converting
                        guard !isConverting else { return }
                        droppedFiles.removeAll()
                        overallProgress = 0.0
                        // Ensure dock progress is reset when clearing the list
                        dockProgressUpdater.reset()
                    } label: {
                        Label("Clear", systemImage: "square.stack.3d.up.slash")
                            .foregroundStyle((droppedFiles.isEmpty || isConverting) ? Color.gray : Color.red)
                    }
                    .help("Remove all files from the list")
                    .disabled(droppedFiles.isEmpty || isConverting)
                }
                
                // Preset Picker
                ToolbarItem(placement: .automatic) {
                    Picker("Preset", selection: toolbarPresetBinding) {
                        ForEach(ExportPreset.allCases) { preset in
                            Text(displayName(for: preset)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .disabled(isConverting)
                    .foregroundColor(.primary)
                    .help("Select export preset for all files")
                }
                ToolbarItem {
                    SettingsLink {
                        Image(systemName: "info.circle").foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Application Settings")
                    .padding(.horizontal, 8)
                }
            }
            
            // Overall progress bar
            if isConverting {
                VStack(alignment: .leading) {
                    Text("Overall Progress: \(Int(overallProgress * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    ProgressView(value: overallProgress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                }
                .padding()
            }
        }
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
                refreshExpectedOutputURLs(for: selectedPreset)
            }
            Task {
                isConverting = await ConversionManager.shared.isConvertingStatus()
            }
        }
        .onChange(of: storedDefaultPresetRawValue) { _, newValue in
            selectedPreset = ExportPreset(rawValue: newValue) ?? .videoLoop
            hasUserChangedPreset = false
        }
        .onChange(of: outputFolder) { _, newValue in
            let updatedFolderURL = URL(fileURLWithPath: newValue)
            if updatedFolderURL.path != currentOutputFolder.path {
                currentOutputFolder = updatedFolderURL
            } else {
                refreshExpectedOutputURLs(for: selectedPreset)
            }
        }
        // Listen for menu command
        .onReceive(NotificationCenter.default.publisher(for: .showFileImporter)) { _ in
            isFileImporterPresented = true
        }
        .onChange(of: watchFolderModeEnabled) { _, newValue in
            handleWatchModeChange(enabled: newValue)
        }
        .onChange(of: droppedFiles.count) { oldCount, newCount in
            if watchFolderModeEnabled && newCount > oldCount {
                scheduleAutoEncode()
            }
        }
        // Listen for App Intent to enqueue file
        .onReceive(NotificationCenter.default.publisher(for: .enqueueFileURL)) { notification in
            guard let url = notification.object as? URL else { return }
            Task {
                if let videoItem = await VideoFileUtils.createVideoItem(
                    from: url,
                    outputFolder: outputFolder,
                    preset: selectedPreset
                ) {
                    await MainActor.run {
                        if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                            droppedFiles.append(videoItem)
                        }
                    }
                }
            }
        }
        // Handle ConvertImmediatelyIntent
        .onReceive(NotificationCenter.default.publisher(for: .convertImmediately)) { notification in
            guard let info = notification.userInfo,
                  let fileURL = info["fileURL"] as? URL,
                  let folderURL = info["outputFolderURL"] as? URL else { return }

            Task {
                // Update output folder to match source directory
                await MainActor.run {
                    currentOutputFolder = folderURL
                    outputFolder = folderURL.path
                }

                if let videoItem = await VideoFileUtils.createVideoItem(
                    from: fileURL,
                    outputFolder: folderURL.path,
                    preset: selectedPreset
                ) {
                    await MainActor.run {
                        if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                            droppedFiles.append(videoItem)
                        }
                    }
                    await startConversion()
                }
            }
        }
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
            return url
        }
        return nil
    }
    
    // Handle file selection from file picker
    private func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    if let videoItem = await VideoFileUtils.createVideoItem(
                        from: url,
                        outputFolder: outputFolder,
                        preset: selectedPreset
                    ) {
                        if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                            droppedFiles.append(videoItem)
                        }
                    } else {
                        print("Skipping unsupported file: \(url.lastPathComponent)")
                    }
                }
            }
        case .failure(let error):
            print("Error selecting files: \(error.localizedDescription)")
        }
    }
    
    private func startProgressUpdates() async {
        progressTask?.cancel()
        progressTask = Task {
            for await progress in await ConversionManager.shared.progressUpdates() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    overallProgress = progress
                    dockProgressUpdater.updateProgress(progress)
                    // Automatically reset converting state when done
                    if progress >= 1.0 {
                        isConverting = false
                    }
                }
            }
        }
    }
    
    private func startConversion() async {
        isConverting = true
        // Initialize dock progress with 0% to show it immediately
        dockProgressUpdater.updateProgress(0.0)

        await ConversionManager.shared.startConversion(
                droppedFiles: $droppedFiles,
                outputFolder: currentOutputFolder.path,
                preset: selectedPreset
            )
        

    }
    
    private func cancelConversion() async {
        await ConversionManager.shared.cancelAllConversions()
        isConverting = false
        // Reset dock progress immediately on cancel
        dockProgressUpdater.reset()
    }
    
    private func refreshExpectedOutputURLs(for preset: ExportPreset) {
        for index in droppedFiles.indices where droppedFiles[index].status == .waiting {
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: preset)
        }
    }

    private func displayName(for preset: ExportPreset) -> String {
        guard let slot = preset.customSlotIndex else {
            return preset.displayName
        }
        let prefixes = AppConstants.customPresetPrefixes
        let fallbackSuffixes = AppConstants.defaultCustomPresetNameSuffixes
        let prefix = prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
        let fallbackSuffix = fallbackSuffixes.indices.contains(slot) ? fallbackSuffixes[slot] : "Custom Preset"
        let storedSuffix: String
        switch slot {
        case 0: storedSuffix = customPreset1Name
        case 1: storedSuffix = customPreset2Name
        case 2: storedSuffix = customPreset3Name
        default: storedSuffix = fallbackSuffix
        }
        let sanitizedSuffix = sanitizeCustomNameSuffix(storedSuffix, prefix: prefix, fallback: fallbackSuffix)
        return "\(prefix) \(sanitizedSuffix)"
    }

    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let remainder = trimmed[cutoff...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let remainder = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        return trimmed
    }

    private func expectedOutputURL(for item: VideoItem, preset: ExportPreset) -> URL? {
        let sanitizedBaseName = FileNameProcessor.processFileName(item.url.deletingPathExtension().lastPathComponent)
        let outputFileName = sanitizedBaseName + preset.fileSuffix + "." + preset.fileExtension
        return currentOutputFolder.appendingPathComponent(outputFileName)
    }

    private var toolbarPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { selectedPreset },
            set: { newValue in
                hasUserChangedPreset = true
                selectedPreset = newValue
                refreshExpectedOutputURLs(for: newValue)
            }
        )
    }
    
    // MARK: - Watch Folder Management
    
    private func handleWatchModeChange(enabled: Bool) {
        Task {
            if enabled {
                if watchFolderPath.isEmpty {
                    let selectedFolder = await MainActor.run { promptForWatchFolderSelection() }
                    guard let folderURL = selectedFolder else {
                        await MainActor.run {
                            watchFolderModeEnabled = false
                        }
                        return
                    }
                    await MainActor.run {
                        watchFolderPath = folderURL.path
                    }
                    _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: folderURL)
                }
                
                await watchFolderManager.startMonitoring(folderPath: watchFolderPath) { newFileURLs in
                    Task { @MainActor in
                        await self.addFilesFromWatchFolder(newFileURLs)
                    }
                }
            } else {
                await watchFolderManager.stopMonitoring()
                autoEncodeTask?.cancel()
                autoEncodeTask = nil
            }
        }
    }
    
    @MainActor
    private func addFilesFromWatchFolder(_ urls: [URL]) async {
        for url in urls {
            // Check if file already exists in the list
            guard !droppedFiles.contains(where: { $0.url == url }) else {
                continue
            }
            
            if let videoItem = await VideoFileUtils.createVideoItem(
                from: url,
                outputFolder: outputFolder,
                preset: selectedPreset
            ) {
                droppedFiles.append(videoItem)
            }
        }
    }
    
    private func scheduleAutoEncode() {
        // Cancel any existing scheduled task
        autoEncodeTask?.cancel()
        
        // Schedule encoding after 2 second delay
        autoEncodeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            guard !Task.isCancelled else { return }
            
            // Only start if not already converting and there are files waiting
            if !isConverting && canStartConversion {
                await startConversion()
            }
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(minWidth: 800, minHeight: 400)
    }
}
