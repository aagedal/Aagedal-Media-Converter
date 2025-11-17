// Aagedal Media Converter
// Copyright © 2025 Truls Aaged
// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path
    @AppStorage(AppConstants.includeDateTagPreferenceKey) private var includeDateTagByDefault = false
    @AppStorage(AppConstants.preserveMetadataPreferenceKey) private var preserveMetadataByDefault = false
    @AppStorage(AppConstants.screenshotDirectoryKey) private var screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path
    @AppStorage(AppConstants.previewCacheCleanupPolicyKey) private var previewCacheCleanupPolicyRaw = AppConstants.defaultPreviewCacheCleanupPolicyRaw
    
    @State private var isClearingPreviewCache = false
    @State private var previewCacheSizeBytes: Int64 = 0

    var body: some View {
        Form {
            outputFolderSection
            screenshotSection
            previewCacheSection
            metadataSection
            linksSection
        }
        .formStyle(.grouped)
        .onChange(of: previewCacheCleanupPolicyRaw) { _, newValue in
            let policy = PreviewCacheCleanupPolicy(rawValue: newValue) ?? .purgeOnLaunch
            Task {
                await PreviewAssetGenerator.shared.applyCleanupPolicy(policy)
                await refreshPreviewCacheSize()
            }
        }
        .task { await refreshPreviewCacheSize() }
        .onChange(of: isClearingPreviewCache) { _, isClearing in
            guard !isClearing else { return }
            Task { await refreshPreviewCacheSize() }
        }
    }

    private var outputFolderSection: some View {
        Section(header: Text("Output Folder")) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Default Output Folder:")
                    .font(.headline)

                HStack {
                    Text(outputFolder)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(outputFolder)

                    Button(action: {
                        let url = URL(fileURLWithPath: outputFolder)
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            outputFolder = AppConstants.defaultOutputDirectory.path
                            NSWorkspace.shared.activateFileViewerSelecting([AppConstants.defaultOutputDirectory])
                            return
                        }

                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Show in Finder")

                    Button(action: { selectNewOutputFolder() }) {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Change default output folder")
                }
            }
            .padding(8)
        }
    }

    private var screenshotSection: some View {
        Section(header: Text("Screenshots")) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Default Screenshot Folder:")
                    .font(.headline)

                HStack {
                    Text(screenshotDirectoryPath)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(screenshotDirectoryPath)

                    Button(action: {
                        let url = URL(fileURLWithPath: screenshotDirectoryPath)
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path
                            return
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Show in Finder")

                    Button(action: { selectScreenshotDirectory() }) {
                        Image(systemName: "camera.on.rectangle")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Change screenshot folder")

                    Button(action: { screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Reset to Downloads")
                }
            }
            .padding(8)
            Text("Frames captured from the preview will be saved as JPEGs into this folder.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var previewCacheSection: some View {
        Section(header: Text("Preview Cache")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Cleanup policy", selection: $previewCacheCleanupPolicyRaw) {
                    ForEach(PreviewCacheCleanupPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text(previewCacheCleanupPolicy.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button {
                        isClearingPreviewCache = true
                        Task {
                            await PreviewAssetGenerator.shared.cleanupAllCache()
                            await refreshPreviewCacheSize()
                            await MainActor.run { isClearingPreviewCache = false }
                        }
                    } label: {
                        Label("Clear cache now", systemImage: "trash")
                    }
                    .disabled(isClearingPreviewCache)

                    if isClearingPreviewCache {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }

                    Text(previewCacheSizeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var metadataSection: some View {
        Section(header: Text("Metadata")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Preserve all original metadata", isOn: $preserveMetadataByDefault)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, the original file's metadata is kept intact during conversion")
                Text("By default, metadata such as title, timecode, and encoder tags are stripped to keep output files clean. Enable this to keep all metadata untouched. However, color related metadata (including HDR) will always be preserved, to assure an accurate viewing experience.")
                    .font(Font.caption.italic())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $includeDateTagByDefault) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Include date tag on new files", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                    Text("Date tag is an autogenerated text added to the beginning of the comment field, e.g. 'Date generated: 20250925'. The tag precedes any custom comment you enter on the video card.")
                        .font(Font.caption.italic())
                        .foregroundColor(preserveMetadataByDefault ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(SwitchToggleStyle())
            .disabled(preserveMetadataByDefault)
            .help("Controls whether newly added files include the \"Date generated\" metadata tag by default")
        }
    }

    private var linksSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Source code and author website", systemImage: "questionmark.circle")
                    .font(.headline)
                HStack {
                    Link("GitHub Repository", destination: URL(string: "https://github.com/aagedal/Aagedal-Media-Converter/tree/main")!)
                    Spacer()
                    Link("Developer Website", destination: URL(string: "https://aagedal.me/about")!)
                }
                .padding(8)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private var previewCacheCleanupPolicy: PreviewCacheCleanupPolicy {
        PreviewCacheCleanupPolicy(rawValue: previewCacheCleanupPolicyRaw) ?? .purgeOnLaunch
    }
    
    private var previewCacheSizeDescription: String {
        guard previewCacheSizeBytes > 0 else { return "Cache is empty" }
        return Self.byteCountFormatter.string(fromByteCount: previewCacheSizeBytes)
    }
    
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesUnit = true
        formatter.includesActualByteCount = false
        return formatter
    }()

    private func refreshPreviewCacheSize() async {
        let size = await PreviewAssetGenerator.shared.cacheDirectorySizeInBytes()
        await MainActor.run { previewCacheSizeBytes = size }
    }

    private func selectNewOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        
        if panel.runModal() == .OK, let url = panel.url {
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outputFolder = url.path
        }
    }

    private func selectScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: screenshotDirectoryPath)

        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            screenshotDirectoryPath = url.path
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }
    }

}

#Preview {
    GeneralSettingsView()
}
