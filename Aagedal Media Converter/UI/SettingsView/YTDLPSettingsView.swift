// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct YTDLPSettingsView: View {
    private struct BrowserOption: Hashable {
        let label: String
        let value: String
    }

    private let cookieBrowserOptions: [BrowserOption] = [
        .init(label: "Safari", value: "safari"),
        .init(label: "Chrome", value: "chrome"),
        .init(label: "Chromium", value: "chromium"),
        .init(label: "Edge", value: "edge"),
        .init(label: "Brave", value: "brave"),
        .init(label: "Firefox", value: "firefox"),
        .init(label: "Opera", value: "opera"),
        .init(label: "Vivaldi", value: "vivaldi"),
        .init(label: "Whale", value: "whale")
    ]
    @State private var ytdlpVersion: String?
    @State private var denoVersion: String?
    @State private var ffmpegVersion: String?
    @State private var isCheckingVersions = false
    @State private var ytdlpCustomPath: String = ""
    @State private var denoCustomPath: String = ""
    @State private var ffmpegCustomPath: String = ""
    @State private var ffmpegStateRefreshTask: Task<Void, Never>?
    @State private var ytdlpStatus: YTDLPStatus = .checking
    @State private var installationStatus: YTDLPInstallationStatus = .notInstalled
    @State private var isDownloading = false
    @State private var ytdlpDownloadProgress: Double = 0.0
    @State private var downloadError: String?
    @State private var downloadInfo: String?

    @State private var denoStatus: DenoStatus = .checking
    @State private var denoInstallationStatus: DenoInstallationStatus = .notInstalled
    @State private var isDownloadingDeno = false
    @State private var denoDownloadProgress: Double = 0.0
    @State private var denoDownloadError: String?
    @State private var denoDownloadInfo: String?

    @AppStorage(AppConstants.ytdlpBinarySourceKey) private var ytdlpBinarySource = BinarySourceSelection.app.rawValue
    @AppStorage(AppConstants.denoBinarySourceKey) private var denoBinarySource = BinarySourceSelection.app.rawValue
    @AppStorage(AppConstants.ffmpegBinarySourceKey) private var ffmpegBinarySource = BinarySourceSelection.app.rawValue
    @AppStorage(AppConstants.autoEncodeAfterDownloadKey) private var autoEncodeAfterDownload = false
    @AppStorage(AppConstants.autoUploadAfterDownloadKey) private var autoUploadAfterDownload = false
    @AppStorage(AppConstants.ytdlpCookiesBrowserKey) private var cookiesBrowser = ""
    @AppStorage(AppConstants.downloadFolderKey) private var downloadFolder = AppConstants.defaultDownloadDirectory.path
    @AppStorage(AppConstants.ytdlpFilenameRestrictionModeKey) private var filenameRestrictionRaw = AppConstants.defaultYTDLPFilenameRestrictionMode
    @AppStorage(AppConstants.allowPrivateNetworkDownloadsKey) private var allowPrivateNetworkDownloads = false

    var body: some View {
        Form {
            downloadDirectorySection
            ytdlpSection
            denoSection
            authenticationSection
            downloadAutomationSection
            ffmpegSection
            aboutSection
        }
        .formStyle(.grouped)
        .task {
            loadSettings()
            await refreshVersions()
        }
        .onChange(of: ytdlpBinarySource) { _, _ in
            downloadError = nil
            downloadInfo = nil
            Task { await refreshVersions() }
        }
        .onChange(of: denoBinarySource) { _, _ in
            denoDownloadError = nil
            denoDownloadInfo = nil
            Task { await refreshVersions() }
        }
        .onChange(of: ffmpegBinarySource) { _, _ in
            scheduleFFmpegStateRefresh()
        }
        .onDisappear {
            ffmpegStateRefreshTask?.cancel()
        }
    }

    // MARK: - yt-dlp Status

    private enum YTDLPStatus {
        case checking
        case configured
        case notAvailable
    }

    private enum DenoStatus {
        case checking
        case configured
        case notAvailable
    }

    private var selectedYTDLPSource: BinarySourceSelection {
        BinarySourceSelection(rawValue: ytdlpBinarySource) ?? .app
    }

    private var selectedDenoSource: BinarySourceSelection {
        BinarySourceSelection(rawValue: denoBinarySource) ?? .app
    }

    private var selectedFFmpegSource: BinarySourceSelection {
        BinarySourceSelection(rawValue: ffmpegBinarySource) ?? .app
    }

    private var ffmpegStatusLabel: String {
        switch selectedFFmpegSource {
        case .custom:
            return "FFmpeg: Custom"
        case .homebrew:
            return "FFmpeg: Homebrew"
        case .app:
            return "FFmpeg: App (Bundled)"
        }
    }

    private func statusColor(for selection: BinarySourceSelection) -> Color {
        switch selection {
        case .custom:
            return .blue
        case .homebrew, .app:
            return .green
        }
    }

    // MARK: - yt-dlp Section

    private var ytdlpSection: some View {
        Section(header: Text("yt-dlp (Video Downloads)")) {
            VStack(alignment: .leading, spacing: 12) {
                // Status
                HStack {
                    switch ytdlpStatus {
                    case .checking:
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Checking...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    case .configured:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(installationStatus.displayText)
                            .font(.headline)
                    case .notAvailable:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("yt-dlp not installed")
                            .font(.headline)
                    }

                    Spacer()

                    if let version = ytdlpVersion {
                        Text("v\(version)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if isCheckingVersions {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                HStack {
                    Text("Source:")
                        .frame(width: 60, alignment: .trailing)
                    Picker("Source", selection: $ytdlpBinarySource) {
                        Text("App Download").tag(BinarySourceSelection.app.rawValue)
                        Text("Homebrew").tag(BinarySourceSelection.homebrew.rawValue)
                        Text("Custom").tag(BinarySourceSelection.custom.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer()
                }

                // Download/Update buttons
                if !isDownloading {
                    HStack {
                        if selectedYTDLPSource == .app {
                            if ytdlpStatus == .notAvailable {
                                Button {
                                    downloadYTDLP()
                                } label: {
                                    Label("Download yt-dlp", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.borderedProminent)
                            } else if ytdlpStatus == .configured {
                                Button {
                                    checkAndUpdateYTDLP()
                                } label: {
                                    Label("Check for Updates", systemImage: "arrow.clockwise")
                                }
                            }
                        } else if ytdlpStatus == .notAvailable {
                            Text("Selected source not found.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView(value: ytdlpDownloadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 140)
                        Text("\(Int(ytdlpDownloadProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Downloading...")
                            .foregroundColor(.secondary)
                        Button {
                            Task { await YTDLPUpdateService.shared.cancelDownload(.ytdlp) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel download")
                    }
                }

                if let error = downloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else if let info = downloadInfo {
                    Text(info)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Show performance tip when using app-downloaded binary
                if selectedYTDLPSource == .app && ytdlpStatus == .configured {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "hare.fill")
                                .foregroundColor(.orange)
                            Text("The app-downloaded yt-dlp has slower startup (~20-30 seconds). For faster downloads, install via Homebrew.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        DisclosureGroup("Install Homebrew version for faster startup") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("1. Run this command in Terminal:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack {
                                    Text("brew install yt-dlp")
                                        .font(.system(.body, design: .monospaced))
                                        .padding(8)
                                        .background(Color(nsColor: .textBackgroundColor))
                                        .cornerRadius(6)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Copy to clipboard")
                                }

                                Text("2. After installing, select \"Homebrew\" above as the source.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Link("Don't have Homebrew? Install it first", destination: URL(string: "https://brew.sh")!)
                                    .font(.caption)
                            }
                            .padding(.top, 4)
                        }
                        .font(.callout)
                        .foregroundColor(.secondary)
                    }
                }

                if case .homebrewAvailable = installationStatus {
                    Text("Tip: You have Homebrew yt-dlp installed. Select \"Homebrew\" above for faster download startup.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if selectedYTDLPSource == .custom {
                    Divider()

                    // Custom path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom yt-dlp path:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Select yt-dlp binary", text: $ytdlpCustomPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Button("Browse...") {
                                selectBinary(for: .ytdlp)
                            }

                            if !ytdlpCustomPath.isEmpty {
                                Button(role: .destructive) {
                                    ytdlpCustomPath = ""
                                    saveYTDLPPath()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .onChange(of: ytdlpCustomPath) { _, _ in
                        saveYTDLPPath()
                    }
                }

                // Alternative install info (Homebrew) - shown when yt-dlp not installed
                if ytdlpStatus == .notAvailable && selectedYTDLPSource == .app {
                    Divider()

                    DisclosureGroup("Alternative: Install via Homebrew (Recommended)") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "hare.fill")
                                    .foregroundColor(.green)
                                Text("Homebrew yt-dlp starts downloads much faster than the app-downloaded version.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("1. Run this command in Terminal:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text("brew install yt-dlp")
                                    .font(.system(.body, design: .monospaced))
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }

                            Text("2. After installing, select \"Homebrew\" above as the source.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Link("Don't have Homebrew? Install it first", destination: URL(string: "https://brew.sh")!)
                                .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var denoSection: some View {
        Section(header: Text("deno (JavaScript Runtime)")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    switch denoStatus {
                    case .checking:
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Checking...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    case .configured:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(denoInstallationStatus.displayText)
                            .font(.headline)
                    case .notAvailable:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("deno not installed")
                            .font(.headline)
                    }

                    Spacer()

                    if let version = denoVersion {
                        Text("v\(version)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if isCheckingVersions {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                HStack {
                    Text("Source:")
                        .frame(width: 60, alignment: .trailing)
                    Picker("Source", selection: $denoBinarySource) {
                        Text("App Download").tag(BinarySourceSelection.app.rawValue)
                        Text("Homebrew").tag(BinarySourceSelection.homebrew.rawValue)
                        Text("Custom").tag(BinarySourceSelection.custom.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer()
                }

                if !isDownloadingDeno {
                    if selectedDenoSource == .app {
                        if denoStatus == .notAvailable {
                            Button {
                                downloadDeno()
                            } label: {
                                Label("Download deno", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            HStack {
                                Button {
                                    downloadDeno()
                                } label: {
                                    Label("Download deno", systemImage: "arrow.down.circle")
                                }
                                .help("Downloads a bundled copy and prefers it over the system runtime.")

                                Button {
                                    checkAndUpdateDeno()
                                } label: {
                                    Label("Check for Updates", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                    } else if denoStatus == .notAvailable {
                        Text("Selected source not found.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView(value: denoDownloadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 140)
                        Text("\(Int(denoDownloadProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Downloading...")
                            .foregroundColor(.secondary)
                        Button {
                            Task { await YTDLPUpdateService.shared.cancelDownload(.deno) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel download")
                    }
                }

                if let error = denoDownloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else if let info = denoDownloadInfo {
                    Text(info)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                if selectedDenoSource == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom deno path:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Select deno binary", text: $denoCustomPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Button("Browse...") {
                                selectBinary(for: .deno)
                            }

                            if !denoCustomPath.isEmpty {
                                Button(role: .destructive) {
                                    denoCustomPath = ""
                                    saveDenoPath()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .onChange(of: denoCustomPath) { _, _ in
                        saveDenoPath()
                    }
                }

                Text("deno provides the JavaScript runtime needed by yt-dlp to handle modern YouTube extraction challenges. It can be auto-downloaded on first use.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    // MARK: - Download Actions

    private func downloadYTDLP() {
        guard selectedYTDLPSource == .app else { return }
        runDownload(
            checkForUpdate: false,
            progressSetter: { ytdlpDownloadProgress = $0 },
            busySetter: { isDownloading = $0 },
            errorSetter: { downloadError = $0 },
            infoSetter: { downloadInfo = $0 },
            checkForUpdates: { await YTDLPUpdateService.shared.checkForUpdates() },
            download: { progress in
                try await YTDLPUpdateService.shared.downloadUpdate(progress: progress)
            }
        )
    }

    private func checkAndUpdateYTDLP() {
        guard selectedYTDLPSource == .app else { return }
        runDownload(
            checkForUpdate: true,
            progressSetter: { ytdlpDownloadProgress = $0 },
            busySetter: { isDownloading = $0 },
            errorSetter: { downloadError = $0 },
            infoSetter: { downloadInfo = $0 },
            checkForUpdates: { await YTDLPUpdateService.shared.checkForUpdates() },
            download: { progress in
                try await YTDLPUpdateService.shared.downloadUpdate(progress: progress)
            }
        )
    }

    private func downloadDeno() {
        guard selectedDenoSource == .app else { return }
        runDownload(
            checkForUpdate: false,
            progressSetter: { denoDownloadProgress = $0 },
            busySetter: { isDownloadingDeno = $0 },
            errorSetter: { denoDownloadError = $0 },
            infoSetter: { denoDownloadInfo = $0 },
            checkForUpdates: { await YTDLPUpdateService.shared.checkForDenoUpdates() },
            download: { progress in
                try await YTDLPUpdateService.shared.downloadDenoUpdate(progress: progress)
            }
        )
    }

    private func checkAndUpdateDeno() {
        guard selectedDenoSource == .app else { return }
        runDownload(
            checkForUpdate: true,
            progressSetter: { denoDownloadProgress = $0 },
            busySetter: { isDownloadingDeno = $0 },
            errorSetter: { denoDownloadError = $0 },
            infoSetter: { denoDownloadInfo = $0 },
            checkForUpdates: { await YTDLPUpdateService.shared.checkForDenoUpdates() },
            download: { progress in
                try await YTDLPUpdateService.shared.downloadDenoUpdate(progress: progress)
            }
        )
    }

    private func runDownload(
        checkForUpdate: Bool,
        progressSetter: @MainActor @escaping (Double) -> Void,
        busySetter: @MainActor @escaping (Bool) -> Void,
        errorSetter: @MainActor @escaping (String?) -> Void,
        infoSetter: @MainActor @escaping (String?) -> Void,
        checkForUpdates: @Sendable @escaping () async -> Bool,
        download: @Sendable @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        busySetter(true)
        progressSetter(0.0)
        errorSetter(nil)
        infoSetter(nil)
        Task {
            do {
                let shouldDownload = checkForUpdate ? await checkForUpdates() : true
                if shouldDownload {
                    try await download { progress in
                        Task { @MainActor in progressSetter(progress) }
                    }
                } else {
                    await MainActor.run { infoSetter("Already up to date") }
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run { infoSetter(nil) }
                }
                await refreshVersions()
            } catch is CancellationError {
                // User cancelled — leave UI silent.
            } catch {
                await MainActor.run { errorSetter(error.localizedDescription) }
            }
            await MainActor.run { busySetter(false) }
        }
    }

    // MARK: - Authentication Section

    private var authenticationSection: some View {
        Section(header: Text("Authentication")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use browser cookies to access age-restricted, private, or member-only content.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Browser:")
                        .frame(width: 60, alignment: .trailing)

                    Picker("", selection: $cookiesBrowser) {
                        Text("None").tag("")
                        Divider()
                        ForEach(cookieBrowserOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                if !cookiesBrowser.isEmpty {
                    let friendlyBrowserName = browserLabel(for: cookiesBrowser)
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("yt-dlp will extract cookies from \(friendlyBrowserName) when downloading.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Note: The browser should be closed for best results. On macOS, you may need to grant Full Disk Access to the app in System Settings > Privacy & Security.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Download Automation Section

    private var downloadAutomationSection: some View {
        Section(header: Text("Download Automation")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Auto-encode after download", isOn: $autoEncodeAfterDownload)
                    .toggleStyle(SwitchToggleStyle())

                Text("When enabled, new downloads will automatically start encoding after the download completes.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Toggle("Auto-upload after download", isOn: $autoUploadAfterDownload)
                    .toggleStyle(SwitchToggleStyle())
                    .disabled(!UploadManager.shared.isConfigured)

                Text("When enabled, new downloads will be uploaded after encoding completes. Requires upload to be configured in Settings > Upload.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !UploadManager.shared.isConfigured {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Upload not configured")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(8)
        }
    }

    private var downloadDirectorySection: some View {
        Section(header: Text("Download Folder")) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Folder:")
                        .font(.headline)

                    HStack {
                        Text(downloadFolder)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(downloadFolder)

                        Button(action: {
                            let url = URL(fileURLWithPath: downloadFolder)
                            guard FileManager.default.fileExists(atPath: url.path) else {
                                downloadFolder = AppConstants.defaultDownloadDirectory.path
                                NSWorkspace.shared.activateFileViewerSelecting([AppConstants.defaultDownloadDirectory])
                                return
                            }
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Show in Finder")

                        Button(action: { chooseDownloadFolder() }) {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Change download folder")

                        Button(action: { downloadFolder = AppConstants.defaultDownloadDirectory.path }) {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Reset to default")
                    }
                }

                Text("Downloads from yt-dlp are saved here before conversion.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text("Filename restrictions:")
                    Picker("", selection: filenameRestrictionMode) {
                        ForEach(YTDLPFilenameRestrictionMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.displayName)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    Spacer()
                }

                Text(filenameRestrictionExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Allow private network downloads", isOn: $allowPrivateNetworkDownloads)
                    .toggleStyle(SwitchToggleStyle())

                Text("Off by default. When off, URLs pointing to LAN, loopback, link-local, or `.local` hosts are rejected. Turn on to download from a local media server (Jellyfin, Plex, etc.).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var filenameRestrictionMode: Binding<YTDLPFilenameRestrictionMode> {
        Binding(
            get: { YTDLPFilenameRestrictionMode(rawValue: filenameRestrictionRaw) ?? .off },
            set: { filenameRestrictionRaw = $0.rawValue }
        )
    }

    private var filenameRestrictionExplanation: LocalizedStringKey {
        switch YTDLPFilenameRestrictionMode(rawValue: filenameRestrictionRaw) ?? .off {
        case .off:
            return "yt-dlp only strips characters illegal on macOS (just '/' and NUL). Filenames may still break on Windows or NTFS drives."
        case .windowsSafe:
            return "Strips characters Windows rejects (< > : \" / \\ | ? *) and trailing space/period. Unicode letters, including æ, ø, å, and CJK scripts, are preserved."
        case .asciiOnly:
            return "Keeps only ASCII letters, digits, underscore, hyphen, and period. Non-Latin scripts and many accented letters are dropped (e.g. ø → empty, é → e)."
        }
    }

    // MARK: - FFmpeg Section

    private var ffmpegSection: some View {
        Section(header: Text("FFmpeg (Conversion)")) {
            VStack(alignment: .leading, spacing: 12) {
                // FFmpeg status
                HStack {
                    if BinaryPathResolver.ffmpegPath != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(statusColor(for: selectedFFmpegSource))
                        Text(ffmpegStatusLabel)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("FFmpeg: Not found")
                    }

                    Spacer()

                    if let version = ffmpegVersion {
                        Text(version)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                HStack {
                    Text("Source:")
                        .frame(width: 60, alignment: .trailing)
                    Picker("Source", selection: $ffmpegBinarySource) {
                        Text("App (Bundled)").tag(BinarySourceSelection.app.rawValue)
                        Text("Homebrew").tag(BinarySourceSelection.homebrew.rawValue)
                        Text("Custom").tag(BinarySourceSelection.custom.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer()
                }

                if selectedFFmpegSource == .custom {
                    // Custom FFmpeg path
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom FFmpeg path:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Select ffmpeg binary", text: $ffmpegCustomPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Button("Browse...") {
                                selectBinary(for: .ffmpeg)
                            }

                            if !ffmpegCustomPath.isEmpty {
                                Button(role: .destructive) {
                                    ffmpegCustomPath = ""
                                    saveFFmpegPath()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .onChange(of: ffmpegCustomPath) { _, _ in
                        saveFFmpegPath()
                    }

                }

                Divider()

                Button("Refresh Versions") {
                    scheduleFFmpegStateRefresh()
                }
                .disabled(isCheckingVersions)
            }
            .padding(8)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section(header: Text("About")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The app includes a bundled ffmpeg binary. You can optionally point at a Homebrew or custom ffmpeg if you need specific features or codecs. Metadata reading (including chapters) is handled in-process by SwiftMediaMetadata — no external ffprobe is required.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("yt-dlp enables downloading videos from YouTube and other sites. It can be auto-downloaded from GitHub or installed via Homebrew. Downloaded videos are automatically queued for conversion.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Link("FFmpeg", destination: URL(string: "https://ffmpeg.org")!)
                    Spacer()
                    Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                    Spacer()
                    Link("Homebrew", destination: URL(string: "https://brew.sh")!)
                }
                .font(.callout)
            }
            .padding(8)
        }
    }

    // MARK: - Binary Type

    private enum BinaryType {
        case ytdlp, deno, ffmpeg

        var title: String {
            switch self {
            case .ytdlp: return "Select yt-dlp binary"
            case .deno: return "Select deno binary"
            case .ffmpeg: return "Select ffmpeg binary"
            }
        }

        var message: String {
            switch self {
            case .ytdlp: return "Select yt-dlp from /opt/homebrew/bin/"
            case .deno: return "Select deno from /opt/homebrew/bin/"
            case .ffmpeg: return "Select ffmpeg binary"
            }
        }

        var defaultDirectory: URL? {
            // For yt-dlp, prefer /opt/homebrew/bin where the symlink is
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
                return URL(fileURLWithPath: "/opt/homebrew/bin")
            }
            return nil
        }
    }

    // MARK: - Actions

    private func loadSettings() {
        seedBinarySourcesIfNeeded()
        ytdlpCustomPath = YTDLPUpdateService.shared.getCustomPath() ?? ""
        denoCustomPath = YTDLPUpdateService.shared.getDenoCustomPath() ?? ""
        ffmpegCustomPath = UserDefaults.standard.string(forKey: AppConstants.customFFmpegPathKey) ?? ""
    }

    private func saveYTDLPPath() {
        Task {
            if ytdlpCustomPath.isEmpty {
                await YTDLPUpdateService.shared.clearCustomPath()
            } else {
                await YTDLPUpdateService.shared.saveCustomPath(ytdlpCustomPath)
            }
            await refreshVersions()
        }
    }

    private func saveDenoPath() {
        Task {
            if denoCustomPath.isEmpty {
                await YTDLPUpdateService.shared.clearDenoCustomPath()
            } else {
                await YTDLPUpdateService.shared.saveDenoCustomPath(denoCustomPath)
            }
            await refreshVersions()
        }
    }

    private func saveFFmpegPath() {
        BinaryPathResolver.saveCustomFFmpegPath(ffmpegCustomPath.isEmpty ? nil : ffmpegCustomPath)
        scheduleFFmpegStateRefresh(after: .milliseconds(300))
    }

    private func scheduleFFmpegStateRefresh(after delay: Duration? = nil) {
        ffmpegStateRefreshTask?.cancel()
        ffmpegStateRefreshTask = Task {
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await refreshFFmpegState()
        }
    }

    private func refreshFFmpegState() async {
        async let versions: Void = refreshVersions()
        async let capability = try? WhisperUpdateService.shared.refreshCapabilitySnapshot()
        _ = await (versions, capability)
    }

    private func seedBinarySourcesIfNeeded() {
        if !hasStoredValue(for: AppConstants.ytdlpBinarySourceKey) {
            ytdlpBinarySource = defaultYTDLPSourceSelection().rawValue
        }
        if !hasStoredValue(for: AppConstants.denoBinarySourceKey) {
            denoBinarySource = defaultDenoSourceSelection().rawValue
        }
        if !hasStoredValue(for: AppConstants.ffmpegBinarySourceKey) {
            ffmpegBinarySource = defaultFFmpegSourceSelection().rawValue
        }
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        panel.directoryURL = URL(fileURLWithPath: downloadFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Persist a writable bookmark so the folder survives across launches.
        _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)
        downloadFolder = url.path
    }

    private func defaultYTDLPSourceSelection() -> BinarySourceSelection {
        if let customPath = YTDLPUpdateService.shared.getCustomPath(),
           fileExists(at: customPath) {
            return .custom
        }
        if fileExists(at: "/opt/homebrew/bin/yt-dlp") {
            return .homebrew
        }
        if fileExists(at: AppConstants.ytdlpToolsDirectory.appendingPathComponent("yt-dlp").path) {
            return .app
        }
        return .app
    }

    private func defaultDenoSourceSelection() -> BinarySourceSelection {
        if let customPath = YTDLPUpdateService.shared.getDenoCustomPath(),
           fileExists(at: customPath) {
            return .custom
        }
        if fileExists(at: AppConstants.ytdlpToolsDirectory.appendingPathComponent("deno").path) {
            return .app
        }
        if fileExists(at: "/opt/homebrew/bin/deno") || fileExists(at: "/usr/bin/deno") {
            return .homebrew
        }
        return .app
    }

    private func defaultFFmpegSourceSelection() -> BinarySourceSelection {
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.customFFmpegPathKey),
           fileExists(at: customPath) {
            return .custom
        }
        return .app
    }

    private func hasStoredValue(for key: String) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) else { return false }
        if let stringValue = value as? String {
            return !stringValue.isEmpty
        }
        return true
    }

    private func fileExists(at path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: trimmed)
    }

    private func browserLabel(for value: String) -> String {
        cookieBrowserOptions.first { $0.value == value }?.label ?? value.capitalized
    }

    private func selectBinary(for type: BinaryType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = type.title
        panel.message = type.message
        panel.prompt = "Select"
        panel.allowedContentTypes = [.unixExecutable, .exe, .item]
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = false
        panel.resolvesAliases = false  // Keep symlinks as-is, don't resolve to actual path

        if let defaultDir = type.defaultDirectory {
            panel.directoryURL = defaultDir
        }

        if panel.runModal() == .OK, let url = panel.url {
            switch type {
            case .ytdlp:
                ytdlpCustomPath = url.path
            case .deno:
                denoCustomPath = url.path
            case .ffmpeg:
                ffmpegCustomPath = url.path
            }
        }
    }

    private func refreshVersions() async {
        await MainActor.run {
            isCheckingVersions = true
            ytdlpStatus = .checking
            denoStatus = .checking
        }

        // Check yt-dlp status and installation status
        let resolvedPath = await YTDLPUpdateService.shared.resolveYTDLPPath()
        let status: YTDLPStatus = resolvedPath != nil ? .configured : .notAvailable
        let instStatus = await YTDLPUpdateService.shared.getInstallationStatus()
        let resolvedDenoPath = await YTDLPUpdateService.shared.resolveDenoPath()
        let denoInstStatus = await YTDLPUpdateService.shared.getDenoInstallationStatus()
        let denoStatusValue: DenoStatus = resolvedDenoPath != nil ? .configured : .notAvailable

        async let ytdlpVer = YTDLPUpdateService.shared.getCurrentVersion()
        async let denoVer = YTDLPUpdateService.shared.getCurrentDenoVersion()
        async let ffmpegVer = BinaryPathResolver.getFFmpegVersion()

        let (yt, deno, ff) = await (ytdlpVer, denoVer, ffmpegVer)

        await MainActor.run {
            ytdlpVersion = yt
            denoVersion = deno
            ffmpegVersion = ff
            ytdlpStatus = status
            installationStatus = instStatus
            denoStatus = denoStatusValue
            denoInstallationStatus = denoInstStatus
            isCheckingVersions = false
        }
    }
}

#Preview {
    YTDLPSettingsView()
}
