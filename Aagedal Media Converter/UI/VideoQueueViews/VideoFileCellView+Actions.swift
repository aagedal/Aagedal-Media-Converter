// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

private let scheduledTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

extension VideoFileCellView {

    // MARK: - Toggle Buttons Update

    func updateToggleButtons(config: VideoFileCellConfiguration) {
        // --- Encode button (green play icon) ---
        encodeButton.isHidden = false
        let isEncoding = config.status == .converting
        encodeButton.image = VideoFileCellView.Symbol.playFill
        encodeButton.contentTintColor = isEncoding ? .systemGreen : .systemGreen.withAlphaComponent(0.75)
        encodeButton.isEnabled = config.status == .waiting || config.status == .done || config.status == .failed
        encodeButton.toolTip = isEncoding ? "Encoding in progress" : "Start encoding"
        applyProcessingRing(to: encodeButton, active: isEncoding, color: .systemGreen)

        // Auto-encode button (only during download)
        let showAutoEncode = config.isDownloading || config.scheduledDownloadTime != nil
        autoEncodeButton.isHidden = !showAutoEncode
        if showAutoEncode {
            autoEncodeButton.image = config.autoEncodeAfterDownload ? VideoFileCellView.Symbol.playFill : VideoFileCellView.Symbol.play
            autoEncodeButton.contentTintColor = config.autoEncodeAfterDownload ? .systemGreen : .secondaryLabelColor
            autoEncodeButton.toolTip = config.autoEncodeAfterDownload ? "Auto-encode enabled" : "Enable auto-encode after download"
        }

        // --- Transcription button (yellow) ---
        transcriptionButton.isHidden = false
        let isTranscriptionEnabled = config.subtitleEnabled && (config.subtitleMethod == .whisper || config.subtitleMethod == .parakeet)
        let isTranscribing = config.subtitleStatus.isInProgress
            && (config.subtitleMethod == .whisper || config.subtitleMethod == .parakeet)
        transcriptionButton.image = isTranscriptionEnabled ? VideoFileCellView.Symbol.captionsBubbleFill : VideoFileCellView.Symbol.captionsBubble
        if !config.isTranscriptionAvailable {
            transcriptionButton.contentTintColor = .systemOrange
            transcriptionButton.toolTip = "Transcription engine not installed. Configure in Settings → Transcription."
        } else if isTranscriptionEnabled || isTranscribing {
            transcriptionButton.contentTintColor = .systemYellow
            let engineName = config.subtitleMethod == .parakeet ? "Parakeet" : "Whisper"
            transcriptionButton.toolTip = "Transcription (\(engineName)) enabled. ⌥-click to generate SRT only."
        } else {
            transcriptionButton.contentTintColor = .secondaryLabelColor
            transcriptionButton.toolTip = "Enable transcription. ⌥-click to generate SRT only."
        }
        applyProcessingRing(to: transcriptionButton, active: isTranscribing, color: .systemYellow)

        // OCR button
        let showOCR = config.hasBitmapSubtitles
        ocrButton.isHidden = !showOCR
        if showOCR {
            let isOCREnabled = config.subtitleEnabled && config.subtitleMethod == .ocr
            let isOCRing = config.subtitleStatus.isInProgress && config.subtitleMethod == .ocr
            let isOCRActive = isOCREnabled || isOCRing
            ocrButton.contentTintColor = isOCRActive ? .systemYellow : .secondaryLabelColor
            ocrButton.toolTip = isOCRActive
                ? "OCR enabled. ⌥-click to generate SRT only."
                : "Enable OCR for bitmap subtitles. ⌥-click to generate SRT only."
            applyProcessingRing(to: ocrButton, active: isOCRing, color: .systemYellow)
        }

        // --- Analytics button (cyan) ---
        let showAnalytics = config.hasVideoStream
        analyticsButton.isHidden = !showAnalytics
        let isAnalyzing = config.analyticsStatus.isInProgress
        if showAnalytics {
            let analyticsIcon: String
            let analyticsColor: NSColor
            if config.hasAnalyticsResults {
                analyticsIcon = "chart.bar.xaxis.ascending"
                analyticsColor = .systemGreen
                analyticsButton.toolTip = "View quality analytics results. ⌥-click to rerun."
            } else if isAnalyzing {
                analyticsIcon = "chart.bar.xaxis.ascending"
                analyticsColor = .systemCyan
                analyticsButton.toolTip = "Analytics in progress"
            } else if config.analyticsEnabled {
                analyticsIcon = "chart.bar.xaxis.ascending"
                analyticsColor = .systemCyan
                analyticsButton.toolTip = "Quality analytics will run after encoding"
            } else {
                analyticsIcon = "chart.bar.xaxis"
                analyticsColor = .secondaryLabelColor
                analyticsButton.toolTip = "Enable quality analytics (VMAF/PSNR/SSIMULACRA2)"
            }
            analyticsButton.image = VideoFileCellView.Symbol.named(analyticsIcon)
            analyticsButton.contentTintColor = analyticsColor
        }
        applyProcessingRing(to: analyticsButton, active: isAnalyzing, color: .systemCyan)

        // --- Upload button (blue) ---
        uploadButton.isHidden = false
        let isUploading = config.uploadStatus == .uploading
        let uploadIcon: String
        let uploadColor: NSColor
        if config.uploadSourceFile {
            uploadIcon = "arrow.up.doc.fill"
            uploadColor = .systemOrange
            uploadButton.toolTip = "Source file will upload. ⌥-click to disable."
        } else if config.uploadEnabled {
            uploadIcon = "icloud.and.arrow.up.fill"
            uploadColor = .systemBlue
            uploadButton.toolTip = "Upload after encoding. ⌥-click to upload source file."
        } else {
            uploadIcon = "icloud.and.arrow.up"
            uploadColor = .secondaryLabelColor
            uploadButton.toolTip = config.isUploadConfigured
                ? "Enable upload after encoding. ⌥-click to upload source file."
                : "Configure upload in Settings → Upload"
        }
        uploadButton.image = VideoFileCellView.Symbol.named(uploadIcon)
        uploadButton.contentTintColor = uploadColor
        uploadButton.isEnabled = config.isUploadConfigured
        applyProcessingRing(to: uploadButton, active: isUploading, color: .systemBlue)

        // Divider visibility tracks the toggle buttons themselves; both are now
        // visible in compact mode too, so the dividers stay shown.
        buttonDivider.isHidden = false
        metaDivider.isHidden = false
    }

    /// Shows or hides a circular ring around a button to indicate active processing.
    /// The border width and corner radius are always present (set in setupToggleButton)
    /// so toggling the ring only changes the color, preventing any layout shift.
    private func applyProcessingRing(to button: NSButton, active: Bool, color: NSColor) {
        button.layer?.borderColor = active
            ? color.withAlphaComponent(0.8).cgColor
            : NSColor.clear.cgColor
    }

    // MARK: - Action Buttons Update

    func updateActionButtons(config: VideoFileCellConfiguration) {
        // Hide all first
        deleteButton.isHidden = true
        resetButton.isHidden = true
        cancelButton.isHidden = true
        stopDownloadButton.isHidden = true
        cancelDownloadButton.isHidden = true
        cancelScheduledButton.isHidden = true
        retryDownloadButton.isHidden = true
        redownloadButton.isHidden = true
        cancelSubtitleButton.isHidden = true
        cancelAnalyticsButton.isHidden = true

        if config.isDownloading {
            stopDownloadButton.isHidden = false
            stopDownloadButton.toolTip = "Stop download and keep partial file"
            cancelDownloadButton.isHidden = false
            cancelDownloadButton.toolTip = "Cancel and discard download"
        } else if config.scheduledDownloadTime != nil {
            cancelScheduledButton.isHidden = false
            cancelScheduledButton.toolTip = "Cancel scheduled download"
        } else if config.fileAlreadyExistsPath != nil {
            redownloadButton.isHidden = false
            redownloadButton.toolTip = "Redownload (overwrite existing file)"
        } else if config.downloadError != nil {
            retryDownloadButton.isHidden = false
            retryDownloadButton.toolTip = "Retry download"
        } else if config.status == .converting {
            cancelButton.isHidden = false
            cancelButton.toolTip = "Cancel conversion"
        } else if config.subtitleStatus.isInProgress {
            cancelSubtitleButton.isHidden = false
            cancelSubtitleButton.toolTip = "Cancel subtitle generation"
        } else if config.analyticsStatus.isInProgress {
            cancelAnalyticsButton.isHidden = false
            cancelAnalyticsButton.toolTip = "Cancel analytics"
        } else {
            deleteButton.isHidden = false
            deleteButton.toolTip = "Remove from list"
            // Hide rather than disable so we don't carry a faded icon next to the
            // strong delete one. Stack order is [reset, delete] so delete stays put.
            resetButton.isHidden = config.status == .converting || config.status == .waiting
            resetButton.toolTip = "Reset status"
        }
    }

    // MARK: - Status Capsule Update

    func updateStatusCapsule(config: VideoFileCellConfiguration) {
        let (text, icon, color): (String, String, NSColor) = {
            if config.downloadError != nil { return ("ERROR", "exclamationmark.circle", .systemRed) }
            if config.isDownloading {
                if config.isLiveStreamRecording { return ("LIVE", "bolt.fill", .systemPurple) }
                return ("DOWNLOADING", "arrow.down.circle", .systemPurple)
            }
            if config.uploadStatus == .uploading { return ("UPLOADING", "arrow.up.circle", .systemBlue) }
            if config.uploadStatus == .uploaded { return ("UPLOADED", "checkmark.circle", .systemGreen) }
            if case .failed = config.uploadStatus { return ("UPLOAD ERR", "exclamationmark.circle", .systemRed) }
            if config.subtitleStatus.isInProgress { return ("SUBTITLES", "captions.bubble", .systemOrange) }
            if case .failed = config.subtitleStatus { return ("SUBTITLE FAIL", "exclamationmark.circle", .systemRed) }
            if config.analyticsStatus.isInProgress { return ("ANALYZING", "chart.bar.xaxis", .systemCyan) }

            switch config.status {
            case .waiting: return ("WAITING", "clock", .secondaryLabelColor)
            case .converting: return ("ENCODING", "arrow.trianglehead.2.clockwise", .systemBlue)
            case .done: return ("DONE", "checkmark.circle", .systemGreen)
            case .failed: return ("FAILED", "exclamationmark.circle", .systemRed)
            case .cancelled: return ("CANCELLED", "xmark.circle", .secondaryLabelColor)
            @unknown default: return ("", "questionmark", .secondaryLabelColor)
            }
        }()

        capsuleLabel.stringValue = text
        capsuleLabel.textColor = color
        capsuleIcon.image = VideoFileCellView.Symbol.named(icon)
        capsuleIcon.contentTintColor = color
        statusCapsule.layer?.borderColor = color.withAlphaComponent(0.6).cgColor
        statusCapsule.toolTip = config.status == .failed ? config.conversionError : nil
    }

    // MARK: - Status Row Update

    func updateStatusRow(config: VideoFileCellConfiguration) {
        // Overwrite warning
        overwriteWarningLabel.isHidden = config.isCompactMode || !(config.status == .waiting && config.outputFileExists)

        // Output size
        if !config.isCompactMode, config.status == .done, let size = config.formattedOutputSize {
            outputSizeLabel.stringValue = "Export: \(size)"
            outputSizeLabel.isHidden = false
        } else {
            outputSizeLabel.isHidden = true
        }

        // Status text
        let text = progressText(config: config)
        statusLabel.stringValue = text
        statusLabel.textColor = statusColor(config: config)
        // Show full error in tooltip when the label truncates it
        let isSubtitleFailed: Bool = {
            if case .failed = config.subtitleStatus { return true }
            return false
        }()
        statusLabel.toolTip = (config.status == .failed || config.downloadError != nil || isSubtitleFailed) ? text : nil
    }

    // MARK: - Progress Text

    func progressText(config: VideoFileCellConfiguration) -> String {
        // Scheduled download — capsule can't show time detail
        if let scheduledTime = config.scheduledDownloadTime {
            return "Scheduled \(scheduledTimeFormatter.string(from: scheduledTime))"
        }

        // Downloading — show percentage and speed (capsule shows DOWNLOADING)
        if config.isDownloading {
            if config.downloadStopping { return "Stopping..." }
            if config.isLiveStreamRecording { return "" }
            if !config.downloadHasProgress { return "Preparing..." }
            let pct = Int(config.downloadProgress * 100)
            if let speed = config.downloadSpeed {
                return "\(pct)% (\(speed))"
            }
            return "\(pct)%"
        }

        // Download error — show detail
        if let error = config.downloadError {
            return error
        }

        // File already exists
        if config.fileAlreadyExistsPath != nil {
            return "File already exists"
        }

        // Upload — show percentage only (capsule shows UPLOADING/UPLOADED/UPLOAD ERR)
        if config.uploadStatus == .uploading {
            return "\(Int(config.uploadProgress * 100))%"
        }
        if config.uploadStatus == .uploaded { return "" }
        if case .failed(let error) = config.uploadStatus { return error }

        // Subtitle generation — show the active stage in addition to percentage so the
        // user knows what's happening when progress hasn't started moving yet (e.g. an
        // FFmpeg PGS dump that hasn't emitted its first time= line yet).
        if config.subtitleStatus.isInProgress {
            let pct = Int(config.subtitleProgress * 100)
            let stage = subtitleStageLabel(status: config.subtitleStatus, method: config.subtitleMethod)
            if stage.isEmpty { return "\(pct)%" }
            return "\(stage) \(pct)%"
        }
        if case .failed(let error) = config.subtitleStatus {
            return error
        }

        // Analytics
        if config.analyticsStatus.isInProgress {
            return "\(Int(config.analyticsProgress * 100))%"
        }

        if case .failed(let error) = config.analyticsStatus { return error }

        // Conversion — show percentage and ETA (capsule shows ENCODING/DONE/FAILED/WAITING).
        // For multi-phase exports (DCP, IMF) `statusMessage` carries the active stage label
        // ("Wrapping audio essence 42%"); when present we prefix it so the user can see
        // which sub-step is running even though the FFmpeg ETA may be stale.
        switch config.status {
        case .waiting:
            return ""
        case .converting:
            let pct = Int(config.progress * 100)
            let stagePrefix: String = {
                guard let stage = config.statusMessage, !stage.isEmpty else { return "" }
                return "\(stage) · "
            }()
            if let eta = config.eta {
                return "\(stagePrefix)\(pct)% — ETA \(eta)"
            }
            return "\(stagePrefix)\(pct)%"
        case .done:
            return ""
        case .failed:
            return config.conversionError ?? ""
        case .cancelled:
            return ""
        @unknown default:
            return ""
        }
    }

    private func subtitleStageLabel(status: SubtitleStatus, method: SubtitleConversionMethod) -> String {
        switch status {
        case .pending:
            return "Preparing"
        case .extractingAudio:
            return method == .ocr ? "Extracting subtitle stream" : "Extracting audio"
        case .generating:
            switch method {
            case .ocr:      return "Recognizing text"
            case .whisper:  return "Transcribing (Whisper)"
            case .parakeet: return "Transcribing (Parakeet)"
            }
        case .embedding:
            return "Embedding subtitles"
        default:
            return ""
        }
    }

    // MARK: - Status Color

    private func statusColor(config: VideoFileCellConfiguration) -> NSColor {
        if config.downloadError != nil { return .systemRed }
        if config.fileAlreadyExistsPath != nil { return .systemOrange }
        if config.isDownloading { return .systemPurple }
        if config.uploadStatus == .uploading { return .systemBlue }
        if config.uploadStatus == .uploaded { return .systemGreen }
        if case .failed = config.uploadStatus { return .systemRed }
        if config.subtitleStatus.isInProgress { return .systemOrange }
        if case .failed = config.subtitleStatus { return .systemRed }
        if config.analyticsStatus.isInProgress { return .systemCyan }

        switch config.status {
        case .waiting: return .secondaryLabelColor
        case .converting: return .systemBlue
        case .done: return .systemGreen
        case .failed: return .systemRed
        case .cancelled: return .secondaryLabelColor
        @unknown default: return .secondaryLabelColor
        }
    }

    // MARK: - Context Menu

    func buildContextMenu(config: VideoFileCellConfiguration) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "Show Source in Finder", action: #selector(ctxShowInFinder), keyEquivalent: "")
            .target = self

        if config.status == .done, config.outputURL != nil {
            menu.addItem(withTitle: "Show Output in Finder", action: #selector(ctxShowOutputInFinder), keyEquivalent: "")
                .target = self
        }

        if config.subtitleFilePath != nil {
            menu.addItem(withTitle: "Show Subtitle File in Finder", action: #selector(ctxShowSubtitleInFinder), keyEquivalent: "")
                .target = self
        }

        menu.addItem(.separator())

        if !config.isDownloading && config.scheduledDownloadTime == nil {
            menu.addItem(withTitle: "Preview / Trim", action: #selector(ctxPreview), keyEquivalent: "")
                .target = self
        }

        menu.addItem(withTitle: "Metadata", action: #selector(ctxMetadata), keyEquivalent: "")
            .target = self

        if config.isDCPPreset {
            menu.addItem(withTitle: "DCP Metadata…", action: #selector(ctxDCPMetadata), keyEquivalent: "")
                .target = self
        } else if config.isIMFPreset {
            menu.addItem(withTitle: "IMF Metadata…", action: #selector(ctxIMFMetadata), keyEquivalent: "")
                .target = self
        }

        if config.hasVideoStream || config.audioStreamCount > 0 {
            menu.addItem(withTitle: "Audio Routing", action: #selector(ctxAudioRouting), keyEquivalent: "")
                .target = self
        }

        menu.addItem(withTitle: "Attach Subtitle File", action: #selector(ctxAttachSubtitle), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        let renameItem = menu.addItem(withTitle: "Rename Output", action: #selector(ctxRename), keyEquivalent: "")
        renameItem.target = self
        renameItem.isEnabled = config.status == .waiting

        let resetItem = menu.addItem(withTitle: "Reset", action: #selector(ctxReset), keyEquivalent: "")
        resetItem.target = self
        resetItem.isEnabled = config.status != .waiting && config.status != .converting

        let removeItem = menu.addItem(withTitle: "Remove", action: #selector(ctxRemove), keyEquivalent: "")
        removeItem.target = self
        removeItem.isEnabled = config.status != .converting

        return menu
    }

    @objc private func ctxShowInFinder() { actionHandler?(.showInFinder) }
    @objc private func ctxShowOutputInFinder() { actionHandler?(.showOutputInFinder) }
    @objc private func ctxShowSubtitleInFinder() { actionHandler?(.showSubtitleInFinder) }
    @objc private func ctxPreview() { actionHandler?(.showPreview) }
    @objc private func ctxMetadata() { actionHandler?(.showMetadata) }
    @objc private func ctxDCPMetadata() { actionHandler?(.showDCPMetadata) }
    @objc private func ctxIMFMetadata() { actionHandler?(.showIMFMetadata) }
    @objc private func ctxAudioRouting() { actionHandler?(.showAudioRouting) }
    @objc private func ctxAttachSubtitle() { actionHandler?(.attachSubtitleFile) }
    @objc private func ctxRename() { actionHandler?(.beginRename) }
    @objc private func ctxReset() { actionHandler?(.reset(optionKeyPressed: false)) }
    @objc private func ctxRemove() { actionHandler?(.delete) }
}
