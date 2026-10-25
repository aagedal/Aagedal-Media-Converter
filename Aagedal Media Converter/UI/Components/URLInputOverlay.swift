// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import OSLog
import SwiftUI

/// Overlay for entering a URL to download via yt-dlp
struct URLInputOverlay: View {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "URLInput")

    @Binding var isPresented: Bool
    var onSubmit: (String, Bool, Bool, DownloadSection?) -> Void
    var onSchedule: ((String, Date, Bool, Bool, DownloadSection?) -> Void)?
    /// Receives the playlist entries the user picked, plus the audio-only flag.
    var onSubmitPlaylist: (([YTDLPPlaylistEntry], Bool) -> Void)?

    @State private var urlText = ""
    @State private var postVideos: [PostDownloadVideo] = []
    @State private var selectedPostVideos: Set<Int> = []
    @State private var postLoadedURL: String?
    @State private var postIsLoading = false
    @State private var postError: String?
    @State private var postRetry = 0
    private let postService = YTDLPService()

    private var sanitizedURL: String { DownloadManager.sanitizeURLInput(urlText) }

    private var needsPostPicker: Bool {
        (InstagramCarouselSelection.isPostURL(sanitizedURL)
            && URLComponents(string: sanitizedURL)?.queryItems?.contains { $0.name == "img_index" } != true)
            || TwitterPostSelection.needsPicker(sanitizedURL)
    }

    /// Posts and playlists share one video picker.
    private var needsPicker: Bool { needsPostPicker || isPlaylistContext }

    private var downloadDisabled: Bool {
        !DownloadManager.isValidURL(sanitizedURL)
            || (needsPicker && (postLoadedURL != sanitizedURL || selectedPostVideos.isEmpty))
            || clipError != nil
    }

    // Clip (section) download state. Per-download, so not persisted.
    @State private var isClipEnabled = false
    @State private var clipStartText = ""
    @State private var clipEndText = ""
    /// Source duration and preview stream probed in the background so the clip
    /// can be picked in a player and kept within the video. Keyed by URL so
    /// typing a new URL never shows the previous video.
    @State private var clipDurationURL: String?
    @State private var clipSourceDuration: Double?
    @State private var clipPreviewStreams: [YTDLPPreviewStream] = []
    @State private var clipProbeEngine: YTDLPEngine?
    @State private var clipDurationIsLoading = false
    /// Space available to the overlay, so the clip player fits the window.
    @State private var overlaySize = CGSize(width: 1200, height: 900)
    private var overlayHeight: CGFloat { overlaySize.height }

    /// Panel height without the clip video, history included.
    private static let clipPanelChromeHeight: CGFloat = 560
    private static let panelWidth: CGFloat = 620
    private static let panelPadding: CGFloat = 20
    private var isPickingClip: Bool { isClipActive && knownClipDuration != nil }
    /// The panel widens with the window while a clip is picked, so the
    /// preview isn't left tiny in a large window.
    private var currentPanelWidth: CGFloat {
        guard isPickingClip else { return Self.panelWidth }
        return min(1200, max(Self.panelWidth, overlaySize.width - 80))
    }
    private var clipVideoHeight: CGFloat {
        let fitsWidth = (currentPanelWidth - 2 * Self.panelPadding) * 9 / 16
        return min(fitsWidth, max(140, overlayHeight - Self.clipPanelChromeHeight))
    }
    /// Short windows drop the history list while a clip is picked.
    private var showsHistory: Bool {
        !(isPickingClip && overlayHeight < Self.clipPanelChromeHeight + 300)
    }

    /// Section downloads usually stream through ffmpeg at roughly 2× playback
    /// speed, while full downloads use fast ranged requests. Below this length
    /// the full download usually wins, as it does for clips covering most of
    /// the video, so the clip row says so.
    private static let shortVideoClipHintThreshold: Double = 600
    /// Clips covering more than this share of the video also download faster whole.
    private static let largeClipShareHintThreshold: Double = 0.5

    /// yt-dlp-rs fetches only the segments a YouTube section needs, so clips
    /// there are fast. Audio-only downloads go to yt-dlp without ffprobe.
    private var hasFastSectionDownload: Bool {
        clipProbeEngine == .ytdlpRS && !downloadAudioOnly
            && YTDLPEngineRouter.site(for: sanitizedURL)?.id == "youtube"
    }

    /// Whether the current clip would likely finish sooner as a full download.
    private var isWholeDownloadLikelyFaster: Bool {
        guard !hasFastSectionDownload else { return false }
        guard let duration = knownClipDuration, let section = clipSection else { return false }
        if duration < Self.shortVideoClipHintThreshold { return true }
        let clipLength = min(section.end ?? duration, duration) - section.start
        return clipLength > duration * Self.largeClipShareHintThreshold
    }

    /// Duration of the current URL's video, once known.
    private var knownClipDuration: Double? {
        guard clipDurationURL == sanitizedURL, let clipSourceDuration, clipSourceDuration > 0 else { return nil }
        return clipSourceDuration
    }

    /// Section downloads target one finite video: not playlists, multi-video posts,
    /// or live recordings rewound from the start.
    private var isClipAvailable: Bool {
        !isPlaylistContext && !needsPostPicker && !downloadLiveFromStart
    }

    private var clipUnavailableReason: String? {
        if isPlaylistContext { return "Clips aren't available for playlist downloads" }
        if needsPostPicker { return "Clips aren't available for multi-video posts" }
        if downloadLiveFromStart { return "Clips aren't available with Record from start" }
        return nil
    }

    private var isClipActive: Bool { isClipEnabled && isClipAvailable }

    /// Parsed clip range, or an error message describing why the fields are invalid.
    private var clipParseResult: Result<DownloadSection, ClipInputError>? {
        guard isClipActive else { return nil }
        let startText = clipStartText.trimmingCharacters(in: .whitespaces)
        let endText = clipEndText.trimmingCharacters(in: .whitespaces)
        let start: Double
        if startText.isEmpty {
            start = 0
        } else if let parsed = DownloadSection.parseTime(startText) {
            start = parsed
        } else {
            return .failure(ClipInputError("Start time isn't valid — use e.g. 1:30 or 1:02:03"))
        }
        var end: Double?
        if !endText.isEmpty {
            guard let parsed = DownloadSection.parseTime(endText) else {
                return .failure(ClipInputError("End time isn't valid — use e.g. 4:10 or 1:02:03"))
            }
            end = parsed
        }
        if let end, end <= start {
            return .failure(ClipInputError("End time must be after start time"))
        }
        if let duration = knownClipDuration {
            let length = DownloadSection.formatTime(duration)
            if start >= duration {
                return .failure(ClipInputError("Start time is after the end of the video (\(length))"))
            }
            if let end, end > duration + 0.5 {
                return .failure(ClipInputError("End time is after the end of the video (\(length))"))
            }
        }
        guard let section = DownloadSection(start: start, end: end) else {
            return .failure(ClipInputError("Set a start or end time"))
        }
        return .success(section)
    }

    private var clipSection: DownloadSection? {
        if case .success(let section)? = clipParseResult { return section }
        return nil
    }

    private var clipError: String? {
        if case .failure(let error)? = clipParseResult { return error.message }
        return nil
    }

    private struct ClipInputError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
    @State private var history: [DownloadHistoryEntry] = []
    @State private var hasUnreadableHistory = false
    @State private var showHistoryResetConfirmation = false
    @State private var isScheduled = false
    @State private var scheduledDate = Self.defaultScheduleDate()
    @FocusState private var isTextFieldFocused: Bool
    @AppStorage(AppConstants.ytdlpLiveFromStartKey) private var downloadLiveFromStart = false
    @AppStorage(AppConstants.ytdlpAudioOnlyKey) private var downloadAudioOnly = false
    @AppStorage(AppConstants.ytdlpDownloadPlaylistKey) private var downloadWholePlaylist = false
    @AppStorage(AppConstants.autoEncodeAfterDownloadKey) private var autoEncodeAfterDownload = false
    @AppStorage(AppConstants.autoUploadAfterDownloadKey) private var autoUploadAfterDownload = false

    // History navigation state (like terminal history)
    @State private var historyIndex: Int = -1  // -1 means not navigating history
    @State private var originalText: String = ""  // Text before starting history navigation

    // Clipboard indicator
    @State private var showClipboardIndicator = false

    /// Returns a default schedule date: 2 minutes from now, rounded to the next full minute
    private static func defaultScheduleDate() -> Date {
        let now = Date()
        let calendar = Calendar.current
        // Get the start of the current minute, then add 2 minutes
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let startOfMinute = calendar.date(from: components) ?? now
        return startOfMinute.addingTimeInterval(120) // 2 minutes from start of current minute
    }

    private var minimumScheduleDate: Date {
        // Round up to the next full minute
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let startOfMinute = calendar.date(from: components) ?? now
        return startOfMinute.addingTimeInterval(60) // Next full minute
    }

    /// True when the current URL looks like a playlist/channel and the playlist
    /// toggle is on. Used both to enable playlist behaviour at submit time and
    /// to disable the schedule UI (which doesn't compose with playlist).
    private var isPlaylistContext: Bool {
        downloadWholePlaylist && Self.looksLikePlaylistURL(sanitizedURL)
    }

    /// Heuristic: does this URL refer to a playlist, channel, or other multi-video
    /// resource yt-dlp would expand under `--flat-playlist`? Conservative on purpose
    /// — false negatives just hide the toggle (annoying), false positives let the
    /// user kick off a playlist download against a single video (confusing).
    private static func looksLikePlaylistURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        // YouTube — any `list=` query param means we're inside a playlist context,
        // even when the URL also names a specific video. Channel URLs and explicit
        // /playlist paths also count.
        if host.contains("youtube.com") || host == "youtu.be" {
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               comps.queryItems?.contains(where: { $0.name == "list" }) == true {
                return true
            }
            if path.hasPrefix("/playlist") || path.hasPrefix("/channel/") ||
               path.hasPrefix("/c/") || path.hasPrefix("/user/") || path.hasPrefix("/@") {
                return true
            }
        }

        if host.contains("vimeo.com") {
            if path.contains("/album/") || path.contains("/channels/") || path.contains("/showcase/") {
                return true
            }
        }

        if host.contains("soundcloud.com") && path.contains("/sets/") {
            return true
        }

        return false
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // Input panel
            inputPanel
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { overlaySize = $0 }
        .task(id: "\(sanitizedURL)|\(isPlaylistContext)|\(postRetry)") {
            await loadPostVideos()
        }
        .task(id: "\(sanitizedURL)|\(isClipAvailable)") {
            await loadClipDuration()
        }
        .onAppear {
            // Pre-warm yt-dlp binary in background (helps with PyInstaller startup)
            YTDLPUpdateService.shared.warmUp()

            // Load history
            history = DownloadHistoryService.getHistory()
            hasUnreadableHistory = DownloadHistoryService.hasUnreadableHistory()

            // Check clipboard for URL (sanitize to first line only)
            if let clipboardString = NSPasteboard.general.string(forType: .string) {
                let sanitized = DownloadManager.sanitizeURLInput(clipboardString)
                if DownloadManager.isValidURL(sanitized) {
                    urlText = sanitized
                    // Show clipboard indicator after layout settles
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showClipboardIndicator = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                showClipboardIndicator = false
                            }
                        }
                    }
                }
            }

            // Auto-focus the text field (with slight delay for SwiftUI to finish layout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }

    // MARK: - Extracted Subviews

    private var inputPanel: some View {
        VStack(spacing: 16) {
            headerSection
            urlInputSection
            clipboardIndicator
            invalidURLWarning
            clipSectionRow
            postPicker
            actionSection
            automationToggles
            if showsHistory {
                historySection
            }
        }
        .padding(Self.panelPadding)
        .frame(width: currentPanelWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onChange(of: downloadWholePlaylist) { _, isOn in
            // Schedule + whole-playlist isn't supported yet; turning the playlist
            // toggle on auto-clears the schedule checkbox so the UI matches submit()'s
            // routing (playlist always submits immediately).
            if isOn { isScheduled = false }
        }
    }

    private var headerSection: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Download from URL")
                .font(.headline)

            Spacer()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var urlInputSection: some View {
        TextField("Paste video URL (YouTube, Vimeo, etc.)...", text: $urlText)
            .accessibilityIdentifier("downloadURLField")
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($isTextFieldFocused)
            .onSubmit {
                submit()
            }
            .onKeyPress(.downArrow) {
                // Down arrow goes into history (visually downward into the list)
                navigateHistoryForward()
                return .handled
            }
            .onKeyPress(.upArrow) {
                // Up arrow goes back toward original text (visually upward)
                navigateHistoryBackward()
                return .handled
            }
            .onChange(of: urlText) { oldValue, newValue in
                // Reset history navigation when user types manually
                // (but not when we're programmatically setting from history)
                if historyIndex >= 0 && !history.isEmpty && historyIndex < history.count && newValue != history[historyIndex].url {
                    historyIndex = -1
                }
                // If switching to a playlist URL with playlist toggle already on,
                // clear the schedule checkbox so the disabled state matches the
                // value (otherwise Schedule reads as disabled-but-checked).
                if downloadWholePlaylist && Self.looksLikePlaylistURL(newValue) {
                    isScheduled = false
                }
            }
    }

    @ViewBuilder
    private var clipboardIndicator: some View {
        if showClipboardIndicator {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.caption)
                Text("Pasted from clipboard")
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var invalidURLWarning: some View {
        if !urlText.isEmpty && !DownloadManager.isValidURL(urlText) {
            HStack {
                Label("Invalid URL", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
            }
        }
    }

    private var clipSectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $isClipEnabled) {
                    Label("Clip", systemImage: "scissors")
                        .font(.subheadline)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("downloadClipToggle")
                .help(clipUnavailableReason ?? "Download only part of the video")

                clipTimeField("Start", text: $clipStartText, placeholder: "0:00", identifier: "downloadClipStartField")
                Text("–")
                    .foregroundStyle(.secondary)
                clipTimeField("End", text: $clipEndText, placeholder: "end", identifier: "downloadClipEndField")

                if let section = clipSection {
                    Text(clipDurationText(section))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .disabled(!isClipAvailable)
            .opacity(isClipAvailable ? 1.0 : 0.5)

            if isClipActive {
                clipPicker
                if let clipError {
                    Label(clipError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Downloads \(Int(DownloadSection.padding)) s extra on each side; the exact in and out points are set as trim points in the queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isWholeDownloadLikelyFaster {
                        Label("Clips download at about twice playback speed. For videos under 10 minutes, or clips longer than half the video, downloading the whole video and trimming it in the queue is likely faster.", systemImage: "hare")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func clipTimeField(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String, identifier: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)
                .accessibilityIdentifier(identifier)
                .onSubmit { submit() }
                .onChange(of: text.wrappedValue) { _, newValue in
                    // Typing a time implies the user wants a clip.
                    if !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                        isClipEnabled = true
                    }
                }
        }
    }

    /// Player and timeline over the probed video. The time fields stay the
    /// source of truth; the picker reads and writes them.
    @ViewBuilder
    private var clipPicker: some View {
        if let duration = knownClipDuration {
            ClipPreviewView(
                streams: clipPreviewStreams,
                duration: duration,
                inPoint: Binding(
                    get: { DownloadSection.parseTime(clipStartText).flatMap { $0 > 0 ? min($0, duration) : nil } },
                    set: { clipStartText = $0.map(DownloadSection.formatTime) ?? "" }
                ),
                outPoint: Binding(
                    get: { DownloadSection.parseTime(clipEndText).flatMap { $0 < duration ? $0 : nil } },
                    // The end of the video is the same as no end time.
                    set: { clipEndText = $0.map(DownloadSection.formatTime) ?? "" }
                ),
                videoHeight: clipVideoHeight,
                onReleaseTextFocus: { isTextFieldFocused = false }
            )
            // mpv stays bound to its first view; each video gets a fresh player.
            .id(clipDurationURL)
        } else if clipDurationIsLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading video…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Probes the video's length and preview stream for the clip picker. Runs for single-video URLs
    /// that allow clips, debounced like the post picker, and only once per URL.
    @MainActor
    private func loadClipDuration() async {
        let url = sanitizedURL
        guard isClipAvailable, DownloadManager.isValidURL(url) else {
            clipDurationIsLoading = false
            return
        }
        guard clipDurationURL != url else { return }
        clipDurationIsLoading = true
        do {
            try await Task.sleep(for: .milliseconds(400))
            let metadata = try await postService.fetchMetadata(url: url)
            try Task.checkCancellation()
            guard sanitizedURL == url else { return }
            // Times typed for another video don't carry over; ones typed
            // for this video stay unless they fall outside it.
            if clipDurationURL != nil {
                clipStartText = ""
                clipEndText = ""
            } else if let duration = metadata.duration {
                if DownloadSection.parseTime(clipStartText).map({ $0 >= duration }) == true { clipStartText = "" }
                if DownloadSection.parseTime(clipEndText).map({ $0 > duration }) == true { clipEndText = "" }
            }
            clipDurationURL = url
            clipSourceDuration = metadata.duration
            clipPreviewStreams = metadata.previewStreams
            clipProbeEngine = metadata.engine
        } catch is CancellationError {
            return
        } catch {
            // Live streams and failed probes just keep the time fields.
            guard !Task.isCancelled, sanitizedURL == url else { return }
            clipDurationURL = url
            clipSourceDuration = nil
            clipPreviewStreams = []
            clipProbeEngine = nil
        }
        clipDurationIsLoading = false
    }

    private func clipDurationText(_ section: DownloadSection) -> String {
        guard let end = section.end else { return "from \(DownloadSection.formatTime(section.start)) to end" }
        return "(\(DownloadSection.formatTime(end - section.start)))"
    }

    private var downloadButtonTitle: String {
        guard needsPicker else { return "Download" }
        if !selectablePostVideoIndices.isEmpty && selectedPostVideos == selectablePostVideoIndices {
            return "Download All (\(selectedPostVideos.count))"
        }
        return "Download Selected (\(selectedPostVideos.count))"
    }

    @ViewBuilder
    private var postPicker: some View {
        if needsPicker {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(isPlaylistContext ? "Choose videos from this playlist" : "Choose videos from this post")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !postVideos.isEmpty {
                        Toggle("Download all (\(selectablePostVideoIndices.count))", isOn: Binding(
                            get: { !selectablePostVideoIndices.isEmpty && selectedPostVideos == selectablePostVideoIndices },
                            set: { selectedPostVideos = $0 ? selectablePostVideoIndices : [] }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(selectablePostVideoIndices.isEmpty)
                        .accessibilityIdentifier("postVideoSelectAll")
                    }
                }
                if postIsLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(isPlaylistContext ? "Loading playlist…" : "Finding videos…").foregroundStyle(.secondary)
                    }
                } else if let postError {
                    Text(postError).font(.caption).foregroundStyle(.orange)
                    Button("Retry") { postRetry += 1 }
                } else if postLoadedURL == sanitizedURL {
                    if postVideos.isEmpty {
                        Text(isPlaylistContext ? "This playlist contains no videos." : "This post contains no downloadable videos.")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            // Lazy only for playlists: channels can have thousands of
                            // entries, while posts are small and keep every row live.
                            if isPlaylistContext {
                                LazyVStack(spacing: 6) {
                                    ForEach(postVideos) { video in
                                        postVideoRow(video)
                                    }
                                }
                            } else {
                                VStack(spacing: 6) {
                                    ForEach(postVideos) { video in
                                        postVideoRow(video)
                                    }
                                }
                            }
                        }
                        .frame(height: min(CGFloat(postVideos.count) * 66, 240))
                        Text(isPlaylistContext
                             ? "Downloads run one after another, each as its own queue item."
                             : "Photo slides are omitted. Choose one or more videos.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func postVideoRow(_ video: PostDownloadVideo) -> some View {
        Toggle(isOn: Binding(
            get: { video.isAvailable && selectedPostVideos.contains(video.slideIndex) },
            set: { selected in
                if selected, video.isAvailable { selectedPostVideos.insert(video.slideIndex) }
                else { selectedPostVideos.remove(video.slideIndex) }
            }
        )) {
            HStack(spacing: 10) {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "video.fill").foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 48)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    if isPlaylistContext {
                        Text(video.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(playlistRowDetail(video)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text(TwitterPostSelection.isPostURL(sanitizedURL) ? "Video \(video.slideIndex)" : "Slide \(video.slideIndex)").font(.callout.weight(.medium))
                        Text(video.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!video.isAvailable)
        .opacity(video.isAvailable ? 1 : 0.55)
        .padding(6)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .help(video.unavailability.map(Self.unavailabilityDescription) ?? "")
        .accessibilityIdentifier(postVideoIdentifier(video))
    }

    private func postVideoIdentifier(_ video: PostDownloadVideo) -> String {
        if isPlaylistContext { return "playlistVideo\(video.slideIndex)" }
        return TwitterPostSelection.isPostURL(sanitizedURL) ? "twitterVideo\(video.slideIndex)" : "instagramSlide\(video.slideIndex)"
    }

    private func playlistRowDetail(_ video: PostDownloadVideo) -> String {
        if let unavailability = video.unavailability {
            return "#\(video.slideIndex) · \(Self.unavailabilityDescription(unavailability))"
        }
        guard let duration = video.duration, duration > 0 else { return "#\(video.slideIndex)" }
        return "#\(video.slideIndex) · \(DownloadSection.formatTime(duration.rounded()))"
    }

    /// Videos that can be picked; unavailable playlist entries are shown but never selectable.
    private var selectablePostVideoIndices: Set<Int> {
        Set(postVideos.filter(\.isAvailable).map(\.slideIndex))
    }

    private static func unavailabilityDescription(_ reason: YTDLPPlaylistEntry.Unavailability) -> String {
        switch reason {
        case .privateVideo:
            return String(localized: "Unavailable: private video", comment: "Playlist picker reason a video can't be downloaded.")
        case .deleted:
            return String(localized: "Unavailable: deleted video", comment: "Playlist picker reason a video can't be downloaded.")
        case .membersOnly:
            return String(localized: "Unavailable: members only", comment: "Playlist picker reason a video can't be downloaded.")
        case .premiumOnly:
            return String(localized: "Unavailable: Premium only", comment: "Playlist picker reason a video can't be downloaded.")
        case .needsAuth:
            return String(localized: "Unavailable: sign-in required", comment: "Playlist picker reason a video can't be downloaded.")
        }
    }

    @MainActor
    private func loadPostVideos() async {
        let url = sanitizedURL
        postVideos = []
        selectedPostVideos = []
        postLoadedURL = nil
        postError = nil
        postIsLoading = false
        guard needsPicker, DownloadManager.isValidURL(url) else { return }
        let isPlaylist = isPlaylistContext
        postIsLoading = true
        do {
            // Debounce: typing restarts this task, so only probe once the URL has
            // settled. Partial URLs often still look valid and would otherwise
            // spawn a failing yt-dlp probe (and flash an error) per keystroke.
            try await Task.sleep(for: .milliseconds(400))
            let videos: [PostDownloadVideo]
            if isPlaylist {
                videos = try await postService.fetchPlaylistEntries(url: url).enumerated().map { offset, entry in
                    PostDownloadVideo(slideIndex: offset + 1, url: entry.url, title: entry.title,
                                      thumbnailURL: entry.thumbnailURL, duration: entry.duration,
                                      unavailability: entry.unavailability)
                }
            } else {
                videos = try await postService.fetchPostVideos(url: url)
            }
            try Task.checkCancellation()
            guard sanitizedURL == url, isPlaylistContext == isPlaylist else { return }
            postVideos = videos
            postLoadedURL = url
            // Playlists default to everything, matching the old whole-playlist
            // behaviour; a single-video post requires no further choice.
            if isPlaylist || videos.count == 1 {
                selectedPostVideos = Set(videos.filter(\.isAvailable).map(\.slideIndex))
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, sanitizedURL == url else { return }
            postError = error.localizedDescription
        }
        postIsLoading = false
    }

    @ViewBuilder
    private var actionSection: some View {
        if onSchedule != nil {
            scheduleSection
        } else {
            simpleDownloadSection
        }
    }

    private var scheduleSection: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isScheduled) {
                Label("Schedule", systemImage: "clock")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)
            .disabled(isPlaylistContext)
            .opacity(isPlaylistContext ? 0.5 : 1.0)
            .help(isPlaylistContext ? "Scheduling isn't supported for playlist downloads" : "")

            DatePicker(
                "",
                selection: $scheduledDate,
                in: minimumScheduleDate...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.field)
            .disabled(!isScheduled || isPlaylistContext)
            .opacity(isScheduled && !isPlaylistContext ? 1.0 : 0.5)

            Spacer()

            Button(isScheduled ? "Schedule" : downloadButtonTitle) {
                submit()
            }
            .accessibilityIdentifier("downloadSubmitButton")
            .keyboardShortcut(.return, modifiers: [])
            .disabled(downloadDisabled)
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    private var simpleDownloadSection: some View {
        HStack {
            Spacer()
            Button(downloadButtonTitle) {
                submit()
            }
            .accessibilityIdentifier("downloadSubmitButton")
            .keyboardShortcut(.return, modifiers: [])
            .disabled(downloadDisabled)
            .buttonStyle(.borderedProminent)
        }
    }

    private var automationToggles: some View {
        HStack(spacing: 8) {
            toggleButton(
                isOn: $downloadLiveFromStart,
                iconOn: "backward.end.fill",
                iconOff: "backward.end",
                label: "Record from start",
                color: .accentColor,
                help: "When enabled, yt-dlp will rewind live streams to the beginning before recording"
            )

            toggleButton(
                isOn: $downloadAudioOnly,
                iconOn: "waveform.circle.fill",
                iconOff: "waveform.circle",
                label: "Audio only",
                color: .purple,
                help: "Download only the audio track (no video)"
            )

            if Self.looksLikePlaylistURL(urlText) {
                toggleButton(
                    isOn: $downloadWholePlaylist,
                    iconOn: "list.bullet.rectangle.fill",
                    iconOff: "list.bullet.rectangle",
                    label: "Playlist",
                    color: .orange,
                    help: "Choose videos from the playlist or channel to add as separate queue items (downloads run sequentially)"
                )
            }

            toggleButton(
                isOn: $autoEncodeAfterDownload,
                iconOn: "play.circle.fill",
                iconOff: "play.circle",
                label: "Encode",
                color: .green,
                help: "Automatically start encoding after download completes"
            )

            toggleButton(
                isOn: $autoUploadAfterDownload,
                iconOn: "arrow.up.circle.fill",
                iconOff: "arrow.up.circle",
                label: "Upload",
                color: .blue,
                help: "Automatically upload after encoding completes"
            )

            Spacer()
        }
    }

    private func toggleButton(isOn: Binding<Bool>, iconOn: String, iconOff: String, label: LocalizedStringKey, color: Color, help: LocalizedStringKey) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? iconOn : iconOff)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.subheadline)
            }
            .foregroundColor(isOn.wrappedValue ? .white : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn.wrappedValue ? color : Color.gray.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var historySection: some View {
        if hasUnreadableHistory {
            historyStorageWarning
        }
        if !history.isEmpty {
            Divider()
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                historyHeader
                historyList
            }
        }
    }

    private var historyStorageWarning: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved download history could not be read.")
                    .font(.headline)
                    .accessibilityIdentifier("downloadHistoryStorageWarning")
                Text("The saved data has been kept. Downloads still work, but new history cannot be saved until you reset it.")
                    .font(.caption)
            }
            Spacer()
            Button("Reset Download History…") {
                showHistoryResetConfirmation = true
            }
            .accessibilityIdentifier("downloadHistoryStorageResetButton")
        }
        .padding()
        .background(.orange.opacity(0.1))
        .alert("Reset saved download history?", isPresented: $showHistoryResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset Download History", role: .destructive) {
                DownloadHistoryService.clearHistory()
                history = DownloadHistoryService.getHistory()
                hasUnreadableHistory = DownloadHistoryService.hasUnreadableHistory()
                historyIndex = -1
            }
            .accessibilityIdentifier("downloadHistoryStorageResetConfirmButton")
        } message: {
            Text("This permanently deletes the unreadable download history. Downloaded files will be kept.")
        }
    }

    private var historyHeader: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Recent Downloads")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("↑↓ to navigate")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(history.indices, id: \.self) { index in
                        historyRow(index: index, entry: history[index])
                            .id(index)
                    }
                }
            }
            .frame(maxHeight: needsPicker || isClipActive ? 100 : 220)
            .onChange(of: historyIndex) { _, newValue in
                // Keep the arrow-key selection inside the visible scroll area.
                guard newValue >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func historyRow(index: Int, entry: DownloadHistoryEntry) -> some View {
        let isSelected = index == historyIndex
        return Button {
            urlText = entry.url
            historyIndex = index
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text(entry.url)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }

                Spacer()

                Text(entry.downloadedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.6) : Color.secondary.opacity(0.6))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : .primary.opacity(0.05))
        )
    }

    // MARK: - History Navigation

    /// Navigate forward into history (Down arrow - older entries, visually down the list)
    private func navigateHistoryForward() {
        guard !history.isEmpty else { return }

        if historyIndex == -1 {
            // Starting history navigation, save current text
            originalText = urlText
            historyIndex = 0
        } else if historyIndex < history.count - 1 {
            // Move to older entry (visually down)
            historyIndex += 1
        }

        urlText = history[historyIndex].url
    }

    /// Navigate backward through history (Up arrow - newer entries, visually up toward text field)
    private func navigateHistoryBackward() {
        guard historyIndex >= 0 else { return }

        if historyIndex > 0 {
            // Move to newer entry (visually up)
            historyIndex -= 1
            urlText = history[historyIndex].url
        } else {
            // At the newest entry, restore original text
            historyIndex = -1
            urlText = originalText
        }
    }

    private func submit() {
        let sanitized = DownloadManager.sanitizeURLInput(urlText)
        guard !sanitized.isEmpty, DownloadManager.isValidURL(sanitized) else { return }
        let trimmed = sanitized
        guard !downloadDisabled else { return }
        let selected = postVideos.filter { $0.isAvailable && selectedPostVideos.contains($0.slideIndex) }

        // Only honour the stored playlist preference when the URL actually looks
        // like a playlist or channel — the toggle is hidden otherwise, so the
        // stored value can carry over from a prior session. Scheduling and
        // playlists don't compose yet (single-item persistence model), so a
        // playlist always submits immediately and sequentially.
        if isPlaylistContext, let onSubmitPlaylist {
            onSubmitPlaylist(selected.map {
                YTDLPPlaylistEntry(url: $0.url, title: $0.title, duration: $0.duration, thumbnailURL: $0.thumbnailURL)
            }, downloadAudioOnly)
            isPresented = false
            return
        }
        if needsPicker {
            for video in selected {
                submitURL(video.url)
            }
            isPresented = false
            return
        }

        submitURL(trimmed, section: clipSection)
        isPresented = false
    }

    private func submitURL(_ url: String, section: DownloadSection? = nil) {
        if isScheduled, !isPlaylistContext, let onSchedule = onSchedule {
            // Round to the start of the minute (remove seconds)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
            let roundedDate = calendar.date(from: components) ?? scheduledDate
            onSchedule(url, roundedDate, downloadLiveFromStart, downloadAudioOnly, section)
        } else {
            onSubmit(url, downloadLiveFromStart, downloadAudioOnly, section)
        }
    }
}

#Preview {
    URLInputOverlay(isPresented: .constant(true)) { _, _, _, _ in }
}
