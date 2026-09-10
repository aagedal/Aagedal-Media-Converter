// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import OSLog
import SwiftUI

/// Overlay for entering a URL to download via yt-dlp
struct URLInputOverlay: View {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "URLInput")

    @Binding var isPresented: Bool
    var onSubmit: (String, Bool, Bool, Bool) -> Void
    var onSchedule: ((String, Date, Bool, Bool, Bool) -> Void)?

    @State private var urlText = ""
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
        downloadWholePlaylist && Self.looksLikePlaylistURL(urlText)
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
            actionSection
            automationToggles
            historySection
        }
        .padding(20)
        .frame(width: 620)
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
            .help(isPlaylistContext ? "Scheduling isn't supported for whole-playlist downloads" : "")

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

            Button(isScheduled ? "Schedule" : "Download") {
                submit()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(urlText.isEmpty || !DownloadManager.isValidURL(urlText))
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    private var simpleDownloadSection: some View {
        HStack {
            Spacer()
            Button("Download") {
                submit()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(urlText.isEmpty || !DownloadManager.isValidURL(urlText))
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
                    label: "Whole playlist",
                    color: .orange,
                    help: "Add every video from the playlist or channel as separate queue items (downloads run sequentially)"
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
            .frame(maxHeight: 220)
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

        // Only honour the stored "whole playlist" preference when the URL actually
        // looks like a playlist or channel — the toggle is hidden in that case
        // anyway, so the stored value can carry over from a prior session.
        // Scheduling and whole-playlist don't compose yet (single-item persistence
        // model), so playlist always submits immediately.
        let isPlaylist = downloadWholePlaylist && Self.looksLikePlaylistURL(trimmed)
        if isScheduled, !isPlaylist, let onSchedule = onSchedule {
            // Round to the start of the minute (remove seconds)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledDate)
            let roundedDate = calendar.date(from: components) ?? scheduledDate
            onSchedule(trimmed, roundedDate, downloadLiveFromStart, downloadAudioOnly, isPlaylist)
        } else {
            onSubmit(trimmed, downloadLiveFromStart, downloadAudioOnly, isPlaylist)
        }
        isPresented = false
    }
}

#Preview {
    URLInputOverlay(isPresented: .constant(true)) { _, _, _, _ in }
}
