// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// A single finding. Codes follow libdcp's `VerificationNote` names where one exists, so
/// results can be compared with DCP-o-matic's verifier.
struct DCPValidationIssue: Identifiable, Hashable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        /// Breaks playback or ingest on a compliant server.
        case error
        /// Likely to cause problems or violates SMPTE DCP.
        case warning
        /// Violates the SMPTE RDD 52 (Bv2.1) application profile.
        case bv21
        case info

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .error: return "Error"
            case .warning: return "Warning"
            case .bv21: return "Bv2.1"
            case .info: return "Info"
            }
        }
    }

    let id = UUID()
    let severity: Severity
    let code: String
    let message: String
    let file: String?
}

struct DCPCompositionSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let contentKind: String
    let standard: String
    let reelCount: Int
    let durationFrames: Int
    let editRate: String
    let pictureSize: String?
    let soundChannels: Int?
    let encrypted: Bool
}

struct DCPValidationReport: Sendable {
    let directory: URL
    var issues: [DCPValidationIssue] = []
    var compositions: [DCPCompositionSummary] = []
    var cancelled = false

    func count(_ severity: DCPValidationIssue.Severity) -> Int {
        issues.filter { $0.severity == severity }.count
    }

    var summaryLine: String {
        "\(count(.error)) error(s), \(count(.warning)) warning(s), \(count(.bv21)) Bv2.1 note(s)"
    }

    /// Plain-text rendering for the clipboard or a log.
    var text: String {
        var lines = ["DCP validation: \(directory.path)", summaryLine, ""]
        for composition in compositions {
            lines.append("CPL \(composition.title) [\(composition.standard), \(composition.contentKind)] "
                + "\(composition.reelCount) reel(s), \(composition.durationFrames) frames @ \(composition.editRate)"
                + (composition.pictureSize.map { ", \($0)" } ?? "")
                + (composition.soundChannels.map { ", \($0) ch" } ?? ""))
        }
        if !compositions.isEmpty { lines.append("") }
        for issue in issues.sorted(by: { $0.severity < $1.severity }) {
            lines.append("[\(issue.severity.label)] \(issue.code): \(issue.message)" + (issue.file.map { " (\($0))" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }
}

/// Validates a DCP folder: XML structure, cross-references between ASSETMAP/PKL/CPL,
/// hashes, and the MXF essence itself. The checks mirror the most important ones in
/// libdcp's `verify` (used by DCP-o-matic), implemented natively so no extra tools ship.
enum DCPValidator {
    struct Options: Sendable {
        /// Re-hash every asset against the PKL. Reads the whole package.
        var verifyHashes = true
        /// Number of evenly spaced picture frames whose codestream headers are inspected.
        var codestreamSampleCount = 48

        init(verifyHashes: Bool = true, codestreamSampleCount: Int = 48) {
            self.verifyHashes = verifyHashes
            self.codestreamSampleCount = codestreamSampleCount
        }
    }

    typealias ProgressHandler = @Sendable (_ fraction: Double, _ status: String) -> Void

    static func validate(
        directory: URL,
        options: Options = Options(),
        progress: ProgressHandler? = nil
    ) async -> DCPValidationReport {
        // Detached so the blocking file I/O stays off the caller's executor; cancellation is
        // forwarded explicitly because detached tasks do not inherit it.
        let task = Task.detached(priority: .userInitiated) {
            var run = Run(directory: directory, options: options, progress: progress)
            run.execute()
            return run.report
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Shared helpers

    static let smptePictureRates: Set<Int> = [24, 25, 30, 48, 50, 60]
    static let smpte4KPictureRates: Set<Int> = [24, 25, 30]
    static let validContentKinds: Set<String> = [
        "feature", "trailer", "teaser", "short", "advertisement", "test", "rating", "policy",
        "public-service-announcement", "psa", "transitional", "episode", "highlights", "event",
    ]
    static let containerSizes2K: Set<String> = ["2048x1080", "1998x1080", "2048x858"]
    static let containerSizes4K: Set<String> = ["4096x2160", "3996x2160", "4096x1716"]

    /// Loose RFC 5646 check: primary language subtag plus optional subtags.
    static func isValidLanguageTag(_ tag: String) -> Bool {
        tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) != nil
    }

    static func base64SHA1(of url: URL, isCancelled: () -> Bool, onBytes: (Int64) -> Void) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while true {
            if isCancelled() { return nil }
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 4 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            onBytes(Int64(chunk.count))
        }
        return Data(hasher.finalize()).base64EncodedString()
    }
}

// MARK: - Validation run

private struct Run {
    typealias Severity = DCPValidationIssue.Severity

    let directory: URL
    let options: DCPValidator.Options
    let progress: DCPValidator.ProgressHandler?
    var report: DCPValidationReport

    /// Asset id (lowercased, no urn prefix) → file URL, from the ASSETMAP.
    private var assetPaths: [String: URL] = [:]
    private var packingListIDs: Set<String> = []
    /// Asset id → PKL entry.
    private var pklAssets: [String: PKLAsset] = [:]
    private var pklAnnotations: [String: String] = [:]
    private var cplIDs: [String] = []
    private var isInterop = false

    private struct PKLAsset {
        let hash: String?
        let size: Int64?
        let type: String?
        let pklFile: String
    }

    init(directory: URL, options: DCPValidator.Options, progress: DCPValidator.ProgressHandler?) {
        self.directory = directory
        self.options = options
        self.progress = progress
        self.report = DCPValidationReport(directory: directory)
    }

    private mutating func add(_ severity: Severity, _ code: String, _ message: String, file: String? = nil) {
        report.issues.append(DCPValidationIssue(severity: severity, code: code, message: message, file: file))
    }

    private func status(_ fraction: Double, _ text: String) {
        progress?(min(max(fraction, 0), 1), text)
    }

    private var isCancelled: Bool { Task.isCancelled }

    mutating func execute() {
        status(0, "Reading asset map…")
        guard readAssetMap() else { return }
        status(0.05, "Reading packing lists…")
        readPackingLists()
        if isCancelled { report.cancelled = true; return }

        status(0.1, "Checking compositions…")
        if cplIDs.isEmpty {
            add(.error, "MISSING_CPL", "No Composition Playlist found in the packing list(s).")
        }
        for (index, cplID) in cplIDs.enumerated() {
            guard let url = assetPaths[cplID] else { continue }
            checkCPL(url: url, id: cplID, progressBase: 0.1 + 0.4 * Double(index) / Double(max(cplIDs.count, 1)))
            if isCancelled { report.cancelled = true; return }
        }

        if options.verifyHashes {
            verifyHashes(progressBase: 0.5)
        }
        status(1, report.cancelled ? "Cancelled" : "Done")
    }

    // MARK: ASSETMAP

    private mutating func readAssetMap() -> Bool {
        let fm = FileManager.default
        let smpteURL = directory.appendingPathComponent("ASSETMAP.xml")
        let interopURL = directory.appendingPathComponent("ASSETMAP")
        let assetMapURL: URL
        if fm.fileExists(atPath: smpteURL.path) {
            assetMapURL = smpteURL
        } else if fm.fileExists(atPath: interopURL.path) {
            assetMapURL = interopURL
            isInterop = true
        } else {
            add(.error, "MISSING_ASSETMAP", "No ASSETMAP.xml (SMPTE) or ASSETMAP (Interop) in the selected folder. Choose the DCP folder itself.")
            return false
        }

        guard let root = loadXML(assetMapURL) else { return false }
        if root.uri?.contains("digicine.com") == true {
            isInterop = true
        }
        if isInterop {
            add(.warning, "INVALID_STANDARD", "This is an Interop DCP. Interop is deprecated; SMPTE DCPs are expected by current servers and required for Bv2.1.", file: assetMapURL.lastPathComponent)
        } else if !fm.fileExists(atPath: directory.appendingPathComponent("VOLINDEX.xml").path) {
            add(.info, "MISSING_VOLINDEX", "VOLINDEX.xml is missing. Most servers ignore it, but SMPTE ST 429-9 packages normally include it.")
        }

        var referencedPaths: Set<String> = [assetMapURL.lastPathComponent, "VOLINDEX.xml", "VOLINDEX"]
        for asset in root.child("AssetList")?.children("Asset") ?? [] {
            guard let id = asset.text("Id").map(normalizedID) else {
                add(.error, "INVALID_ASSET_MAP", "An ASSETMAP entry has no Id.", file: assetMapURL.lastPathComponent)
                continue
            }
            if asset.text("PackingList")?.lowercased() == "true" { packingListIDs.insert(id) }
            let chunks = asset.child("ChunkList")?.children("Chunk") ?? []
            if chunks.count != 1 {
                add(.warning, "UNSUPPORTED_CHUNKING", "Asset \(id) is split into \(chunks.count) chunks; multi-volume DCPs are not checked.", file: assetMapURL.lastPathComponent)
            }
            guard let chunk = chunks.first, let rawPath = chunk.text("Path"), !rawPath.isEmpty else {
                add(.error, "EMPTY_ASSET_PATH", "Asset \(id) has no path in the ASSETMAP.", file: assetMapURL.lastPathComponent)
                continue
            }
            let path = rawPath.hasPrefix("file://") ? String(rawPath.dropFirst(7)) : rawPath
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                add(.error, "INVALID_ASSET_MAP_PATH", "Asset path \"\(rawPath)\" must be relative to the DCP folder.", file: assetMapURL.lastPathComponent)
                continue
            }
            let url = directory.appendingPathComponent(path)
            referencedPaths.insert(path)
            guard fm.fileExists(atPath: url.path) else {
                add(.error, "MISSING_ASSET", "\(path) is listed in the ASSETMAP but does not exist.", file: assetMapURL.lastPathComponent)
                continue
            }
            assetPaths[id] = url
            if let length = chunk.text("Length").flatMap(Int64.init), length != fileSize(url) {
                add(.warning, "MISMATCHED_ASSET_MAP_LENGTH", "\(path): ASSETMAP length \(length) bytes, file is \(fileSize(url)) bytes.", file: assetMapURL.lastPathComponent)
            }
        }

        if packingListIDs.isEmpty {
            add(.error, "MISSING_PKL", "The ASSETMAP does not identify a packing list.", file: assetMapURL.lastPathComponent)
        }
        let extras = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !referencedPaths.contains($0) }
        if !extras.isEmpty {
            add(.info, "UNREFERENCED_FILES", "Files not listed in the ASSETMAP (ignored by servers): \(extras.sorted().joined(separator: ", "))")
        }
        return true
    }

    // MARK: PKL

    private mutating func readPackingLists() {
        for id in packingListIDs.sorted() {
            guard let url = assetPaths[id], let root = loadXML(url) else { continue }
            guard root.localName == "PackingList" else {
                add(.error, "INVALID_PKL", "\(url.lastPathComponent) is flagged as a packing list but its root element is <\(root.localName ?? "?")>.", file: url.lastPathComponent)
                continue
            }
            if let annotation = root.text("AnnotationText") { pklAnnotations[url.lastPathComponent] = annotation }
            if root.text("IssueDate").flatMap(parseDate) == nil {
                add(.warning, "INVALID_ISSUE_DATE", "PKL IssueDate is missing or not an ISO 8601 date.", file: url.lastPathComponent)
            }
            for asset in root.child("AssetList")?.children("Asset") ?? [] {
                guard let assetID = asset.text("Id").map(normalizedID) else { continue }
                let type = asset.text("Type")
                pklAssets[assetID] = PKLAsset(
                    hash: asset.text("Hash"),
                    size: asset.text("Size").flatMap(Int64.init),
                    type: type,
                    pklFile: url.lastPathComponent
                )
                guard let assetURL = assetPaths[assetID] else {
                    add(.error, "MISSING_ASSET", "PKL asset \(assetID) is not in the ASSETMAP.", file: url.lastPathComponent)
                    continue
                }
                if let size = pklAssets[assetID]?.size, size != fileSize(assetURL) {
                    add(.error, "MISMATCHED_ASSET_SIZE", "\(assetURL.lastPathComponent): PKL size \(size) bytes, file is \(fileSize(assetURL)) bytes.", file: url.lastPathComponent)
                }
                if asset.text("Hash") == nil {
                    add(.error, "MISSING_HASH", "PKL entry for \(assetURL.lastPathComponent) has no Hash.", file: url.lastPathComponent)
                }
                if let type, type.contains("CPL") || (type == "text/xml" && looksLikeCPL(assetURL)) {
                    cplIDs.append(assetID)
                }
            }
        }
    }

    private func looksLikeCPL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "xml",
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2048)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return head.contains("CompositionPlaylist")
    }

    // MARK: CPL

    private mutating func checkCPL(url: URL, id: String, progressBase: Double) {
        let file = url.lastPathComponent
        guard let root = loadXML(url) else { return }
        guard root.localName == "CompositionPlaylist" else {
            add(.error, "INVALID_CPL", "Root element is <\(root.localName ?? "?")>, expected <CompositionPlaylist>.", file: file)
            return
        }
        let namespace = root.uri ?? ""
        let cplIsInterop = namespace.contains("digicine.com")
        if !cplIsInterop && namespace != "http://www.smpte-ra.org/schemas/429-7/2006/CPL" {
            add(.warning, "INVALID_CPL_NAMESPACE", "Unexpected CPL namespace \"\(namespace)\".", file: file)
        }
        if cplIsInterop != isInterop {
            add(.error, "MISMATCHED_STANDARD", "The CPL and ASSETMAP use different standards (Interop vs SMPTE).", file: file)
        }

        if let cplID = root.text("Id").map(normalizedID), cplID != id {
            add(.error, "MISMATCHED_CPL_ID", "CPL Id \(cplID) does not match its ASSETMAP/PKL id \(id).", file: file)
        }
        let title = root.text("ContentTitleText") ?? ""
        if title.isEmpty {
            add(.error, "MISSING_CPL_CONTENT_TITLE", "ContentTitleText is empty.", file: file)
        }
        let contentKind = root.text("ContentKind") ?? ""
        if !DCPValidator.validContentKinds.contains(contentKind.lowercased()) {
            add(.warning, "INVALID_CONTENT_KIND", "ContentKind \"\(contentKind)\" is not a recognised value.", file: file)
        }
        if root.text("IssueDate").flatMap(parseDate) == nil {
            add(.warning, "INVALID_ISSUE_DATE", "CPL IssueDate is missing or not an ISO 8601 date.", file: file)
        }
        if !cplIsInterop {
            let annotation = root.text("AnnotationText")
            if annotation == nil {
                add(.bv21, "MISSING_CPL_ANNOTATION_TEXT", "CPL has no AnnotationText.", file: file)
            } else if annotation != title {
                add(.bv21, "MISMATCHED_CPL_ANNOTATION_TEXT", "CPL AnnotationText \"\(annotation ?? "")\" differs from ContentTitleText \"\(title)\".", file: file)
            }
            if pklAnnotations.count == 1, cplIDs.count == 1, let pklAnnotation = pklAnnotations.values.first, pklAnnotation != title {
                add(.bv21, "MISMATCHED_PKL_ANNOTATION_TEXT_WITH_CPL", "PKL AnnotationText \"\(pklAnnotation)\" differs from the CPL ContentTitleText.", file: file)
            }
        }
        checkListedInPKL(id: id, url: url)

        let reels = root.child("ReelList")?.children("Reel") ?? []
        if reels.isEmpty {
            add(.error, "MISSING_REELS", "The CPL has no reels.", file: file)
        }

        var totalFrames = 0
        var editRateText = "?"
        var pictureSize: String?
        var soundChannels: Set<Int> = []
        var encrypted = false
        var foundFFOC = false
        var foundLFOC = false
        var compositionMetadata: XMLElement?

        for (reelIndex, reel) in reels.enumerated() {
            let reelLabel = "Reel \(reelIndex + 1)"
            let assets = reel.child("AssetList")?.childElements ?? []
            var durations: [String: Int] = [:]
            var hasPicture = false
            var lfocOffset: Int?

            for asset in assets {
                let name = asset.localName ?? ""
                if name == "CompositionMetadataAsset" {
                    compositionMetadata = asset
                    continue
                }
                let editRate = asset.text("EditRate").flatMap(parseRational)
                let intrinsic = asset.text("IntrinsicDuration").flatMap(Int.init)
                let entryPoint = asset.text("EntryPoint").flatMap(Int.init) ?? 0
                let duration = asset.text("Duration").flatMap(Int.init) ?? intrinsic.map { $0 - entryPoint }
                let assetID = asset.text("Id").map(normalizedID)
                if asset.child("KeyId") != nil { encrypted = true }

                if let editRate, let intrinsic, editRate.numerator > 0 {
                    let oneSecond = (editRate.numerator + editRate.denominator - 1) / editRate.denominator
                    if intrinsic < oneSecond {
                        add(.error, "INVALID_INTRINSIC_DURATION", "\(reelLabel) \(name): IntrinsicDuration \(intrinsic) is shorter than one second.", file: file)
                    }
                    if let duration, duration < oneSecond {
                        add(.error, "INVALID_DURATION", "\(reelLabel) \(name): Duration \(duration) is shorter than one second.", file: file)
                    }
                    if let duration, entryPoint + duration > intrinsic {
                        add(.error, "INVALID_DURATION", "\(reelLabel) \(name): EntryPoint + Duration (\(entryPoint + duration)) exceeds IntrinsicDuration (\(intrinsic)).", file: file)
                    }
                }

                if name == "MainMarkers" {
                    for marker in asset.child("MarkerList")?.children("Marker") ?? [] {
                        let label = marker.text("Label") ?? ""
                        let offset = marker.text("Offset").flatMap(Int.init)
                        if label == "FFOC" {
                            foundFFOC = true
                            if offset != 1 {
                                add(.bv21, "INCORRECT_FFOC", "FFOC marker is at \(offset.map(String.init) ?? "?"); it should be 1.", file: file)
                            }
                        } else if label == "LFOC" {
                            foundLFOC = true
                            lfocOffset = offset
                        }
                    }
                    continue
                }

                if let duration { durations[name] = duration }
                if name == "MainPicture" || name == "MainStereoscopicPicture" {
                    hasPicture = true
                    if let editRate { editRateText = "\(editRate.numerator)/\(editRate.denominator)" }
                    totalFrames += duration ?? 0
                }
                if !cplIsInterop, asset.text("Hash") == nil, ["MainPicture", "MainSound", "MainStereoscopicPicture"].contains(name) {
                    add(.bv21, "MISSING_CPL_HASHES", "\(reelLabel) \(name) has no Hash.", file: file)
                }
                if name == "MainSound" || name == "MainSubtitle" || name == "ClosedCaption" {
                    if let language = asset.text("Language"), !DCPValidator.isValidLanguageTag(language) {
                        add(.warning, "INVALID_LANGUAGE", "\(reelLabel) \(name): \"\(language)\" is not an RFC 5646 language tag.", file: file)
                    } else if asset.text("Language") == nil, name == "MainSound", !cplIsInterop {
                        add(.bv21, "MISSING_LANGUAGE", "\(reelLabel) MainSound has no Language.", file: file)
                    }
                }

                guard let assetID else {
                    add(.error, "MISSING_ASSET_ID", "\(reelLabel) \(name) has no Id.", file: file)
                    continue
                }
                guard let assetURL = assetPaths[assetID] else {
                    add(.warning, "EXTERNAL_ASSET", "\(reelLabel) \(name) (\(assetID)) is not in this package. That is expected for a VF; for an OV it is missing.", file: file)
                    continue
                }
                if let cplHash = asset.text("Hash"), let pklHash = pklAssets[assetID]?.hash, cplHash != pklHash {
                    add(.error, "MISMATCHED_CPL_HASHES", "\(reelLabel) \(name): CPL and PKL hashes differ.", file: file)
                }

                if name == "MainPicture" || name == "MainSound" || name == "MainStereoscopicPicture" {
                    let essence = checkEssence(
                        url: assetURL, assetID: assetID, kind: name, reelLabel: reelLabel,
                        editRate: editRate, intrinsicDuration: intrinsic, isInterop: cplIsInterop,
                        progress: progressBase
                    )
                    if name == "MainPicture", let essence, let width = essence.storedWidth, let height = essence.storedHeight {
                        pictureSize = "\(width)×\(height)"
                    }
                    if name == "MainSound", let channels = essence?.channelCount {
                        soundChannels.insert(channels)
                    }
                }
                if isCancelled { return }
            }

            // Markers usually precede the picture in the asset list, so check LFOC afterwards.
            if let lfocOffset, let duration = durations["MainPicture"] ?? durations["MainStereoscopicPicture"],
               lfocOffset != duration - 1 {
                add(.bv21, "INCORRECT_LFOC", "\(reelLabel): LFOC marker is at \(lfocOffset); it should be \(duration - 1) (last frame).", file: file)
            }
            if !hasPicture {
                add(.error, "MISSING_MAIN_PICTURE", "\(reelLabel) has no MainPicture.", file: file)
            }
            if Set(durations.values).count > 1 {
                let detail = durations.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                add(.error, "MISMATCHED_ASSET_DURATION", "\(reelLabel) assets have different durations: \(detail).", file: file)
            }
        }

        if soundChannels.count > 1 {
            add(.error, "MISMATCHED_SOUND_CHANNEL_COUNTS", "Sound assets have different channel counts across reels: \(soundChannels.sorted()).", file: file)
        }

        if !cplIsInterop {
            if !foundFFOC { add(.bv21, "MISSING_FFOC", "No FFOC (first frame of content) marker.", file: file) }
            if !foundLFOC { add(.bv21, "MISSING_LFOC", "No LFOC (last frame of content) marker.", file: file) }
            if let metadata = compositionMetadata {
                checkCompositionMetadata(metadata, soundChannels: soundChannels.first, file: file)
            } else {
                add(.bv21, "MISSING_CPL_METADATA", "No CompositionMetadataAsset (SMPTE ST 429-16) in the first reel.", file: file)
            }
        }
        if encrypted {
            add(.info, "ENCRYPTED_CONTENT", "This composition is encrypted; essence checks are limited and a KDM is needed for playback.", file: file)
            if root.child("Signer") == nil {
                add(.error, "UNSIGNED_CPL_WITH_ENCRYPTED_CONTENT", "Encrypted compositions must have a signed CPL.", file: file)
            }
        }

        report.compositions.append(DCPCompositionSummary(
            id: id, title: title, contentKind: contentKind, standard: cplIsInterop ? "Interop" : "SMPTE",
            reelCount: reels.count, durationFrames: totalFrames, editRate: editRateText,
            pictureSize: pictureSize, soundChannels: soundChannels.first, encrypted: encrypted
        ))
    }

    private mutating func checkListedInPKL(id: String, url: URL) {
        guard pklAssets[id] == nil else { return }
        add(.error, "MISSING_CPL_IN_PKL", "\(url.lastPathComponent) is not listed in any packing list.", file: url.lastPathComponent)
    }

    private mutating func checkCompositionMetadata(_ metadata: XMLElement, soundChannels: Int?, file: String) {
        if metadata.text("FullContentTitleText") == nil {
            add(.bv21, "MISSING_CPL_METADATA_FULL_TITLE", "CompositionMetadataAsset has no FullContentTitleText.", file: file)
        }
        if metadata.text("VersionNumber") == nil {
            add(.bv21, "MISSING_CPL_METADATA_VERSION_NUMBER", "CompositionMetadataAsset has no VersionNumber.", file: file)
        }
        if let configuration = metadata.text("MainSoundConfiguration") {
            // e.g. "51/L,R,C,LFE,Ls,Rs" — count the channel list after the soundfield.
            let channelList = configuration.split(separator: "/").dropFirst().first ?? ""
            let declared = channelList.split(separator: ",").count
            if let soundChannels, declared > 0, declared != soundChannels {
                add(.error, "INVALID_MAIN_SOUND_CONFIGURATION", "MainSoundConfiguration \"\(configuration)\" declares \(declared) channels but the sound MXF has \(soundChannels).", file: file)
            }
        } else if soundChannels != nil {
            add(.bv21, "INVALID_MAIN_SOUND_CONFIGURATION", "CompositionMetadataAsset has no MainSoundConfiguration.", file: file)
        }
        if let active = metadata.child("MainPictureActiveArea"),
           let width = active.text("Width").flatMap(Int.init), let height = active.text("Height").flatMap(Int.init),
           width % 2 != 0 || height % 2 != 0 {
            add(.bv21, "INVALID_MAIN_PICTURE_ACTIVE_AREA", "MainPictureActiveArea \(width)×\(height) must have even dimensions.", file: file)
        }
    }

    // MARK: Essence

    @discardableResult
    private mutating func checkEssence(
        url: URL, assetID: String, kind: String, reelLabel: String,
        editRate: (numerator: Int, denominator: Int)?, intrinsicDuration: Int?, isInterop: Bool,
        progress: Double
    ) -> MXFEssenceInfo? {
        let file = url.lastPathComponent
        status(progress, "Inspecting \(file)…")
        let info: MXFEssenceInfo
        do {
            info = try MXFReader.read(url: url)
        } catch {
            add(.error, "INVALID_MXF", "\(reelLabel) \(kind): \(error.localizedDescription).", file: file)
            return nil
        }

        if let assetUUID = info.assetUUID, assetUUID != assetID {
            add(.error, "MISMATCHED_ASSET_ID", "\(reelLabel) \(kind): the MXF's AssetUUID is \(assetUUID) but the CPL/ASSETMAP call it \(assetID). Servers will report the asset as missing.", file: file)
        }
        if let editRate, let mxfRate = info.editRate,
           editRate.numerator * mxfRate.denominator != mxfRate.numerator * editRate.denominator {
            add(.error, "MISMATCHED_EDIT_RATE", "\(reelLabel) \(kind): CPL EditRate \(editRate.numerator)/\(editRate.denominator) but MXF edit rate \(mxfRate.numerator)/\(mxfRate.denominator).", file: file)
        }
        if let intrinsicDuration, let containerDuration = info.containerDuration, containerDuration != intrinsicDuration {
            add(.error, "MISMATCHED_INTRINSIC_DURATION", "\(reelLabel) \(kind): CPL IntrinsicDuration \(intrinsicDuration) but the MXF holds \(containerDuration) edit units.", file: file)
        }
        if info.frameRanges.count > 0, let containerDuration = info.containerDuration, info.frameRanges.count != containerDuration {
            add(.warning, "MISMATCHED_FRAME_COUNT", "\(reelLabel) \(kind): MXF declares \(containerDuration) edit units but contains \(info.frameRanges.count) essence elements.", file: file)
        }

        if kind == "MainSound" {
            if info.kind != .sound {
                add(.error, "INVALID_SOUND_ASSET", "\(reelLabel) MainSound does not reference a PCM sound MXF.", file: file)
            }
            if let rate = info.audioSampleRate, rate != 48_000, rate != 96_000 {
                add(.error, "INVALID_SOUND_FRAME_RATE", "\(reelLabel): sound sample rate is \(rate) Hz; DCPs require 48 kHz (or 96 kHz).", file: file)
            }
            if let bits = info.quantizationBits, bits != 24 {
                add(.error, "INVALID_SOUND_BIT_DEPTH", "\(reelLabel): sound is \(bits)-bit; DCPs require 24-bit PCM.", file: file)
            }
            if let channels = info.channelCount, channels > 16 {
                add(.error, "INVALID_SOUND_CHANNEL_COUNT", "\(reelLabel): \(channels) sound channels; at most 16 are allowed.", file: file)
            } else if let channels = info.channelCount, channels < 6 {
                add(.warning, "INVALID_SOUND_CHANNEL_COUNT", "\(reelLabel): only \(channels) sound channel(s). Cinema processors expect at least 6 (5.1); stereo should sit in L/R of a 6-channel track.", file: file)
            }
            if !isInterop && !info.hasMCALabels && !info.isEncrypted {
                add(.bv21, "MISSING_SOUND_MCA_LABELS", "\(reelLabel): sound MXF has no MCA (ST 377-4) channel labels.", file: file)
            }
            return info
        }

        if info.kind != .picture {
            add(.error, "INVALID_PICTURE_ASSET", "\(reelLabel) \(kind) does not reference a JPEG 2000 picture MXF.", file: file)
            return info
        }
        guard let width = info.storedWidth, let height = info.storedHeight else { return info }
        let size = "\(width)x\(height)"
        let isFourK = DCPValidator.containerSizes4K.contains(size)
        if !DCPValidator.containerSizes2K.contains(size) && !isFourK {
            add(.error, "INVALID_PICTURE_SIZE_IN_PIXELS", "\(reelLabel): picture is \(width)×\(height); DCI containers are 2048×1080 / 4096×2160 (Flat 1998/3996, Scope 858/1716 high).", file: file)
        }
        if let editRate, editRate.denominator == 1 {
            let fps = editRate.numerator
            let allowed = isFourK ? DCPValidator.smpte4KPictureRates : DCPValidator.smptePictureRates
            if !allowed.contains(fps) {
                let code = isFourK ? "INVALID_PICTURE_FRAME_RATE_FOR_4K" : "INVALID_PICTURE_FRAME_RATE"
                add(.error, code, "\(reelLabel): \(fps) fps is not allowed for \(isFourK ? "4K" : "2K") DCPs.", file: file)
            }
            checkFrameSizes(info: info, fps: fps, reelLabel: reelLabel, file: file)
        } else if let editRate {
            add(.error, "INVALID_PICTURE_FRAME_RATE", "\(reelLabel): non-integer edit rate \(editRate.numerator)/\(editRate.denominator) is not allowed in DCPs.", file: file)
        }

        if !info.isEncrypted {
            checkCodestreams(url: url, info: info, isFourK: isFourK, reelLabel: reelLabel, file: file)
        }
        return info
    }

    private mutating func checkFrameSizes(info: MXFEssenceInfo, fps: Int, reelLabel: String, file: String) {
        guard fps > 0, !info.frameRanges.isEmpty else { return }
        // Same thresholds as libdcp: 250 Mbit/s hard limit, warn above 230 Mbit/s.
        let limit = 250_000_000 / 8 / fps
        let nearLimit = 230_000_000 / 8 / fps
        var over = 0
        var near = 0
        var firstOver: Int?
        for (index, range) in info.frameRanges.enumerated() {
            let bytes = Int(range.upperBound - range.lowerBound)
            if bytes > limit {
                over += 1
                if firstOver == nil { firstOver = index }
            } else if bytes > nearLimit {
                near += 1
            }
        }
        let peakMbps = Double(info.maxFrameSize) * 8 * Double(fps) / 1_000_000
        if over > 0 {
            add(.error, "INVALID_PICTURE_FRAME_SIZE_IN_BYTES", String(format: "%@: %d frame(s) exceed 250 Mbit/s (first at frame %d, peak %.0f Mbit/s).", reelLabel, over, firstOver ?? 0, peakMbps), file: file)
        } else if near > 0 {
            add(.warning, "NEARLY_INVALID_PICTURE_FRAME_SIZE_IN_BYTES", String(format: "%@: %d frame(s) are above 230 Mbit/s (peak %.0f Mbit/s). Some older servers struggle near the limit.", reelLabel, near, peakMbps), file: file)
        }
    }

    private mutating func checkCodestreams(url: URL, info: MXFEssenceInfo, isFourK: Bool, reelLabel: String, file: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let frames = info.frameRanges
        let sampleCount = min(frames.count, max(options.codestreamSampleCount, 1))
        var indices = Set<Int>()
        if sampleCount > 1 {
            for step in 0..<sampleCount { indices.insert(step * (frames.count - 1) / (sampleCount - 1)) }
        } else if !frames.isEmpty {
            indices.insert(0)
        }

        var problems: [String: (count: Int, firstFrame: Int, message: String, severity: Severity)] = [:]
        func note(_ code: String, _ severity: Severity, _ frame: Int, _ message: String) {
            if let existing = problems[code] {
                problems[code] = (existing.count + 1, existing.firstFrame, existing.message, existing.severity)
            } else {
                problems[code] = (1, frame, message, severity)
            }
        }

        for index in indices.sorted() {
            if isCancelled { return }
            let range = frames[index]
            guard (try? handle.seek(toOffset: range.lowerBound)) != nil,
                  let data = try? handle.read(upToCount: Int(range.upperBound - range.lowerBound)),
                  let j2k = J2KCodestreamInfo.parse(data) else {
                note("INVALID_JPEG2000_CODESTREAM", .error, index, "frame data is not a JPEG 2000 codestream")
                continue
            }
            if j2k.width != info.storedWidth || j2k.height != info.storedHeight {
                note("INVALID_JPEG2000_SIZE", .error, index, "codestream is \(j2k.width)×\(j2k.height), MXF says \(info.storedWidth ?? 0)×\(info.storedHeight ?? 0)")
            }
            let expectedRsiz = isFourK ? 4 : 3
            if j2k.rsiz & 0xFF != expectedRsiz {
                note("INVALID_JPEG2000_RSIZ", .warning, index, String(format: "Rsiz is 0x%04x; DCI %@ codestreams use profile %d", j2k.rsiz, isFourK ? "4K" : "2K", expectedRsiz))
            }
            if j2k.components != 3 || j2k.bitDepth != 12 {
                note("INVALID_JPEG2000_COMPONENTS", .error, index, "\(j2k.components) component(s) at \(j2k.bitDepth) bits; DCI requires 3 × 12-bit X′Y′Z′")
            }
            if j2k.tileWidth != j2k.width || j2k.tileHeight != j2k.height {
                note("INVALID_JPEG2000_TILE_SIZE", .error, index, "image is tiled \(j2k.tileWidth)×\(j2k.tileHeight); DCI requires a single tile")
            }
            if j2k.progressionOrder != J2KCodestreamInfo.cprl {
                note("INVALID_JPEG2000_PROGRESSION_ORDER", .error, index, "progression order is not CPRL")
            }
            if j2k.codeBlockWidth != 32 || j2k.codeBlockHeight != 32 {
                note("INVALID_JPEG2000_CODE_BLOCK_SIZE", .error, index, "code blocks are \(j2k.codeBlockWidth)×\(j2k.codeBlockHeight); DCI requires 32×32")
            }
            let maxLevels = isFourK ? 6 : 5
            if j2k.decompositionLevels > maxLevels || j2k.decompositionLevels < 1 {
                note("INVALID_JPEG2000_TRANSFORM_LEVELS", .error, index, "\(j2k.decompositionLevels) wavelet levels; \(isFourK ? "4K" : "2K") allows at most \(maxLevels)")
            } else if isFourK && j2k.decompositionLevels != 6 {
                note("INVALID_JPEG2000_TRANSFORM_LEVELS", .warning, index, "\(j2k.decompositionLevels) wavelet levels; 4K should use 6 so 2K projectors can extract a 2K image")
            }
            if j2k.guardBits != (isFourK ? 2 : 1) {
                note("INVALID_JPEG2000_GUARD_BITS", .bv21, index, "\(j2k.guardBits) guard bits; expected \(isFourK ? 2 : 1)")
            }
            if !j2k.hasTLM {
                note("MISSING_JPEG2000_TLM_MARKER", .bv21, index, "no TLM marker")
            }
            if j2k.tileParts != (isFourK ? 6 : 3) {
                note(isFourK ? "INVALID_JPEG2000_TILE_PARTS_FOR_4K" : "INVALID_JPEG2000_TILE_PARTS_FOR_2K", .bv21, index, "\(j2k.tileParts) tile parts; expected \(isFourK ? 6 : 3) (one per component\(isFourK ? " per resolution group" : ""))")
            }
            if isFourK && !j2k.hasPOC {
                note("INVALID_JPEG2000_POC_MARKER_COUNT_FOR_4K", .bv21, index, "4K codestream has no POC marker")
            }
        }

        for (code, problem) in problems.sorted(by: { $0.key < $1.key }) {
            add(problem.severity, code, "\(reelLabel): \(problem.message) (\(problem.count) of \(indices.count) sampled frames, first at frame \(problem.firstFrame)).", file: file)
        }
    }

    // MARK: Hashes

    private mutating func verifyHashes(progressBase: Double) {
        let entries = pklAssets.compactMap { id, asset -> (URL, PKLAsset)? in
            guard let url = assetPaths[id], asset.hash != nil else { return nil }
            return (url, asset)
        }.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
        let totalBytes = max(entries.reduce(Int64(0)) { $0 + fileSize($1.0) }, 1)
        var doneBytes: Int64 = 0
        for (url, asset) in entries {
            let progress = progress
            let base = doneBytes
            let name = url.lastPathComponent
            var hashedBytes: Int64 = 0
            var reportedBytes: Int64 = 0
            let digest = DCPValidator.base64SHA1(of: url, isCancelled: { Task.isCancelled }) { bytes in
                hashedBytes += bytes
                // Throttle UI updates to roughly every 64 MB.
                guard hashedBytes - reportedBytes >= 64 * 1024 * 1024 else { return }
                reportedBytes = hashedBytes
                let fraction = progressBase + (1 - progressBase) * Double(base + hashedBytes) / Double(totalBytes)
                progress?(min(fraction, 1), "Verifying hash of \(name)…")
            }
            doneBytes += fileSize(url)
            if isCancelled { report.cancelled = true; return }
            guard let digest else {
                add(.error, "UNREADABLE_ASSET", "Could not read \(url.lastPathComponent) to verify its hash.", file: asset.pklFile)
                continue
            }
            if digest != asset.hash {
                add(.error, "INCORRECT_ASSET_HASH", "\(url.lastPathComponent): SHA-1 does not match the PKL. The file is corrupt or was modified.", file: asset.pklFile)
            }
        }
    }

    // MARK: XML helpers

    private mutating func loadXML(_ url: URL) -> XMLElement? {
        do {
            let document = try XMLDocument(contentsOf: url, options: [])
            guard let root = document.rootElement() else {
                add(.error, "INVALID_XML", "Empty XML document.", file: url.lastPathComponent)
                return nil
            }
            return root
        } catch {
            add(.error, "INVALID_XML", "Could not parse XML: \(error.localizedDescription)", file: url.lastPathComponent)
            return nil
        }
    }

    private func normalizedID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "urn:uuid:", with: "")
    }

    private func parseRational(_ text: String) -> (numerator: Int, denominator: Int)? {
        let parts = text.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 2, parts[1] != 0 else { return nil }
        return (parts[0], parts[1])
    }

    private func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private func fileSize(_ url: URL) -> Int64 {
        SMPTEPackageUtils.fileSize(at: url)
    }
}

private extension XMLElement {
    var childElements: [XMLElement] {
        children?.compactMap { $0 as? XMLElement } ?? []
    }

    func child(_ name: String) -> XMLElement? {
        childElements.first { $0.localName == name }
    }

    func children(_ name: String) -> [XMLElement] {
        childElements.filter { $0.localName == name }
    }

    func text(_ name: String) -> String? {
        child(name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
