// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ObjectiveC
import SwiftUI

extension VideoFileCellView: NSPopoverDelegate {

    // MARK: - Comment popover storage (associated object — stored properties not allowed in extensions)

    private static var commentPopoverKey: UInt8 = 0
    private static var commentPopoverHostKey: UInt8 = 0
    var commentPopover: NSPopover? {
        get { objc_getAssociatedObject(self, &Self.commentPopoverKey) as? NSPopover }
        set { objc_setAssociatedObject(self, &Self.commentPopoverKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    var commentPopoverHost: NSViewController? {
        get { objc_getAssociatedObject(self, &Self.commentPopoverHostKey) as? NSViewController }
        set { objc_setAssociatedObject(self, &Self.commentPopoverHostKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    // MARK: - Comment Button + Popover Setup

    /// Configures the comment / date-tag / waveform buttons as toggle-style icons so
    /// they render the same way as the encode / transcription / upload buttons and can
    /// sit alongside them in the buttons row. The comment field itself no longer lives
    /// inline — it opens in a popover anchored to the comment button.
    func setupCommentSection() {
        setupToggleButton(commentToggleButton, symbol: "text.bubble", action: #selector(commentToggleClicked))
        commentToggleButton.setAccessibilityIdentifier("queue.item.metadataEditor")
        commentToggleButton.setAccessibilityLabel("Edit metadata")
        setupToggleButton(metadataToggleButton, symbol: "film.stack", action: #selector(metadataToggleClicked))
        setupToggleButton(dateTagButton, symbol: "calendar.badge.checkmark", action: #selector(dateTagClicked))
        setupToggleButton(waveformButton, symbol: "waveform.circle", action: #selector(waveformClicked))
        setupToggleButton(waveformBgButton, symbol: "photo", action: #selector(waveformBgClicked))

        // The info and comment-section containers from the old layout aren't used anymore
        // but are kept as plain references so the existing update paths don't crash.
        commentInfoButton.isHidden = true
        commentSection.isHidden = true

        // Configure the comment field for use inside the popover.
        commentField.font = .systemFont(ofSize: 12)
        commentField.placeholderString = "Add a comment (single line)…"
        commentField.isBezeled = true
        commentField.bezelStyle = .roundedBezel
        commentField.delegate = self
        commentField.lineBreakMode = .byTruncatingTail
        commentField.maximumNumberOfLines = 1
        commentField.usesSingleLineMode = true
        commentField.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Comment Section Update

    func updateCommentSection(config: VideoFileCellConfiguration) {
        // Each button has its own visibility rule based on what the item actually
        // supports. Compact mode keeps the same buttons visible — VideoFileCellView's
        // applyCompactSizing() shrinks them so they still fit in the shorter row.

        // Comment toggle — only shown when the output container can actually carry
        // a comment tag. Hides the button for DCP (which has its own metadata
        // sheet), image sequences, animated stills, and MXF-based presets.
        let commentsAvailable = config.preset.supportsMetadataComment
        commentToggleButton.isHidden = !commentsAvailable
        commentToggleButton.isEnabled = !config.isDownloading && !config.isQueuedForDownload && config.scheduledDownloadTime == nil && !config.isLiveStreamRecording && config.downloadError == nil
        if commentsAvailable {
            // The speech bubble reflects Comment's override, rather than the
            // mere existence of saved settings for any of the editor's fields.
            let writesComment = config.metadataEditorSettings?.writesComment ?? !config.comment.isEmpty
            commentToggleButton.image = writesComment ? VideoFileCellView.Symbol.textBubbleFill : VideoFileCellView.Symbol.textBubble
            commentToggleButton.contentTintColor = writesComment ? .systemCyan : .secondaryLabelColor
            commentToggleButton.setAccessibilityValue(writesComment ? "Comment override enabled" : "Comment override disabled")
            if config.metadataEditorSettings?.isActive == false {
                commentToggleButton.toolTip = "Edit metadata — all editor overrides disabled"
            } else if config.metadataEditorSettings != nil {
                commentToggleButton.toolTip = writesComment
                    ? "Edit metadata — Comment override enabled"
                    : "Edit metadata — Comment override disabled; other fields keep their own settings"
            } else {
                commentToggleButton.toolTip = "Edit metadata — prefilled from the source file"
            }
        }

        // DCP / IMF metadata toggle — visible only when the current preset is a
        // DCP or IMF preset. The cell config carries the per-preset flag plus the
        // current title (nil/empty when nothing has been set yet) so we can
        // tint the button to indicate whether the user has populated metadata.
        let metadataAvailable = config.isDCPPreset || config.isIMFPreset
        metadataToggleButton.isHidden = !metadataAvailable
        if metadataAvailable {
            let title = config.isDCPPreset ? config.dcpMetadataTitle : config.imfMetadataTitle
            let hasMetadata = !(title?.isEmpty ?? true)
            metadataToggleButton.image = hasMetadata ? VideoFileCellView.Symbol.filmStackFill : VideoFileCellView.Symbol.filmStack
            metadataToggleButton.contentTintColor = hasMetadata ? .systemIndigo : .secondaryLabelColor
            if config.isDCPPreset {
                metadataToggleButton.toolTip = hasMetadata
                    ? "Edit DCP metadata — embedded in the CPL/PKL"
                    : "Add DCP metadata (title, content kind, language)"
            } else {
                metadataToggleButton.toolTip = hasMetadata
                    ? "Edit IMF metadata — embedded in the CPL/PKL"
                    : "Add IMF metadata (title, content kind, language)"
            }
        }

        // Date tag button — respects the "show date tag" preference.
        let showDateTag = config.showDateTagButton
        dateTagButton.isHidden = !showDateTag
        if showDateTag {
            let writesComment = config.metadataEditorSettings?.writesComment != false
            dateTagButton.isEnabled = writesComment
            dateTagButton.toolTip = writesComment ? "Include the generated date in the comment" : "Enable Comment in the metadata editor to include a date tag"
            let isActive = config.includeDateTag && writesComment
            dateTagButton.image = isActive ? VideoFileCellView.Symbol.calendarCheck : VideoFileCellView.Symbol.calendarMinus
            dateTagButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
        }

        // Waveform controls only apply to audio-only items.
        let showWaveform = !config.hasVideoStream
        waveformButton.isHidden = !showWaveform
        waveformBgButton.isHidden = !showWaveform
        if showWaveform {
            let isActive = config.waveformVideoEnabled
            waveformButton.image = isActive ? VideoFileCellView.Symbol.waveformCircleFill : VideoFileCellView.Symbol.waveformCircle
            waveformButton.contentTintColor = isActive ? .controlAccentColor : .secondaryLabelColor
        }

        // Focus handoff: if Tab navigated focus to this row, auto-open the
        // popover so the user can keep typing without reaching for the mouse.
        // Suppressed when the button itself is hidden (preset doesn't support
        // comments) — focus just moves past this row.
        if commentsAvailable, commentToggleButton.isEnabled,
           config.isFocusedComment,
           commentPopover?.isShown != true {
            presentCommentPopover()
        } else if !config.isFocusedComment, commentPopover?.isShown == true {
            // Focus moved elsewhere (e.g. Tab navigated to another row). Close
            // this row's popover so it doesn't linger behind the newly-opened one.
            commentPopover?.performClose(nil)
        }
    }

    // MARK: - Popover

    private func presentCommentPopover() {
        guard commentToggleButton.isEnabled, let config = currentConfig else { return }
        if let settings = config.metadataEditorSettings {
            showMetadataEditor(settings, config: config)
            return
        }
        guard metadataEditorLoadTask == nil else { return }
        let sourceURL = config.url
        metadataEditorLoadTask = Task { [weak self] in
            let metadata = await VideoFileUtils.fetchMetadata(for: sourceURL)
            var audioText = ContainerTextMetadata()
            if metadata == nil, SwiftExifMediaProbe.canReadAudio(sourceURL) || ["wav", "aiff", "aif"].contains(sourceURL.pathExtension.lowercased()) {
                audioText = (try? await NonJoiningTaskDeadline.run(timeout: .seconds(15)) {
                    let access = SecurityScopedBookmarkManager.shared.startAccessing(url: sourceURL)
                    defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
                    var text = await ContainerTextMetadata.read(from: sourceURL)
                    if let audio = try? await SwiftExifMediaProbe.readAudio(sourceURL) {
                        text.title = text.title ?? audio.title
                        text.artist = text.artist ?? audio.artist
                        text.comment = text.comment ?? audio.comment
                        for (key, value) in audio.userTextFrames { text.apply(name: key, value: value) }
                        for (key, value) in audio.userURLFrames { text.apply(name: key, value: value) }
                        text.sourceURL = text.sourceURL ?? ContainerTextMetadata.webURL(text.comment)
                    }
                    return text
                }) ?? ContainerTextMetadata()
            }
            guard !Task.isCancelled, let self, let current = self.currentConfig, current.itemID == config.itemID, current.url == sourceURL else { return }
            self.metadataEditorLoadTask = nil
            guard self.commentToggleButton.isEnabled else { return }
            let settings = current.metadataEditorSettings ?? MetadataEditorSettings(
                comment: current.comment.isEmpty ? metadata?.comment ?? current.sourceTextMetadata.comment ?? audioText.comment ?? "" : current.comment,
                description: metadata?.description ?? current.sourceTextMetadata.description ?? audioText.description ?? "",
                title: metadata?.title ?? current.sourceTitle ?? audioText.title ?? "",
                artist: metadata?.artist ?? current.sourceArtist ?? audioText.artist ?? "",
                sourceURL: metadata?.sourceURL ?? current.sourceTextMetadata.sourceURL ?? audioText.sourceURL
            )
            self.showMetadataEditor(settings, config: current)
        }
    }

    private func showMetadataEditor(_ settings: MetadataEditorSettings, config: VideoFileCellConfiguration) {
        commentPopover?.performClose(nil)
        let itemID = config.itemID
        let editor = MetadataEditorPopoverView(settings: settings, includeDateTag: config.includeDateTag) { [weak self] settings in
            guard self?.currentConfig?.itemID == itemID else { return }
            self?.actionHandler?(.metadataEditorChanged(settings))
        }
        let host = NSHostingController(rootView: editor)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 480, height: 410)
        commentPopover = popover
        commentPopoverHost = host
        popover.show(relativeTo: commentToggleButton.bounds, of: commentToggleButton, preferredEdge: .maxY)
        actionHandler?(.commentFocusChanged(true))
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === commentPopover else { return }
        actionHandler?(.commentFocusChanged(false))
    }

    // MARK: - Comment Button Actions

    @objc private func dateTagClicked() { actionHandler?(.toggleDateTag) }
    @objc private func waveformClicked() { actionHandler?(.toggleWaveform) }
    @objc private func waveformBgClicked() { actionHandler?(.showBackgroundImagePicker) }

    /// Opens a popover anchored to the comment button so the user can edit the
    /// comment text without the field occupying space in the row.
    @objc func commentPopoverRequested() {
        presentCommentPopover()
    }
}

private struct MetadataEditorPopoverView: View {
    @State var settings: MetadataEditorSettings
    let includeDateTag: Bool
    let onChange: (MetadataEditorSettings) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Write edited metadata", isOn: Binding(
                get: { settings.isActive }, set: { settings.isEnabled = $0 }
            ))
            .font(.headline)
            .accessibilityIdentifier("metadata.editor.enabled")
            Text(settings.isActive
                 ? "Enabled fields are written to the exported file. Empty enabled fields remove the existing value."
                 : "Editor overrides are off. Original metadata follows the preset's preservation setting.")
                .font(.caption).foregroundStyle(.secondary)
            TabView {
                field("Comment", value: $settings.comment, multiline: true)
                    .tabItem { Text("Comment") }
                field("Description", value: $settings.description, multiline: true)
                    .tabItem { Text("Description") }
                field("Title", value: $settings.title, multiline: false)
                    .tabItem { Text("Title") }
                field("Artist", value: $settings.artist, multiline: false)
                    .tabItem { Text("Artist") }
            }
            if let sourceURL = settings.sourceURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source URL").font(.caption).foregroundStyle(.secondary)
                    Text(sourceURL).font(.caption).textSelection(.enabled).lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(width: 480, height: 410)
        .onAppear { onChange(settings) }
        .onChange(of: settings) { _, newValue in onChange(newValue) }
    }

    private func field(_ label: String, value: Binding<MetadataEditorField>, multiline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Write this field", isOn: value.isEnabled)
                .help("When off, this field follows the original metadata preservation setting.")
                .accessibilityIdentifier("metadata.editor.\(label.lowercased()).enabled")
                .disabled(!settings.isActive)
            if multiline {
                TextEditor(text: value.value)
                    // Recreate the native control when editing permission
                    // changes, keeping its text in the existing binding.
                    .id(settings.isActive && value.wrappedValue.isEnabled)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .disabled(!settings.isActive || !value.wrappedValue.isEnabled)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("metadata.editor.\(label.lowercased()).value")
            } else {
                TextField(label, text: value.value)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.isActive || !value.wrappedValue.isEnabled)
                    .accessibilityIdentifier("metadata.editor.\(label.lowercased()).value")
                Spacer()
            }
            if label == "Comment", settings.isActive, value.wrappedValue.isEnabled {
                let preview = CommentMetadataPlan(comment: value.wrappedValue.value, includeDateTag: includeDateTag, settings: CommentSettings()).value
                Text("Output comment").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(preview ?? "No comment will be added")
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 55)
            }
        }
        .padding(12)
    }
}
