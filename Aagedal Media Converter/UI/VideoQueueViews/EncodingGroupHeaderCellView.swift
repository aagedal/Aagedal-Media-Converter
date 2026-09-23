// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
    }
}

private extension NSColor {
    static let queueGroupHeaderCardBackground = NSColor(name: "queueGroupHeaderCardBackground") { appearance in
        // Dark: slightly lighter than the row card (0.17) so the header reads as a tier above.
        // Light: slightly darker than the row card (0.93) for the same hierarchy in reverse.
        appearance.isDark
            ? NSColor(white: 0.19, alpha: 1.0)
            : NSColor(white: 0.90, alpha: 1.0)
    }
    static let queueGroupHeaderRestingStroke = NSColor(name: "queueGroupHeaderRestingStroke") { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.18)
    }
}

/// Pure AppKit cell view for an encoding group header.
/// Mirrors VideoFileCellView's card layout — same thumbnail area + shadow + corner radius — so
/// groups read as peers of single items. The thumbnail area uses a stacked-thumbnail preview
/// that signals "this is a group of items"; the selection border is dashed at rest and solid
/// + system-blue when selected. When expanded, child items render as compact mini-rows inside
/// the group's card rather than as separate table rows.
final class EncodingGroupHeaderCellView: NSTableCellView, NSTextFieldDelegate {

    static let baseRowHeight: CGFloat = 170
    static let baseCompactRowHeight: CGFloat = 120

    /// Computes the total row height the table view should reserve for this group.
    /// Groups are now single-height summary cards — expand/collapse was removed
    /// when detail editing moved to the standalone Group Editor window.
    static func rowHeight(for config: EncodingGroupCellConfiguration) -> CGFloat {
        config.isCompactMode ? baseCompactRowHeight : baseRowHeight
    }

    // MARK: - Cached SF Symbols (group-header-specific)

    private enum GroupSymbol {
        static let folderFill       = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: String(localized: "Group folder"))
        static let plus             = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add files"))
        static let reset            = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: String(localized: "Reset group"))
        static let trash            = NSImage(systemSymbolName: "trash", accessibilityDescription: String(localized: "Delete group"))
        static let numberCircleFill = NSImage(systemSymbolName: "number.circle.fill", accessibilityDescription: String(localized: "Sequential naming enabled"))
        static let numberCircle     = NSImage(systemSymbolName: "number.circle", accessibilityDescription: String(localized: "Sequential naming"))
        static let concat           = NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: String(localized: "Concatenate clips"))
        static let finderCircle     = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: String(localized: "Show in Finder"))
        static let dragHandle       = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: String(localized: "Drag to share"))
        static let uploadedCheck    = NSImage(systemSymbolName: "checkmark.icloud.fill", accessibilityDescription: String(localized: "Upload complete"))
        static let uploadFailed     = NSImage(systemSymbolName: "exclamationmark.icloud.fill", accessibilityDescription: String(localized: "Upload failed"))
        static let uploadPending    = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: String(localized: "Upload pending"))
        static let playCircle       = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: String(localized: "Start"))
        static let checkmarkCircle  = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: String(localized: "Done"))
        static let xmarkCircle      = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Cancel"))
        static let arrowDownCircle  = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: String(localized: "Download"))
        static let clock            = NSImage(systemSymbolName: "clock", accessibilityDescription: String(localized: "Pending"))
    }

    // MARK: - State

    private(set) var currentGroupID: UUID?
    var actionHandler: ((CellAction) -> Void)?
    private var currentConfig: EncodingGroupCellConfiguration?

    // MARK: - Subviews

    private let cardView = NSView()
    private let selectionBorderLayer = CAShapeLayer()

    private let mainHStack = NSStackView()

    // Thumbnail area (left)
    private let thumbnailContainer = NSView()
    private let thumbnailBorderLayer = CAShapeLayer()
    private let stackedThumb1 = NSImageView()   // back
    private let stackedThumb2 = NSImageView()   // middle
    private let stackedThumb3 = NSImageView()   // front (primary)
    private let emptyFolderIcon = NSImageView()
    private let childCountBadge = NSTextField(labelWithString: "")
    /// Centered glass overlay shown on thumbnail hover. Opens the group editor
    /// — mirrors VideoFileCellView's hover-to-play UX so groups read as peers.
    private let overlayOpenButton = PlayOverlayButtonView()
    private var thumbnailTrackingArea: NSTrackingArea?

    // Right side: content
    private let contentStack = NSStackView()
    private let topRow = NSStackView()
    private let metaRow = NSStackView()
    private let statusRow = NSStackView()
    private let buttonsRow = NSStackView()
    private let togglesStack = NSStackView()
    private let progressBar = NSProgressIndicator()
    private let uploadRow = NSStackView()
    private let uploadIcon = NSImageView()
    private let uploadLabel = NSTextField(labelWithString: "")
    private let uploadProgress = NSProgressIndicator()
    /// Small inline button shown at the trailing edge of the upload row while
    /// an upload is active or queued. Lets the user stop the rclone transfer
    /// without removing the entire group.
    private let cancelUploadButton = NSButton()

    // Status row (mirrors VideoFileCellView's status capsule + label)
    private let statusCapsule = NSView()
    private let capsuleIcon = NSImageView()
    private let capsuleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    // Top row
    private let folderIcon = NSImageView()
    private let nameField = NSTextField()
    private let clipCountLabel = NSTextField(labelWithString: "")
    private let concatOutputButton = NSButton()
    private let concatCopyPathButton = NSButton()
    private let concatDragButton = DraggableFileImageView()
    private let concatWarningButton = NSButton()
    // Buttons row layout mirrors VideoFileCellView: add/edit + toggles sit on
    // the leading edge, reset/delete are pushed to the trailing edge by a
    // spacer + divider. Sort intentionally lives only in the editor window
    // and the context menu — the bigger, multi-mode picker over there
    // replaces the cycle button that used to be on the card.
    private let addFilesButton = NSButton()
    private let editButton = NSButton()
    private let resetButton = NSButton()
    private let deleteButton = NSButton()
    private let actionButtonDivider = NSView()
    /// Vertical separator between the group-specific toggles (sequential
    /// naming, concat) and the encode/post-processing pipeline that mirrors
    /// VideoFileCellView's button order.
    private let groupSpecificDivider = NSView()
    /// Vertical separator between the encode button and the post-processing
    /// toggles (transcribe, analytics, upload). Mirrors `encodeDivider` on
    /// VideoFileCellView so groups read as peers of single-item cards.
    private let encodeDivider = NSView()

    // Bottom row
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sequentialToggle = NSButton()
    private let concatToggle = NSButton()
    private let encodeButton = NSButton()
    private let uploadToggle = NSButton()
    private let transcriptionToggle = NSButton()
    private let analyticsToggle = NSButton()

    private var presetWidthConstraint: NSLayoutConstraint?
    private var thumbnailWidthConstraint: NSLayoutConstraint?
    private var thumbnailHeightConstraint: NSLayoutConstraint?
    private var checkerHeightConstraint: NSLayoutConstraint?

    // Layout cache
    private var lastCardBoundsSize: CGSize = .zero
    private var lastThumbBoundsSize: CGSize = .zero
    private var isCompact = false

    private var thumbnailWidth: CGFloat { isCompact ? 160 : 240 }

    // Sizing pulled from VideoFileCellView so single-item and group cards stay
    // visually paired in normal vs. compact mode.
    private var buttonSize: CGFloat { isCompact ? VideoFileCellView.compactButtonSize : VideoFileCellView.normalButtonSize }
    private var buttonSymbolPointSize: CGFloat { isCompact ? VideoFileCellView.compactSymbolPointSize : VideoFileCellView.normalSymbolPointSize }
    private var buttonCornerRadius: CGFloat { buttonSize / 2 }
    private var dividerHeight: CGFloat { isCompact ? VideoFileCellView.compactDividerHeight : VideoFileCellView.normalDividerHeight }
    private var capsuleHeight: CGFloat { isCompact ? VideoFileCellView.compactCapsuleHeight : VideoFileCellView.normalCapsuleHeight }

    // Captured at setup so applyCompactLayout can flip them on toggle.
    private var compactSizedButtons: [NSButton] = []
    private var buttonSizeConstraints: [NSLayoutConstraint] = []
    private var dividerHeightConstraints: [NSLayoutConstraint] = []
    private var capsuleHeightConstraint: NSLayoutConstraint?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.masksToBounds = true
        // Card background — dynamic NSColor; reapplied in viewDidChangeEffectiveAppearance.
        applyCardBackground()
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        // Selection border — dashed at rest, solid + system-blue on selection. Idle dash is a
        // muted neutral so it reads as "container" without competing with VideoItem selection.
        selectionBorderLayer.fillColor = nil
        applyRestingSelectionStroke()
        selectionBorderLayer.lineWidth = 1.2
        selectionBorderLayer.lineDashPattern = [6, 4]
        selectionBorderLayer.zPosition = 100
        cardView.layer?.addSublayer(selectionBorderLayer)

        // Main horizontal stack: thumbnail | content
        mainHStack.orientation = .horizontal
        mainHStack.spacing = 0
        mainHStack.alignment = .top
        mainHStack.distribution = .fill
        mainHStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(mainHStack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            mainHStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            mainHStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            mainHStack.topAnchor.constraint(equalTo: cardView.topAnchor),
            mainHStack.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor),
        ])

        setupThumbnailArea()
        setupContentArea()
    }

    // MARK: - Thumbnail area

    private func setupThumbnailArea() {
        thumbnailContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer?.masksToBounds = true
        thumbnailContainer.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        thumbnailContainer.layer?.cornerRadius = 8

        // Checkerboard background — pinned to thumbnail container so it tracks the compact width.
        let checkSize: CGFloat = 16
        let checkImage = NSImage(size: NSSize(width: checkSize * 2, height: checkSize * 2), flipped: true) { rect in
            NSColor(white: 0.2, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.3, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: checkSize, height: checkSize).fill()
            NSRect(x: checkSize, y: checkSize, width: checkSize, height: checkSize).fill()
            return true
        }
        let checkerView = NSView()
        checkerView.wantsLayer = true
        if let cgImage = checkImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            checkerView.layer?.backgroundColor = NSColor(patternImage: NSImage(cgImage: cgImage, size: NSSize(width: checkSize * 2, height: checkSize * 2))).cgColor
        }
        checkerView.layer?.masksToBounds = true
        checkerView.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        checkerView.layer?.cornerRadius = 8
        checkerView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(checkerView, positioned: .below, relativeTo: mainHStack)
        let checkerHeight = checkerView.heightAnchor.constraint(equalToConstant: Self.baseRowHeight - 12)
        self.checkerHeightConstraint = checkerHeight

        // Stacked thumbnail layers — back → middle → front, slight offsets create the "stack" feel.
        for (i, view) in [stackedThumb1, stackedThumb2, stackedThumb3].enumerated() {
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            view.layer?.cornerRadius = 6
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            thumbnailContainer.addSubview(view)
            // Slight darkening for back/mid layers so the stack reads front-to-back.
            view.alphaValue = i == 0 ? 0.55 : (i == 1 ? 0.8 : 1.0)
        }

        // Fallback folder icon, shown when there are no children at all.
        emptyFolderIcon.image = GroupSymbol.folderFill
        emptyFolderIcon.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.75)
        emptyFolderIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyFolderIcon.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(emptyFolderIcon)

        // Child count badge (bottom-right of thumbnail) — always shown when itemCount > 1.
        childCountBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        childCountBadge.textColor = .white
        childCountBadge.isBezeled = false
        childCountBadge.isEditable = false
        childCountBadge.drawsBackground = true
        childCountBadge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        childCountBadge.alignment = .center
        childCountBadge.wantsLayer = true
        childCountBadge.layer?.cornerRadius = 10
        childCountBadge.layer?.masksToBounds = true
        childCountBadge.translatesAutoresizingMaskIntoConstraints = false
        thumbnailContainer.addSubview(childCountBadge)

        // Border over the entire thumbnail container
        thumbnailBorderLayer.fillColor = nil
        thumbnailBorderLayer.strokeColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailBorderLayer.lineWidth = 1
        thumbnailContainer.layer?.addSublayer(thumbnailBorderLayer)

        mainHStack.addArrangedSubview(thumbnailContainer)

        let widthConstraint = thumbnailContainer.widthAnchor.constraint(equalToConstant: thumbnailWidth)
        widthConstraint.identifier = "groupThumbnailWidth"
        self.thumbnailWidthConstraint = widthConstraint

        // Thumbnail only spans the BASE row region; the expanded children live below.
        let heightConstraint = thumbnailContainer.heightAnchor.constraint(equalToConstant: Self.baseRowHeight - 12)
        self.thumbnailHeightConstraint = heightConstraint

        // Now that thumbnailContainer has a superview, its width anchor can be bound to
        // the checkerView's width anchor (they share `cardView` as a common ancestor).
        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            thumbnailContainer.topAnchor.constraint(equalTo: mainHStack.topAnchor),

            checkerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            checkerView.topAnchor.constraint(equalTo: cardView.topAnchor),
            checkerHeight,
            checkerView.widthAnchor.constraint(equalTo: thumbnailContainer.widthAnchor),
        ])

        // Position stacked thumbnails and fallback folder icon relative to the container.
        // Back layer is nudged up-left, middle slightly less so, front is flush to (left + 12, center).
        // Each layer gets ~68% of the container width so they clearly overlap.
        let inset: CGFloat = 12
        let backOffset: CGFloat = 16
        let midOffset: CGFloat = 8

        NSLayoutConstraint.activate([
            // stackedThumb1 (back)
            stackedThumb1.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: inset + backOffset),
            stackedThumb1.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor, constant: inset + backOffset),
            stackedThumb1.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -inset),
            stackedThumb1.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -inset),

            // stackedThumb2 (middle)
            stackedThumb2.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: inset + midOffset),
            stackedThumb2.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor, constant: inset + midOffset),
            stackedThumb2.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -inset - backOffset + midOffset),
            stackedThumb2.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -inset - backOffset + midOffset),

            // stackedThumb3 (front, primary)
            stackedThumb3.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor, constant: inset),
            stackedThumb3.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor, constant: inset),
            stackedThumb3.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -inset - backOffset),
            stackedThumb3.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -inset - backOffset),

            // Empty folder icon
            emptyFolderIcon.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            emptyFolderIcon.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
            emptyFolderIcon.widthAnchor.constraint(equalToConstant: 40),
            emptyFolderIcon.heightAnchor.constraint(equalToConstant: 40),

            // Child count badge, bottom-right corner
            childCountBadge.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor, constant: -6),
            childCountBadge.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor, constant: -6),
            childCountBadge.heightAnchor.constraint(equalToConstant: 20),
            childCountBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])

        setupOverlayButton()
    }

    // MARK: - Hover overlay

    private func setupOverlayButton() {
        overlayOpenButton.configure(
            symbolName: "folder.fill",
            accessibilityDescription: String(localized: "Edit group contents"),
            iconXNudge: 0
        )
        overlayOpenButton.onClick = { [weak self] in self?.actionHandler?(.openGroupEditor) }
        thumbnailContainer.addSubview(overlayOpenButton)
        NSLayoutConstraint.activate([
            overlayOpenButton.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
            overlayOpenButton.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = thumbnailTrackingArea {
            thumbnailContainer.removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: thumbnailContainer.bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        thumbnailContainer.addTrackingArea(area)
        thumbnailTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        overlayOpenButton.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        overlayOpenButton.setHovered(false)
    }

    // MARK: - Content area

    private func setupContentArea() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        // Tight row spacing keeps the card at the original 170pt height even
        // with the extra metadata and status rows. `applyCompactLayout` halves
        // it again for the 120pt compact card. The codec preset shares the
        // status row's trailing edge instead of taking its own row.
        contentStack.spacing = 4
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        setupTopRow()
        setupMetaRow()
        setupStatusRow()
        setupButtonsRow()
        setupProgressBar()
        setupUploadRow()

        // Visual order: name + concat output → clip count/duration → status
        // capsule + preset popup → progress bar → buttons row → upload summary.
        // Mirrors VideoFileCellView's vertical flow so single items and group
        // headers read as siblings.
        contentStack.addArrangedSubview(topRow)
        contentStack.addArrangedSubview(metaRow)
        contentStack.addArrangedSubview(statusRow)
        contentStack.addArrangedSubview(progressBar)
        contentStack.addArrangedSubview(buttonsRow)
        contentStack.addArrangedSubview(uploadRow)

        // Wrap contentStack in a padded container, matching VideoFileCellView's right column.
        let contentPadding = NSView()
        contentPadding.translatesAutoresizingMaskIntoConstraints = false
        contentPadding.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentPadding.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: contentPadding.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentPadding.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentPadding.bottomAnchor, constant: -8),

            topRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            metaRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            metaRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            statusRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            buttonsRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            buttonsRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            progressBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            uploadRow.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            uploadRow.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])

        mainHStack.addArrangedSubview(contentPadding)
        contentPadding.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func setupTopRow() {
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        folderIcon.image = GroupSymbol.folderFill
        folderIcon.contentTintColor = .systemBlue
        folderIcon.imageScaling = .scaleProportionallyUpOrDown
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        folderIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.placeholderString = String(localized: "Group name")
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.textColor = .labelColor
        nameField.delegate = self
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.usesSingleLineMode = true
        nameField.cell?.sendsActionOnEndEditing = true
        nameField.target = self
        nameField.action = #selector(nameFieldCommitted)
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        clipCountLabel.font = .systemFont(ofSize: 11)
        clipCountLabel.textColor = .secondaryLabelColor
        clipCountLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clipCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Concat output icons (finder / copy path / drag / warning) match the
        // natural symbol size used by VideoFileCellView's `finderButton`,
        // `copyPathButton`, and `dragButton` — those buttons have no explicit
        // width/height, so the encoding-group versions follow suit instead of
        // the larger 28pt action-button footprint.
        configureNaturalIconButton(concatOutputButton, symbolName: "magnifyingglass.circle.fill", tint: .systemBlue, action: #selector(concatOutputFinderClicked))
        concatOutputButton.setAccessibilityIdentifier("group.output")
        concatOutputButton.toolTip = String(localized: "Show merged output in Finder")

        configureNaturalIconButton(concatCopyPathButton, symbolName: "doc.on.doc.fill", tint: .systemBlue, action: #selector(concatCopyPathClicked))
        concatCopyPathButton.toolTip = String(localized: "Copy merged output file path")

        concatDragButton.image = GroupSymbol.dragHandle
        concatDragButton.contentTintColor = .systemBlue
        concatDragButton.toolTip = String(localized: "Drag to share the merged file")
        concatDragButton.translatesAutoresizingMaskIntoConstraints = false
        concatDragButton.setContentHuggingPriority(.required, for: .horizontal)

        configureNaturalIconButton(concatWarningButton, symbolName: "magnifyingglass.circle.fill", tint: .systemOrange, action: #selector(concatWarningClicked))
        concatWarningButton.toolTip = String(localized: "Output file already exists and will be overwritten. Click to show in Finder.")

        configureActionButton(addFilesButton, symbolName: "plus", tint: .secondaryLabelColor, action: #selector(addFilesClicked))
        addFilesButton.toolTip = String(localized: "Add files to group")

        // Opens the standalone editor window where reorder/remove/extract happen.
        // Keeps the main queue focused on high-level queue manipulation.
        configureActionButton(editButton, symbolName: "square.and.pencil", tint: .systemBlue, action: #selector(editClicked))
        editButton.setAccessibilityIdentifier("group.edit")
        editButton.toolTip = String(localized: "Edit group contents (reorder, remove, rename)")

        configureActionButton(resetButton, symbolName: "arrow.counterclockwise.circle.fill", tint: .systemBlue, action: #selector(resetClicked))
        resetButton.toolTip = String(localized: "Reset all items in group")

        configureActionButton(deleteButton, symbolName: "xmark.circle.fill", tint: .systemRed, action: #selector(deleteClicked))
        deleteButton.toolTip = String(localized: "Delete group")

        topRow.addArrangedSubview(folderIcon)
        topRow.addArrangedSubview(nameField)
        topRow.addArrangedSubview(concatOutputButton)
        topRow.addArrangedSubview(concatCopyPathButton)
        topRow.addArrangedSubview(concatDragButton)
        topRow.addArrangedSubview(concatWarningButton)
    }

    private func setupMetaRow() {
        // Mirrors VideoFileCellView's metadata row: clip count + total duration
        // sit directly under the editable name field instead of being squeezed
        // into the top-row alongside the action buttons.
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 6
        metaRow.distribution = .fill
        metaRow.translatesAutoresizingMaskIntoConstraints = false
        metaRow.addArrangedSubview(clipCountLabel)
    }

    private func setupStatusRow() {
        // Status capsule + summary text — same shape as a single-item card so
        // groups read at a glance ("WAITING", "ENCODING 35%", "DONE"). The
        // codec preset popup shares the row's trailing edge so we can keep
        // the card at its original 170pt height.
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        statusRow.distribution = .fill
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        setupStatusCapsule()

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.drawsBackground = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // Hugging priority must be lower than the trailing spacer's so empty
        // status text doesn't stretch the capsule across the row — the spacer
        // absorbs the slack and pushes the preset popup to the trailing edge.
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        presetPopup.translatesAutoresizingMaskIntoConstraints = false
        presetPopup.controlSize = .small
        presetPopup.font = .systemFont(ofSize: 11)
        presetPopup.target = self
        presetPopup.action = #selector(presetSelected(_:))
        let width = presetPopup.widthAnchor.constraint(equalToConstant: 220)
        width.isActive = true
        presetWidthConstraint = width

        let trailingSpacer = NSView()
        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusRow.addArrangedSubview(statusCapsule)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(trailingSpacer)
        statusRow.addArrangedSubview(presetPopup)
    }

    private func setupStatusCapsule() {
        statusCapsule.wantsLayer = true
        statusCapsule.layer?.cornerRadius = VideoFileCellView.normalCapsuleHeight / 2
        statusCapsule.layer?.borderWidth = 1.2
        statusCapsule.translatesAutoresizingMaskIntoConstraints = false

        capsuleIcon.translatesAutoresizingMaskIntoConstraints = false
        capsuleIcon.contentTintColor = .secondaryLabelColor
        statusCapsule.addSubview(capsuleIcon)

        capsuleLabel.font = .systemFont(ofSize: 9, weight: .bold)
        capsuleLabel.textColor = .secondaryLabelColor
        capsuleLabel.isBezeled = false
        capsuleLabel.isEditable = false
        capsuleLabel.isSelectable = false
        capsuleLabel.drawsBackground = false
        capsuleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusCapsule.addSubview(capsuleLabel)

        let capsuleHeightConstraint = statusCapsule.heightAnchor.constraint(equalToConstant: VideoFileCellView.normalCapsuleHeight)
        self.capsuleHeightConstraint = capsuleHeightConstraint
        NSLayoutConstraint.activate([
            capsuleIcon.leadingAnchor.constraint(equalTo: statusCapsule.leadingAnchor, constant: 7),
            capsuleIcon.centerYAnchor.constraint(equalTo: statusCapsule.centerYAnchor),
            capsuleIcon.widthAnchor.constraint(equalToConstant: 10),
            capsuleIcon.heightAnchor.constraint(equalToConstant: 10),

            capsuleLabel.leadingAnchor.constraint(equalTo: capsuleIcon.trailingAnchor, constant: 3),
            capsuleLabel.trailingAnchor.constraint(equalTo: statusCapsule.trailingAnchor, constant: -8),
            capsuleLabel.centerYAnchor.constraint(equalTo: statusCapsule.centerYAnchor),

            capsuleHeightConstraint,
        ])

        statusCapsule.setContentHuggingPriority(.required, for: .horizontal)
        statusCapsule.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func setupButtonsRow() {
        // Mirrors VideoFileCellView's buttons row: leading-aligned actions
        // (add/edit) sit next to the toggles, the trailing edge holds only
        // the destructive reset/delete pair behind a divider, and a flexible
        // spacer keeps them pinned right.
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 6
        buttonsRow.distribution = .fill
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false

        togglesStack.orientation = .horizontal
        togglesStack.alignment = .centerY
        togglesStack.spacing = 4
        togglesStack.translatesAutoresizingMaskIntoConstraints = false

        configureToggleButton(sequentialToggle, onSymbol: GroupSymbol.numberCircleFill, offSymbol: GroupSymbol.numberCircle, action: #selector(sequentialClicked))
        configureToggleButton(concatToggle, onSymbol: GroupSymbol.concat, offSymbol: GroupSymbol.concat, action: #selector(concatClicked))
        configureToggleButton(encodeButton, onSymbol: VideoFileCellView.Symbol.playFill, offSymbol: VideoFileCellView.Symbol.playFill, action: #selector(encodeClicked))
        encodeButton.contentTintColor = .secondaryLabelColor
        encodeButton.toolTip = String(localized: "Option-click to encode this group immediately")
        configureToggleButton(transcriptionToggle, onSymbol: VideoFileCellView.Symbol.captionsBubbleFill, offSymbol: VideoFileCellView.Symbol.captionsBubble, action: #selector(transcriptionClicked))
        configureToggleButton(analyticsToggle, onSymbol: VideoFileCellView.Symbol.chartAscending, offSymbol: VideoFileCellView.Symbol.chartBase, action: #selector(analyticsClicked))
        configureToggleButton(uploadToggle, onSymbol: VideoFileCellView.Symbol.cloudArrowUpFill, offSymbol: VideoFileCellView.Symbol.cloudArrowUp, action: #selector(uploadClicked))

        // togglesStack mirrors VideoFileCellView's buttons row:
        // [group-specific] | divider | encode | divider | [post-processing]
        // Group-specific toggles (sequential naming, concat) are unique to
        // group cards. The encode button + post-processing trio (transcribe,
        // analytics, upload) match the order on single-item cards so the two
        // card types read as peers.
        for divider in [groupSpecificDivider, encodeDivider] {
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false
            let heightConstraint = divider.heightAnchor.constraint(equalToConstant: VideoFileCellView.normalDividerHeight)
            NSLayoutConstraint.activate([
                divider.widthAnchor.constraint(equalToConstant: 2),
                heightConstraint,
            ])
            dividerHeightConstraints.append(heightConstraint)
        }

        togglesStack.addArrangedSubview(sequentialToggle)
        togglesStack.addArrangedSubview(concatToggle)
        togglesStack.addArrangedSubview(groupSpecificDivider)
        togglesStack.addArrangedSubview(encodeButton)
        togglesStack.addArrangedSubview(encodeDivider)
        togglesStack.addArrangedSubview(transcriptionToggle)
        togglesStack.addArrangedSubview(analyticsToggle)
        togglesStack.addArrangedSubview(uploadToggle)

        // Vertical separator between toggles and destructive actions, mirroring
        // the divider VideoFileCellView uses for the same purpose.
        actionButtonDivider.wantsLayer = true
        actionButtonDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        actionButtonDivider.translatesAutoresizingMaskIntoConstraints = false
        let actionDividerHeight = actionButtonDivider.heightAnchor.constraint(equalToConstant: VideoFileCellView.normalDividerHeight)
        NSLayoutConstraint.activate([
            actionButtonDivider.widthAnchor.constraint(equalToConstant: 2),
            actionDividerHeight,
        ])
        dividerHeightConstraints.append(actionDividerHeight)

        let leadingActions = NSStackView()
        leadingActions.orientation = .horizontal
        leadingActions.alignment = .centerY
        leadingActions.spacing = 4
        leadingActions.translatesAutoresizingMaskIntoConstraints = false
        leadingActions.addArrangedSubview(addFilesButton)
        leadingActions.addArrangedSubview(editButton)

        let trailingActions = NSStackView()
        trailingActions.orientation = .horizontal
        trailingActions.alignment = .centerY
        trailingActions.spacing = 4
        trailingActions.translatesAutoresizingMaskIntoConstraints = false
        trailingActions.addArrangedSubview(resetButton)
        trailingActions.addArrangedSubview(deleteButton)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        buttonsRow.addArrangedSubview(leadingActions)
        buttonsRow.addArrangedSubview(togglesStack)
        buttonsRow.addArrangedSubview(spacer)
        buttonsRow.addArrangedSubview(actionButtonDivider)
        buttonsRow.addArrangedSubview(trailingActions)
    }

    private func setupProgressBar() {
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        progressBar.isHidden = true
    }

    private func setupUploadRow() {
        uploadRow.orientation = .horizontal
        uploadRow.alignment = .centerY
        uploadRow.spacing = 6
        uploadRow.translatesAutoresizingMaskIntoConstraints = false

        uploadIcon.imageScaling = .scaleProportionallyUpOrDown
        uploadIcon.translatesAutoresizingMaskIntoConstraints = false
        uploadIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        uploadIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        uploadLabel.font = .systemFont(ofSize: 11)
        uploadLabel.textColor = .secondaryLabelColor

        uploadProgress.style = .bar
        uploadProgress.isIndeterminate = false
        uploadProgress.minValue = 0
        uploadProgress.maxValue = 1
        uploadProgress.controlSize = .small
        uploadProgress.translatesAutoresizingMaskIntoConstraints = false
        uploadProgress.heightAnchor.constraint(equalToConstant: 4).isActive = true
        uploadProgress.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cancelUploadButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        cancelUploadButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        cancelUploadButton.bezelStyle = .inline
        cancelUploadButton.isBordered = false
        cancelUploadButton.imagePosition = .imageOnly
        cancelUploadButton.contentTintColor = .systemRed
        cancelUploadButton.target = self
        cancelUploadButton.action = #selector(cancelUploadClicked)
        cancelUploadButton.toolTip = String(localized: "Cancel upload")
        cancelUploadButton.translatesAutoresizingMaskIntoConstraints = false
        cancelUploadButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelUploadButton.isHidden = true

        uploadRow.addArrangedSubview(uploadIcon)
        uploadRow.addArrangedSubview(uploadLabel)
        uploadRow.addArrangedSubview(uploadProgress)
        uploadRow.addArrangedSubview(cancelUploadButton)
        uploadRow.isHidden = true
    }

    /// Compact icon used for the concat output buttons (Finder / copy path /
    /// warning) — matches VideoFileCellView's `finderButton` / `copyPathButton`
    /// which use the SF Symbol's natural intrinsic size with no explicit
    /// width/height, instead of the larger 28pt action-button footprint.
    private func configureNaturalIconButton(_ button: NSButton, symbolName: String, tint: NSColor, action: Selector) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = tint
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// Action-button styling that matches `VideoFileCellView.setupActionButton` —
    /// shared sizing constants so group cards read as peers of single-item cards
    /// and shrink in lockstep when compact mode is enabled.
    private func configureActionButton(_ button: NSButton, symbolName: String, tint: NSColor, action: Selector) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: VideoFileCellView.normalSymbolPointSize, weight: .regular)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = tint
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: VideoFileCellView.normalButtonSize)
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: VideoFileCellView.normalButtonSize)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        buttonSizeConstraints.append(widthConstraint)
        buttonSizeConstraints.append(heightConstraint)
        compactSizedButtons.append(button)
    }

    /// Matches `VideoFileCellView.setupToggleButton` — same circular-ring
    /// scaffolding so the active-processing indicator stays a true circle
    /// and shrinks together when compact mode is enabled.
    private func configureToggleButton(_ button: NSButton, onSymbol: NSImage?, offSymbol: NSImage?, action: Selector) {
        button.image = offSymbol
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: VideoFileCellView.normalSymbolPointSize, weight: .regular)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = VideoFileCellView.normalButtonSize / 2
        button.layer?.borderWidth = 2
        button.layer?.borderColor = NSColor.clear.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: VideoFileCellView.normalButtonSize)
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: VideoFileCellView.normalButtonSize)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        buttonSizeConstraints.append(widthConstraint)
        buttonSizeConstraints.append(heightConstraint)
        compactSizedButtons.append(button)
    }

    // MARK: - Configure

    func configure(with config: EncodingGroupCellConfiguration, actionHandler: @escaping (CellAction) -> Void) {
        let prev = self.currentConfig
        self.actionHandler = actionHandler

        if let prev, prev == config { return }

        let isFirstConfigure = prev == nil || prev?.groupID != config.groupID
        self.currentGroupID = config.groupID

        if isFirstConfigure || prev?.isCompactMode != config.isCompactMode {
            isCompact = config.isCompactMode
            applyCompactLayout(config.isCompactMode)
            thumbnailWidthConstraint?.constant = thumbnailWidth
        }

        if isFirstConfigure || prev?.name != config.name {
            if nameField.stringValue != config.name {
                nameField.stringValue = config.name
            }
        }

        if isFirstConfigure || prev?.itemCount != config.itemCount || prev?.totalDuration != config.totalDuration {
            clipCountLabel.stringValue = clipCountText(count: config.itemCount, duration: config.totalDuration)
            metaRow.isHidden = config.itemCount == 0 && config.totalDuration.isEmpty
        }

        if isFirstConfigure
            || prev?.status != config.status
            || prev?.progress != config.progress
            || prev?.itemCount != config.itemCount
            || prev?.isCompactMode != config.isCompactMode {
            updateStatusCapsuleAndLabel(config: config)
        }

        if isFirstConfigure
            || prev?.concatOutputURL != config.concatOutputURL
            || prev?.concatOutputAlreadyExists != config.concatOutputAlreadyExists
            || prev?.concatOutputExistingURL != config.concatOutputExistingURL {
            updateConcatOutputIcons(config: config)
        }

        if isFirstConfigure
            || prev?.globalPreset != config.globalPreset
            || prev?.groupPreset != config.groupPreset {
            rebuildPresetPopup(config: config)
        }

        if isFirstConfigure
            || prev?.sequentialNamingEnabled != config.sequentialNamingEnabled
            || prev?.name != config.name {
            updateSequentialToggle(config: config)
        }

        if isFirstConfigure || prev?.concatEnabled != config.concatEnabled {
            updateConcatToggle(config: config)
        }

        if isFirstConfigure
            || prev?.uploadEnabled != config.uploadEnabled
            || prev?.isUploadConfigured != config.isUploadConfigured {
            updateUploadToggle(config: config)
        }

        if isFirstConfigure || prev?.transcriptionEnabled != config.transcriptionEnabled {
            updateTranscriptionToggle(config: config)
        }

        if isFirstConfigure || prev?.analyticsEnabled != config.analyticsEnabled {
            updateAnalyticsToggle(config: config)
        }

        if isFirstConfigure
            || prev?.status != config.status
            || prev?.progress != config.progress
            || prev?.isCompactMode != config.isCompactMode {
            updateProgressBar(config: config)
        }

        if isFirstConfigure
            || prev?.status != config.status
            || prev?.itemCount != config.itemCount {
            updateEncodeButton(config: config)
        }

        if isFirstConfigure
            || prev?.uploadSummary != config.uploadSummary
            || prev?.isCompactMode != config.isCompactMode {
            updateUploadSummary(config: config)
        }

        if isFirstConfigure
            || prev?.isSelected != config.isSelected
            || prev?.isDropTargetHover != config.isDropTargetHover {
            updateSelectionBorder(isSelected: config.isSelected, isDropTargetHover: config.isDropTargetHover)
        }

        if isFirstConfigure || prev?.stackedChildren != config.stackedChildren {
            updateStackedThumbnails(config: config)
        }

        if isFirstConfigure || prev?.itemCount != config.itemCount {
            updateChildCountBadge(count: config.itemCount)
        }

        // Context menu — rebuild when states that change item enablement flip.
        if isFirstConfigure
            || prev?.status != config.status
            || prev?.concatOutputURL != config.concatOutputURL
            || prev?.itemCount != config.itemCount {
            self.menu = buildContextMenu(config: config)
        }

        self.currentConfig = config
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastCardBoundsSize = .zero
        lastThumbBoundsSize = .zero
    }

    /// Called by the coordinator when a child's thumbnail data finishes decoding
    /// off-main. Updates the stacked-preview slots that reference that child.
    func applyDecodedChildThumbnail(_ image: NSImage?, forItemID itemID: UUID) {
        guard let config = currentConfig else { return }
        for (slot, child) in config.stackedChildren.prefix(3).enumerated() where child.itemID == itemID {
            switch slot {
            case 0: stackedThumb3.image = image
            case 1: stackedThumb2.image = image
            case 2: stackedThumb1.image = image
            default: break
            }
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let cardBounds = cardView.bounds
        if cardBounds.size != lastCardBoundsSize {
            let path = CGPath(roundedRect: cardBounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
            selectionBorderLayer.path = path
            selectionBorderLayer.frame = cardBounds
            lastCardBoundsSize = cardBounds.size
        }

        let thumbBounds = thumbnailContainer.bounds
        if thumbBounds.size != lastThumbBoundsSize {
            let path = CGPath(roundedRect: thumbBounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
            thumbnailBorderLayer.path = path
            thumbnailBorderLayer.frame = thumbBounds
            lastThumbBoundsSize = thumbBounds.size
        }
    }

    private func applyCompactLayout(_ compact: Bool) {
        contentStack.spacing = compact ? 2 : 4
        presetWidthConstraint?.constant = compact ? 140 : 220
        let baseHeight = (compact ? Self.baseCompactRowHeight : Self.baseRowHeight) - 12
        thumbnailHeightConstraint?.constant = baseHeight
        checkerHeightConstraint?.constant = baseHeight

        // Shrink toggles, action buttons, dividers, and the status capsule in
        // lockstep with VideoFileCellView so the two card types stay paired.
        let size = buttonSize
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: buttonSymbolPointSize, weight: .regular)
        let cornerRadius = buttonCornerRadius
        for constraint in buttonSizeConstraints {
            constraint.constant = size
        }
        for button in compactSizedButtons {
            button.symbolConfiguration = symbolConfig
            button.layer?.cornerRadius = cornerRadius
        }
        for constraint in dividerHeightConstraints {
            constraint.constant = dividerHeight
        }
        capsuleHeightConstraint?.constant = capsuleHeight
        statusCapsule.layer?.cornerRadius = capsuleHeight / 2
    }

    // MARK: - Sub-updates

    private func clipCountText(count: Int, duration: String) -> String {
        guard count > 0 else {
            return String(localized: "Empty group",
                          comment: "Shown in place of a clip count when the group has no items.")
        }
        let clipText = String(
            localized: "\(count) clips",
            comment: "Clip-count label on the group header. Supports pluralization."
        )
        if duration.isEmpty { return clipText }
        return "\(clipText) · \(duration)"
    }

    private func updateConcatOutputIcons(config: EncodingGroupCellConfiguration) {
        let showDone = config.concatOutputURL != nil
        concatOutputButton.isHidden = !showDone
        concatCopyPathButton.isHidden = !showDone
        concatDragButton.isHidden = !showDone
        concatDragButton.fileURL = config.concatOutputURL

        let showWarning = config.concatOutputAlreadyExists
        concatWarningButton.isHidden = !showWarning
    }

    private func rebuildPresetPopup(config: EncodingGroupCellConfiguration) {
        let manager = PresetManager.shared
        presetPopup.removeAllItems()

        let globalLabel = String(
            localized: "Global (\(manager.displayName(for: config.globalPreset)))",
            comment: "Menu item for the default/global preset choice. Placeholder is the currently-selected global preset's display name."
        )
        let globalItem = NSMenuItem(title: globalLabel, action: nil, keyEquivalent: "")
        globalItem.representedObject = nil as ExportPreset?
        presetPopup.menu?.addItem(globalItem)
        presetPopup.menu?.addItem(.separator())

        for preset in manager.visiblePresets {
            let item = NSMenuItem(title: manager.displayName(for: preset), action: nil, keyEquivalent: "")
            item.representedObject = preset
            presetPopup.menu?.addItem(item)
        }

        if let selected = config.groupPreset,
           let item = presetPopup.menu?.items.first(where: { ($0.representedObject as? ExportPreset) == selected }) {
            presetPopup.select(item)
        } else {
            presetPopup.selectItem(at: 0)
        }
    }

    private func updateSequentialToggle(config: EncodingGroupCellConfiguration) {
        // Mutual exclusion: sequential naming is disabled while merge is on.
        // The two settings can't be on simultaneously — see toggle handlers in
        // VideoQueueTableView and the Encoding tab in Settings.
        let blockedByMerge = config.concatEnabled && !config.sequentialNamingEnabled
        sequentialToggle.image = config.sequentialNamingEnabled ? GroupSymbol.numberCircleFill : GroupSymbol.numberCircle
        sequentialToggle.contentTintColor = config.sequentialNamingEnabled ? .systemBlue : .secondaryLabelColor
        sequentialToggle.isEnabled = !blockedByMerge
        sequentialToggle.alphaValue = blockedByMerge ? 0.4 : 1.0
        sequentialToggle.toolTip = blockedByMerge
            ? String(localized: "Disabled while Merge is on — turn off Merge to enable sequential naming")
            : (config.sequentialNamingEnabled
                ? String(localized: "Sequential naming enabled — files named \(config.name)_001, \(config.name)_002, …",
                         comment: "Tooltip shown when sequential naming is enabled. Placeholder is the current group name.")
                : String(localized: "Enable sequential naming using group name"))
    }

    private func updateConcatToggle(config: EncodingGroupCellConfiguration) {
        // Mutual exclusion mirror of updateSequentialToggle — merge is disabled
        // while sequential naming is on.
        let blockedBySequential = config.sequentialNamingEnabled && !config.concatEnabled
        concatToggle.image = GroupSymbol.concat
        concatToggle.contentTintColor = config.concatEnabled ? .systemBlue : .secondaryLabelColor
        concatToggle.isEnabled = !blockedBySequential
        concatToggle.alphaValue = blockedBySequential ? 0.4 : 1.0
        concatToggle.toolTip = blockedBySequential
            ? String(localized: "Disabled while Sequential naming is on — turn it off to enable Merge")
            : (config.concatEnabled
                ? String(localized: "Concat enabled — clips will be merged into one file")
                : String(localized: "Enable concat to merge clips into one file"))
    }

    private func updateUploadToggle(config: EncodingGroupCellConfiguration) {
        uploadToggle.image = config.uploadEnabled
            ? VideoFileCellView.Symbol.cloudArrowUpFill
            : VideoFileCellView.Symbol.cloudArrowUp
        uploadToggle.contentTintColor = config.uploadEnabled ? .systemBlue : .secondaryLabelColor
        uploadToggle.isEnabled = config.isUploadConfigured
        uploadToggle.toolTip = config.isUploadConfigured
            ? (config.uploadEnabled
                ? String(localized: "Upload enabled — files will upload after encoding")
                : String(localized: "Enable upload after encoding"))
            : String(localized: "Configure upload in Settings → Upload")
    }

    private func updateTranscriptionToggle(config: EncodingGroupCellConfiguration) {
        transcriptionToggle.image = config.transcriptionEnabled
            ? VideoFileCellView.Symbol.captionsBubbleFill
            : VideoFileCellView.Symbol.captionsBubble
        transcriptionToggle.contentTintColor = config.transcriptionEnabled ? .systemGreen : .secondaryLabelColor
        transcriptionToggle.toolTip = config.transcriptionEnabled
            ? String(localized: "Transcription enabled — SRT will be created after encoding")
            : String(localized: "Enable transcription for subtitle generation")
    }

    private func updateAnalyticsToggle(config: EncodingGroupCellConfiguration) {
        analyticsToggle.image = config.analyticsEnabled
            ? VideoFileCellView.Symbol.chartAscending
            : VideoFileCellView.Symbol.chartBase
        analyticsToggle.contentTintColor = config.analyticsEnabled ? .systemCyan : .secondaryLabelColor
        analyticsToggle.toolTip = config.analyticsEnabled
            ? String(localized: "Quality analytics enabled — will run after encoding")
            : String(localized: "Enable quality analytics after encoding")
    }

    private func updateEncodeButton(config: EncodingGroupCellConfiguration) {
        let isEncoding = config.status == .converting
        let hasItems = config.itemCount > 0
        encodeButton.image = VideoFileCellView.Symbol.playFill
        encodeButton.contentTintColor = isEncoding
            ? .systemGreen
            : .systemGreen.withAlphaComponent(hasItems ? 0.5 : 0.25)
        encodeButton.isEnabled = hasItems && (config.status == .waiting || config.status == .done || config.status == .failed)
        encodeButton.toolTip = isEncoding
            ? String(localized: "Encoding in progress")
            : String(localized: "Option-click to encode this group immediately")
    }

    private func updateProgressBar(config: EncodingGroupCellConfiguration) {
        let active = config.status == .converting && !config.isCompactMode
        progressBar.isHidden = !active
        if active {
            progressBar.doubleValue = config.progress
        }
    }

    /// Mirrors VideoFileCellView's status capsule. Stays visible in compact
    /// mode now that the row also hosts the preset popup and status label —
    /// the smaller compact button sizes free up enough vertical space for
    /// the row to remain.
    private func updateStatusCapsuleAndLabel(config: EncodingGroupCellConfiguration) {
        statusRow.isHidden = false

        let (text, icon, color): (String, String, NSColor) = {
            switch config.status {
            case .waiting:    return ("WAITING", "clock", .secondaryLabelColor)
            case .converting: return ("ENCODING", "arrow.trianglehead.2.clockwise", .systemBlue)
            case .done:       return ("DONE", "checkmark.circle", .systemGreen)
            case .failed:     return ("FAILED", "exclamationmark.circle", .systemRed)
            case .cancelled:  return ("CANCELLED", "xmark.circle", .secondaryLabelColor)
            @unknown default: return ("", "questionmark", .secondaryLabelColor)
            }
        }()

        capsuleLabel.stringValue = text
        capsuleLabel.textColor = color
        capsuleIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        capsuleIcon.contentTintColor = color
        statusCapsule.layer?.borderColor = color.withAlphaComponent(0.6).cgColor

        statusLabel.stringValue = statusSummary(config: config)
        statusLabel.textColor = .secondaryLabelColor
    }

    /// Right-of-capsule summary text — overall progress while encoding, plus a
    /// running "done/total" so groups feel as informative as a single item's
    /// status row.
    private func statusSummary(config: EncodingGroupCellConfiguration) -> String {
        switch config.status {
        case .converting:
            let pct = Int(config.progress * 100)
            return "\(pct)%"
        case .waiting, .done, .failed, .cancelled:
            return ""
        @unknown default:
            return ""
        }
    }

    private func updateUploadSummary(config: EncodingGroupCellConfiguration) {
        if config.isCompactMode {
            uploadRow.isHidden = true
            cancelUploadButton.isHidden = true
            return
        }
        switch config.uploadSummary {
        case .hidden:
            uploadRow.isHidden = true
            cancelUploadButton.isHidden = true
        case .uploaded(let count, let total):
            uploadRow.isHidden = false
            uploadIcon.image = GroupSymbol.uploadedCheck
            uploadIcon.contentTintColor = .systemGreen
            uploadLabel.stringValue = String(
                localized: "Uploaded \(count)/\(total)",
                comment: "Group header upload status when all uploads have finished. First placeholder is the number uploaded, second is the total."
            )
            uploadProgress.isHidden = true
            cancelUploadButton.isHidden = true
        case .failed(let count, let total):
            uploadRow.isHidden = false
            uploadIcon.image = GroupSymbol.uploadFailed
            uploadIcon.contentTintColor = .systemRed
            uploadLabel.stringValue = String(
                localized: "Upload failed \(count)/\(total)",
                comment: "Group header upload status when uploads have failed. First placeholder is the number failed, second is the total."
            )
            uploadProgress.isHidden = true
            cancelUploadButton.isHidden = true
        case .uploading(let completed, let total, let progress, let speed):
            uploadRow.isHidden = false
            uploadIcon.image = VideoFileCellView.Symbol.cloudArrowUp
            uploadIcon.contentTintColor = .systemOrange
            let speedText = speed.map { " · \($0)" } ?? ""
            uploadLabel.stringValue = String(
                localized: "Uploading \(completed + 1)/\(total)\(speedText)",
                comment: "Group header upload status while actively uploading. Placeholders are the current item index, total, and optional speed text."
            )
            uploadProgress.isHidden = false
            uploadProgress.doubleValue = progress
            cancelUploadButton.isHidden = false
        case .pending(let uploaded, let total):
            uploadRow.isHidden = false
            uploadIcon.image = GroupSymbol.uploadPending
            uploadIcon.contentTintColor = .systemOrange
            uploadLabel.stringValue = String(
                localized: "Upload pending \(uploaded)/\(total)",
                comment: "Group header upload status when uploads are queued but not yet started."
            )
            uploadProgress.isHidden = false
            uploadProgress.doubleValue = total > 0 ? Double(uploaded) / Double(total) : 0
            cancelUploadButton.isHidden = false
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        applyCardBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardBackground()
        // Re-run with current selection state so we don't clobber an active blue stroke
        // when the user toggles theme on a selected/drop-hover cell.
        if let config = currentConfig {
            updateSelectionBorder(isSelected: config.isSelected, isDropTargetHover: config.isDropTargetHover)
        } else {
            applyRestingSelectionStroke()
        }
        cardView.needsDisplay = true
    }

    /// Resolves the dynamic card background against the current effective appearance and
    /// pushes the result onto `cardView.layer.backgroundColor`. `cgColor` snapshots the resolved
    /// color at access time, so we re-run this whenever appearance changes.
    private func applyCardBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cardView.layer?.backgroundColor = NSColor.queueGroupHeaderCardBackground.cgColor
        }
    }

    /// Resolves the resting (idle) dashed selection stroke against the current appearance.
    /// Only assigns when the selection is not in selected/drop-hover state — those cases handle
    /// their own stroke colors with `.systemBlue`.
    private func applyRestingSelectionStroke() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionBorderLayer.strokeColor = NSColor.queueGroupHeaderRestingStroke.cgColor
        }
    }

    private func updateSelectionBorder(isSelected: Bool, isDropTargetHover: Bool) {
        // Drop-target hover wins over selection so the user can see exactly where a
        // dragged item will land. Uses a bright, thick, solid blue — distinct from
        // the dimmer selection border so the two states read differently.
        if isDropTargetHover {
            selectionBorderLayer.strokeColor = NSColor.systemBlue.cgColor
            selectionBorderLayer.lineWidth = 3
            selectionBorderLayer.lineDashPattern = nil
        } else if isSelected {
            selectionBorderLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
            selectionBorderLayer.lineWidth = 2.5
            selectionBorderLayer.lineDashPattern = nil
        } else {
            applyRestingSelectionStroke()
            selectionBorderLayer.lineWidth = 1.2
            selectionBorderLayer.lineDashPattern = [6, 4]
        }
    }

    private func updateStackedThumbnails(config: EncodingGroupCellConfiguration) {
        let children = Array(config.stackedChildren.prefix(3))

        // Reset all three slots first.
        stackedThumb1.image = nil
        stackedThumb2.image = nil
        stackedThumb3.image = nil

        let visibleCount = children.count
        stackedThumb1.isHidden = visibleCount < 3
        stackedThumb2.isHidden = visibleCount < 2
        stackedThumb3.isHidden = visibleCount < 1
        emptyFolderIcon.isHidden = visibleCount > 0

        // Front → back mapping: first child goes to front (stackedThumb3), next to middle, last to back.
        for (slot, child) in children.enumerated() {
            let cached = ThumbnailCache.shared[child.itemID]
            let view: NSImageView
            switch slot {
            case 0: view = stackedThumb3
            case 1: view = stackedThumb2
            case 2: view = stackedThumb1
            default: continue
            }
            view.image = cached
        }
    }

    private func updateChildCountBadge(count: Int) {
        childCountBadge.isHidden = count <= 1
        if count > 1 {
            let label = String(
                localized: "\(count) clips",
                comment: "Badge on the stacked thumbnail preview showing how many clips are in the group."
            )
            childCountBadge.stringValue = "  \(label)  "
        }
    }

    // MARK: - Actions

    @objc private func addFilesClicked() { actionHandler?(.addFilesToGroup) }
    @objc private func editClicked() { actionHandler?(.openGroupEditor) }
    @objc private func resetClicked() { actionHandler?(.resetGroup) }
    @objc private func deleteClicked() {
        guard let groupName = currentConfig?.name else {
            actionHandler?(.deleteGroup)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete Group")
        alert.informativeText = String(
            localized: "This will remove the group \"\(groupName)\" and all its items from the queue.",
            comment: "Confirmation text shown before deleting an encoding group. Placeholder is the group's name."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Delete Group"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            actionHandler?(.deleteGroup)
        }
    }

    @objc private func cancelUploadClicked() { actionHandler?(.cancelGroupUpload) }

    @objc private func sequentialClicked() { actionHandler?(.toggleSequentialNaming) }
    @objc private func concatClicked() { actionHandler?(.toggleConcat) }
    @objc private func uploadClicked() {
        let opt = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.toggleGroupUpload(optionPressed: opt))
    }
    @objc private func transcriptionClicked() { actionHandler?(.toggleGroupTranscription) }
    @objc private func analyticsClicked() { actionHandler?(.toggleGroupAnalytics) }
    @objc private func encodeClicked() {
        let opt = NSEvent.modifierFlags.contains(.option)
        actionHandler?(.encodeNow(optionPressed: opt))
    }

    @objc private func presetSelected(_ sender: NSPopUpButton) {
        let preset = sender.selectedItem?.representedObject as? ExportPreset
        actionHandler?(.setGroupPreset(preset))
    }

    @objc private func concatOutputFinderClicked() {
        if let url = currentConfig?.concatOutputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func concatCopyPathClicked() {
        guard let url = currentConfig?.concatOutputURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    @objc private func concatWarningClicked() {
        if let url = currentConfig?.concatOutputExistingURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func nameFieldCommitted() {
        let newName = nameField.stringValue
        if newName != currentConfig?.name {
            actionHandler?(.groupNameChanged(newName))
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        nameFieldCommitted()
    }

    // MARK: - Context Menu

    private func buildContextMenu(config: EncodingGroupCellConfiguration) -> NSMenu {
        let menu = NSMenu()

        let editItem = menu.addItem(withTitle: String(localized: "Edit Group Contents…"), action: #selector(ctxOpenEditor), keyEquivalent: "")
        editItem.target = self

        let addItem = menu.addItem(withTitle: String(localized: "Add Files to Group…"), action: #selector(ctxAddFiles), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = config.status != .converting

        let sortItem = menu.addItem(withTitle: String(localized: "Sort Items"), action: #selector(ctxSort), keyEquivalent: "")
        sortItem.target = self
        sortItem.isEnabled = config.itemCount > 1 && config.status != .converting

        if config.concatOutputURL != nil {
            menu.addItem(.separator())
            let showOutput = menu.addItem(withTitle: String(localized: "Show Merged Output in Finder"), action: #selector(ctxShowConcatOutput), keyEquivalent: "")
            showOutput.target = self
        }

        menu.addItem(.separator())

        let resetItem = menu.addItem(withTitle: String(localized: "Reset Group"), action: #selector(ctxReset), keyEquivalent: "")
        resetItem.target = self
        resetItem.isEnabled = config.status != .converting && config.status != .waiting && config.itemCount > 0

        let deleteItem = menu.addItem(withTitle: String(localized: "Delete Group…"), action: #selector(ctxDelete), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = config.status != .converting

        return menu
    }

    @objc private func ctxOpenEditor() { actionHandler?(.openGroupEditor) }
    @objc private func ctxAddFiles() { actionHandler?(.addFilesToGroup) }
    @objc private func ctxSort() { actionHandler?(.cycleGroupSort) }
    @objc private func ctxReset() { actionHandler?(.resetGroup) }
    @objc private func ctxDelete() { deleteClicked() }
    @objc private func ctxShowConcatOutput() {
        if let url = currentConfig?.concatOutputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
