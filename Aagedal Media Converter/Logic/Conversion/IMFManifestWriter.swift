// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Generates IMF (Interoperable Master Package) manifests — CPL (ST 2067-3),
/// PKL (ST 2067-2), and ASSETMAP (ST 2067-8) — alongside the encoded video and
/// audio essence MXFs to assemble a single-segment, single-essence-pair IMP.
///
/// The structure produced here is intentionally minimal: one Reel containing a
/// MainImageSequence and a MainAudioSequence, each with a single TrackFileResource.
/// This is the smallest CPL the existing `IMFPackageParser` can round-trip.
actor IMFManifestWriter {
    static let shared = IMFManifestWriter()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "IMFManifestWriter")

    private init() {}

    // MARK: - Public API

    func pictureFrameCount(for videoMXFURL: URL) async -> Int? {
        await IMFMXFMetadata.read(videoMXFURL, expectedKind: "Picture")?.duration
    }

    /// Assembles an IMF Master Package directory from already-encoded video and audio MXF files.
    /// - Parameters:
    ///   - videoMXFURL: Encoded video essence (J2K or ProRes) wrapped to OP1a MXF.
    ///   - audioMXFURL: Encoded audio essence (PCM) wrapped to OP1a MXF, or nil if source has no audio.
    ///   - outputDirectoryURL: Empty package directory the manifests and renamed essences will be written into.
    ///   - title: ContentTitleText displayed by IMF players.
    ///   - application: Selects App #2e or RDD 45 identity for the CPL.
    ///   - editRateNumerator/editRateDenominator: Edit rate for the composition (e.g. 24/1, 30000/1001).
    ///   - frameCount: Total intrinsic duration in edit-rate units.
    ///   - itemMetadata: Per-item user metadata (ContentKind, AnnotationText, AudioLanguage).
    ///   - progress: Progress callback (0.0 → 1.0).
    /// - Returns: true on success.
    func assembleIMP(
        videoMXFURL: URL,
        audioMXFURL: URL?,
        outputDirectoryURL: URL,
        title: String,
        application: IMFApplication,
        editRateNumerator: Int,
        editRateDenominator: Int,
        frameCount: Int,
        color: IMFColorEncoding = .rec709,
        itemMetadata: IMFItemMetadata? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        logger.info("Assembling IMP: \(title) (\(application.displayName), \(frameCount) frames @ \(editRateNumerator)/\(editRateDenominator))")

        guard let videoMetadata = await IMFMXFMetadata.read(videoMXFURL, expectedKind: "Picture"),
              videoMetadata.duration >= frameCount else {
            logger.error("IMF video MXF metadata is missing or shorter than the composition")
            return false
        }
        let audioMetadata: IMFMXFMetadata?
        if let audioMXFURL {
            guard let inspected = await IMFMXFMetadata.read(audioMXFURL, expectedKind: "Sound") else {
                logger.error("IMF audio MXF metadata is missing")
                return false
            }
            audioMetadata = inspected
        } else {
            audioMetadata = nil
        }

        // Generate all manifest-only UUIDs upfront so cross-references are stable.
        let cplUUID = SMPTEPackageUtils.urnUUID()
        let pklUUID = SMPTEPackageUtils.urnUUID()
        let assetMapUUID = SMPTEPackageUtils.urnUUID()
        let videoUUID = videoMetadata.trackFileID
        let audioUUID = audioMetadata?.trackFileID
        let videoResourceUUID = SMPTEPackageUtils.urnUUID()
        let audioResourceUUID = audioMXFURL != nil ? SMPTEPackageUtils.urnUUID() : nil
        let imageSequenceUUID = SMPTEPackageUtils.urnUUID()
        let audioSequenceUUID = audioMXFURL != nil ? SMPTEPackageUtils.urnUUID() : nil
        let segmentUUID = SMPTEPackageUtils.urnUUID()
        let reelUUID = SMPTEPackageUtils.urnUUID()

        // Move essences into the package with UUID-based names (typical IMF practice).
        let videoFileName = "video_\(SMPTEPackageUtils.uuidString(from: videoUUID)).mxf"
        let videoDestURL = outputDirectoryURL.appendingPathComponent(videoFileName)
        do {
            if videoMXFURL != videoDestURL {
                if FileManager.default.fileExists(atPath: videoDestURL.path) {
                    try FileManager.default.removeItem(at: videoDestURL)
                }
                try FileManager.default.moveItem(at: videoMXFURL, to: videoDestURL)
            }
        } catch {
            logger.error("Failed to move video MXF: \(error.localizedDescription)")
            return false
        }
        progress(0.1)

        var audioFileName: String? = nil
        var audioDestURL: URL? = nil
        if let audioMXF = audioMXFURL, let aUUID = audioUUID {
            let fileName = "audio_\(SMPTEPackageUtils.uuidString(from: aUUID)).mxf"
            audioFileName = fileName
            let destURL = outputDirectoryURL.appendingPathComponent(fileName)
            audioDestURL = destURL
            do {
                if audioMXF != destURL {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: audioMXF, to: destURL)
                }
            } catch {
                logger.error("Failed to move audio MXF: \(error.localizedDescription)")
                return false
            }
        }
        progress(0.2)

        // Hash + size the essence files (PKL needs hashes, ASSETMAP needs sizes).
        guard let videoHash = SMPTEPackageUtils.computeSHA1(for: videoDestURL) else {
            logger.error("Failed to compute SHA-1 for video MXF")
            return false
        }
        let videoSize = SMPTEPackageUtils.fileSize(at: videoDestURL)
        progress(0.5)

        var audioHash: String? = nil
        var audioSize: Int64? = nil
        if let dest = audioDestURL {
            audioHash = SMPTEPackageUtils.computeSHA1(for: dest)
            audioSize = SMPTEPackageUtils.fileSize(at: dest)
        }
        progress(0.6)

        // CPL — must be written before PKL since PKL needs the CPL's own hash.
        let titleForXML = title.isEmpty ? outputDirectoryURL.lastPathComponent : title
        let annotationText = (itemMetadata?.annotationText.isEmpty == false ? itemMetadata!.annotationText : titleForXML)
        let contentKind = itemMetadata?.contentKind ?? .feature
        let audioLanguage = itemMetadata?.audioLanguage ?? "en"

        let cplFileName = "CPL_\(SMPTEPackageUtils.uuidString(from: cplUUID)).xml"
        let cplContent = generateCPL(
            cplUUID: cplUUID,
            title: titleForXML,
            annotationText: annotationText,
            contentKind: contentKind,
            editRateNumerator: editRateNumerator,
            editRateDenominator: editRateDenominator,
            frameCount: frameCount,
            segmentUUID: segmentUUID,
            reelUUID: reelUUID,
            imageSequenceUUID: imageSequenceUUID,
            videoResourceUUID: videoResourceUUID,
            videoTrackFileUUID: videoUUID,
            audioSequenceUUID: audioSequenceUUID,
            audioResourceUUID: audioResourceUUID,
            audioTrackFileUUID: audioUUID,
            audioLanguage: audioLanguage,
            applicationLabel: application.displayName,
            application: application,
            color: color,
            videoMetadata: videoMetadata,
            audioMetadata: audioMetadata,
            videoHash: videoHash,
            audioHash: audioHash
        )
        let cplURL = outputDirectoryURL.appendingPathComponent(cplFileName)
        do {
            try cplContent.write(to: cplURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write CPL: \(error.localizedDescription)")
            return false
        }
        guard let cplHashHex = SMPTEPackageUtils.computeSHA1(for: cplURL) else {
            logger.error("Failed to compute SHA-1 for CPL")
            return false
        }
        let cplSize = SMPTEPackageUtils.fileSize(at: cplURL)
        progress(0.8)

        // PKL.
        let pklFileName = "PKL_\(SMPTEPackageUtils.uuidString(from: pklUUID)).xml"
        let pklContent = generatePKL(
            pklUUID: pklUUID,
            annotationText: annotationText,
            cplUUID: cplUUID,
            cplFileName: cplFileName,
            cplHashHex: cplHashHex,
            cplSize: cplSize,
            videoUUID: videoUUID,
            videoFileName: videoFileName,
            videoHashHex: videoHash,
            videoSize: videoSize,
            audioUUID: audioUUID,
            audioFileName: audioFileName,
            audioHashHex: audioHash,
            audioSize: audioSize
        )
        let pklURL = outputDirectoryURL.appendingPathComponent(pklFileName)
        do {
            try pklContent.write(to: pklURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write PKL: \(error.localizedDescription)")
            return false
        }
        let pklSize = SMPTEPackageUtils.fileSize(at: pklURL)
        progress(0.9)

        // ASSETMAP.
        let assetMapContent = generateAssetMap(
            assetMapUUID: assetMapUUID,
            annotationText: annotationText,
            pklUUID: pklUUID,
            pklFileName: pklFileName,
            pklSize: pklSize,
            cplUUID: cplUUID,
            cplFileName: cplFileName,
            cplSize: cplSize,
            videoUUID: videoUUID,
            videoFileName: videoFileName,
            videoSize: videoSize,
            audioUUID: audioUUID,
            audioFileName: audioFileName,
            audioSize: audioSize
        )
        let assetMapURL = outputDirectoryURL.appendingPathComponent("ASSETMAP.xml")
        do {
            try assetMapContent.write(to: assetMapURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write ASSETMAP: \(error.localizedDescription)")
            return false
        }

        progress(1.0)
        logger.info("IMP assembly complete: \(outputDirectoryURL.lastPathComponent)")
        return true
    }

    // MARK: - Folder naming

    /// Generates a conventional IMF folder name. IMF doesn't have a single mandated naming
    /// scheme like ISDCF for DCP — the form below mirrors common deliveries.
    /// Format: `Title_App<n>_<ResTier>_<FPS>_<Lang>_<YYYYMMDD>`
    func packageFolderName(
        title: String,
        application: IMFApplication,
        resolution: IMFResolution,
        frameRate: IMFFrameRate,
        audioLanguage: String
    ) -> String {
        let sanitizedTitle = title
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
            .map { String($0) }.joined()
            .replacingOccurrences(of: " ", with: "-")
        let appTag: String
        switch application {
        case .app2e: appTag = "App2e"
        case .rdd45: appTag = "RDD45"
        }
        let langCode = String(audioLanguage.prefix(3)).uppercased()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStr = dateFormatter.string(from: Date())
        let safeTitle = sanitizedTitle.isEmpty ? "IMF" : sanitizedTitle
        return "\(safeTitle)_\(appTag)_\(resolution.shortTier)_\(frameRate.folderTag)_\(langCode)_\(dateStr)"
    }

    // MARK: - CPL (ST 2067-3)

    private func generateCPL(
        cplUUID: String,
        title: String,
        annotationText: String,
        contentKind: IMFContentKind,
        editRateNumerator: Int,
        editRateDenominator: Int,
        frameCount: Int,
        segmentUUID: String,
        reelUUID: String,
        imageSequenceUUID: String,
        videoResourceUUID: String,
        videoTrackFileUUID: String,
        audioSequenceUUID: String?,
        audioResourceUUID: String?,
        audioTrackFileUUID: String?,
        audioLanguage: String,
        applicationLabel: String,
        application: IMFApplication,
        color: IMFColorEncoding,
        videoMetadata: IMFMXFMetadata,
        audioMetadata: IMFMXFMetadata?,
        videoHash: String,
        audioHash: String?
    ) -> String {
        let editRate = "\(editRateNumerator) \(editRateDenominator)"
        let escapedTitle = SMPTEPackageUtils.xmlEscape(title)
        let escapedAnnotation = SMPTEPackageUtils.xmlEscape(annotationText)
        let escapedAppLabel = SMPTEPackageUtils.xmlEscape(applicationLabel)
        let escapedLang = SMPTEPackageUtils.xmlEscape(audioLanguage)
        let now = SMPTEPackageUtils.iso8601Now()
        let contentVersionUUID = SMPTEPackageUtils.urnUUID()

        var sequences = """
                  <SequenceList>
                    <cc:MainImageSequence>
                      <Id>\(imageSequenceUUID)</Id>
                      <TrackId>\(SMPTEPackageUtils.urnUUID())</TrackId>
                      <ResourceList>
                        <Resource xsi:type="TrackFileResourceType">
                          <Id>\(videoResourceUUID)</Id>
                          <EditRate>\(videoMetadata.editRate.replacingOccurrences(of: "/", with: " "))</EditRate>
                          <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                          <EntryPoint>0</EntryPoint>
                          <SourceDuration>\(frameCount)</SourceDuration>
                          <RepeatCount>1</RepeatCount>
                          <TrackFileId>\(videoTrackFileUUID)</TrackFileId>
                          <SourceEncoding>\(videoMetadata.descriptorID)</SourceEncoding>
                          <Hash>\(SMPTEPackageUtils.base64SHA1(hex: videoHash))</Hash>
                          <HashAlgorithm Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/>
                        </Resource>
                      </ResourceList>
                    </cc:MainImageSequence>
        """

        if let audioSeqUUID = audioSequenceUUID,
           let audioResUUID = audioResourceUUID,
           let audioTfUUID = audioTrackFileUUID,
           let audioMetadata, let audioHash {
            let audioDuration = audioMetadata.duration
            sequences += """

                    <cc:MainAudioSequence>
                      <Id>\(audioSeqUUID)</Id>
                      <TrackId>\(SMPTEPackageUtils.urnUUID())</TrackId>
                      <ResourceList>
                        <Resource xsi:type="TrackFileResourceType">
                          <Id>\(audioResUUID)</Id>
                          <EditRate>\(audioMetadata.editRate.replacingOccurrences(of: "/", with: " "))</EditRate>
                          <IntrinsicDuration>\(audioDuration)</IntrinsicDuration>
                          <EntryPoint>0</EntryPoint>
                          <SourceDuration>\(audioDuration)</SourceDuration>
                          <RepeatCount>1</RepeatCount>
                          <TrackFileId>\(audioTfUUID)</TrackFileId>
                          <SourceEncoding>\(audioMetadata.descriptorID)</SourceEncoding>
                          <Hash>\(SMPTEPackageUtils.base64SHA1(hex: audioHash))</Hash>
                          <HashAlgorithm Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/>
                        </Resource>
                      </ResourceList>
                    </cc:MainAudioSequence>
            """
        }

        sequences += """

                  </SequenceList>
        """

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <CompositionPlaylist xmlns="http://www.smpte-ra.org/schemas/2067-3/2016"
                             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                             xmlns:cc="http://www.smpte-ra.org/ns/2067-2/2020"
                             xmlns:reg="http://www.smpte-ra.org/reg/335/2012"
                             xmlns:aaf="http://www.smpte-ra.org/reg/395/2014/13/1/aaf">
          <Id>\(cplUUID)</Id>
          <Annotation>\(escapedAnnotation)</Annotation>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter (\(escapedAppLabel))</Creator>
          <ContentTitle>\(escapedTitle)</ContentTitle>
          <ContentKind>\(contentKind.rawValue)</ContentKind>
          <ContentVersionList>
            <ContentVersion>
              <Id>\(contentVersionUUID)</Id>
              <LabelText>\(escapedTitle)_v1</LabelText>
            </ContentVersion>
          </ContentVersionList>
          <EssenceDescriptorList>
        \(videoMetadata.descriptorXML(color: color))
        \(audioMetadata?.descriptorXML(color: color) ?? "")
          </EssenceDescriptorList>
          <CompositionTimecode>
            <TimecodeDropFrame>false</TimecodeDropFrame>
            <TimecodeRate>\(Int((Double(editRateNumerator) / Double(editRateDenominator)).rounded()))</TimecodeRate>
            <TimecodeStartAddress>00:00:00:00</TimecodeStartAddress>
          </CompositionTimecode>
          <EditRate>\(editRate)</EditRate>
          <ExtensionProperties>
            <cc:ApplicationIdentification>\(application == .app2e ? "http://www.smpte-ra.org/ns/2067-21/2021" : "tag:apple.com,2017:imf:rdd45:2017")</cc:ApplicationIdentification>
          </ExtensionProperties>
          <LocaleList>
            <Locale>
              <LanguageList>
                <Language>\(escapedLang)</Language>
              </LanguageList>
            </Locale>
          </LocaleList>
          <SegmentList>
            <Segment>
              <Id>\(segmentUUID)</Id>
        \(sequences)
            </Segment>
          </SegmentList>
        </CompositionPlaylist>
        """
    }

    // MARK: - PKL (ST 2067-2)

    private func generatePKL(
        pklUUID: String,
        annotationText: String,
        cplUUID: String,
        cplFileName: String,
        cplHashHex: String,
        cplSize: Int64,
        videoUUID: String,
        videoFileName: String,
        videoHashHex: String,
        videoSize: Int64,
        audioUUID: String?,
        audioFileName: String?,
        audioHashHex: String?,
        audioSize: Int64?
    ) -> String {
        let escapedAnnotation = SMPTEPackageUtils.xmlEscape(annotationText)
        let now = SMPTEPackageUtils.iso8601Now()

        var assets = """
            <Asset>
              <Id>\(cplUUID)</Id>
              <AnnotationText>\(SMPTEPackageUtils.uuidString(from: cplUUID))</AnnotationText>
              <Hash>\(SMPTEPackageUtils.base64SHA1(hex: cplHashHex))</Hash>
              <Size>\(cplSize)</Size>
              <Type>text/xml</Type>
              <OriginalFileName>\(cplFileName)</OriginalFileName>
              <HashAlgorithm Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/>
            </Asset>
            <Asset>
              <Id>\(videoUUID)</Id>
              <AnnotationText>\(SMPTEPackageUtils.uuidString(from: videoUUID))</AnnotationText>
              <Hash>\(SMPTEPackageUtils.base64SHA1(hex: videoHashHex))</Hash>
              <Size>\(videoSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(videoFileName)</OriginalFileName>
              <HashAlgorithm Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/>
            </Asset>
        """

        if let aUUID = audioUUID, let aFileName = audioFileName, let aHash = audioHashHex, let aSize = audioSize {
            assets += """

            <Asset>
              <Id>\(aUUID)</Id>
              <AnnotationText>\(SMPTEPackageUtils.uuidString(from: aUUID))</AnnotationText>
              <Hash>\(SMPTEPackageUtils.base64SHA1(hex: aHash))</Hash>
              <Size>\(aSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(aFileName)</OriginalFileName>
              <HashAlgorithm Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/>
            </Asset>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <PackingList xmlns="http://www.smpte-ra.org/schemas/2067-2/2016/PKL">
          <Id>\(pklUUID)</Id>
          <AnnotationText>\(escapedAnnotation)</AnnotationText>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter</Creator>
          <AssetList>
        \(assets)
          </AssetList>
        </PackingList>
        """
    }

    // MARK: - ASSETMAP (ST 2067-8)

    private func generateAssetMap(
        assetMapUUID: String,
        annotationText: String,
        pklUUID: String,
        pklFileName: String,
        pklSize: Int64,
        cplUUID: String,
        cplFileName: String,
        cplSize: Int64,
        videoUUID: String,
        videoFileName: String,
        videoSize: Int64,
        audioUUID: String?,
        audioFileName: String?,
        audioSize: Int64?
    ) -> String {
        let escapedAnnotation = SMPTEPackageUtils.xmlEscape(annotationText)
        let now = SMPTEPackageUtils.iso8601Now()

        var assets = """
            <Asset>
              <Id>\(pklUUID)</Id>
              <PackingList>true</PackingList>
              <ChunkList>
                <Chunk>
                  <Path>\(pklFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                  <Length>\(pklSize)</Length>
                </Chunk>
              </ChunkList>
            </Asset>
            <Asset>
              <Id>\(cplUUID)</Id>
              <ChunkList>
                <Chunk>
                  <Path>\(cplFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                  <Length>\(cplSize)</Length>
                </Chunk>
              </ChunkList>
            </Asset>
            <Asset>
              <Id>\(videoUUID)</Id>
              <ChunkList>
                <Chunk>
                  <Path>\(videoFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                  <Length>\(videoSize)</Length>
                </Chunk>
              </ChunkList>
            </Asset>
        """

        if let aUUID = audioUUID, let aFileName = audioFileName, let aSize = audioSize {
            assets += """

            <Asset>
              <Id>\(aUUID)</Id>
              <ChunkList>
                <Chunk>
                  <Path>\(aFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                  <Length>\(aSize)</Length>
                </Chunk>
              </ChunkList>
            </Asset>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <AssetMap xmlns="http://www.smpte-ra.org/schemas/429-9/2007/AM">
          <Id>\(assetMapUUID)</Id>
          <AnnotationText>\(escapedAnnotation)</AnnotationText>
          <Creator>Aagedal Media Converter</Creator>
          <VolumeCount>1</VolumeCount>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <AssetList>
        \(assets)
          </AssetList>
        </AssetMap>
        """
    }
}

/// The small subset of MXF header metadata needed for a single-track experimental IMP.
/// Values come from the MXF after wrapping, rather than from the requested encode settings.
private struct IMFMXFMetadata {
    let trackFileID: String
    let descriptorID = SMPTEPackageUtils.urnUUID()
    let kind: String
    let editRate: String
    let duration: Int
    let containerUL: String
    let compressionUL: String?
    let width: Int?
    let height: Int?
    let aspectRatio: String?
    let componentDepth: Int?
    let horizontalSubsampling: Int?
    let verticalSubsampling: Int?
    let audioSampleRate: String?
    let audioChannels: Int?
    let audioBits: Int?
    let audioBlockAlign: Int?
    let linkedTrackID: Int

    static func read(_ url: URL, expectedKind: String) async -> Self? {
        guard let data = await BMXService.shared.getMXFXMLInfo(url: url),
              let document = try? XMLDocument(data: data),
              let op = try? document.nodes(forXPath: "//*[local-name()='op_label']").first?.stringValue,
              op == "OP1A",
              let package = try? document.nodes(forXPath: "//*[local-name()='file']/*[local-name()='primary_package']").first as? XMLElement,
              let trackFileID = package.attribute(forName: "idau")?.stringValue,
              trackFileID.hasPrefix("urn:uuid:"),
              let track = try? document.nodes(forXPath: "//*[local-name()='clip']/*[local-name()='tracks']/*[local-name()='track']").first,
              let kind = value("essence_kind", in: track), kind == expectedKind,
              let rate = value("edit_rate", in: track),
              let durationElement = try? track.nodes(forXPath: "./*[local-name()='duration']").first as? XMLElement,
              let durationText = durationElement.attribute(forName: "count")?.stringValue,
              let duration = Int(durationText), duration > 0,
              let containerUL = value("ec_label", in: track),
              let linkedID = value("track_id", in: track, scope: ".//*[local-name()='file_source']/*"),
              let linkedTrackID = Int(linkedID) else { return nil }

        let picture = try? track.nodes(forXPath: "./*[local-name()='picture_descriptor']").first
        let sound = try? track.nodes(forXPath: "./*[local-name()='sound_descriptor']").first
        if kind == "Picture" {
            guard let picture, value("stored_width", in: picture) != nil,
                  value("stored_height", in: picture) != nil,
                  let cdci = try? picture.nodes(forXPath: "./*[local-name()='cdci_descriptor']"),
                  !cdci.isEmpty else { return nil }
        } else if sound == nil { return nil }
        return Self(
            trackFileID: trackFileID, kind: kind, editRate: rate, duration: duration,
            containerUL: containerUL,
            compressionUL: picture.flatMap { value("coding_label", in: $0) },
            width: picture.flatMap { value("stored_width", in: $0) }.flatMap(Int.init),
            height: picture.flatMap { value("stored_height", in: $0) }.flatMap(Int.init),
            aspectRatio: picture.flatMap { value("aspect_ratio", in: $0) },
            componentDepth: picture.flatMap { value("component_depth", in: $0, scope: ".//*[local-name()='cdci_descriptor']/*") }.flatMap(Int.init),
            horizontalSubsampling: picture.flatMap { value("horiz_subsamp", in: $0, scope: ".//*[local-name()='cdci_descriptor']/*") }.flatMap(Int.init),
            verticalSubsampling: picture.flatMap { value("vert_subsamp", in: $0, scope: ".//*[local-name()='cdci_descriptor']/*") }.flatMap(Int.init),
            audioSampleRate: sound.flatMap { value("sampling_rate", in: $0) },
            audioChannels: sound.flatMap { value("channel_count", in: $0) }.flatMap(Int.init),
            audioBits: sound.flatMap { value("bits_per_sample", in: $0) }.flatMap(Int.init),
            audioBlockAlign: sound.flatMap { value("block_align", in: $0) }.flatMap(Int.init),
            linkedTrackID: linkedTrackID
        )
    }

    private static func value(_ name: String, in node: XMLNode, scope: String = "./*") -> String? {
        try? node.nodes(forXPath: "\(scope)[local-name()='\(name)']").first?.stringValue
    }

    func descriptorXML(color: IMFColorEncoding) -> String {
        if kind == "Sound" {
            let channels = audioChannels ?? 0
            let bits = audioBits ?? 0
            let block = audioBlockAlign ?? 0
            let rate = audioSampleRate ?? "48000/1"
            let samples = Int(rate.split(separator: "/").first ?? "48000") ?? 48000
            return """
                <EssenceDescriptor>
                  <Id>\(descriptorID)</Id>
                  <aaf:WAVEPCMDescriptor>
                    <reg:LinkedTrackID>\(linkedTrackID)</reg:LinkedTrackID>
                    <reg:InstanceID>\(SMPTEPackageUtils.urnUUID())</reg:InstanceID>
                    <reg:AudioSampleRate>\(rate)</reg:AudioSampleRate>
                    <reg:SampleRate>\(rate)</reg:SampleRate>
                    <reg:ChannelCount>\(channels)</reg:ChannelCount>
                    <reg:QuantizationBits>\(bits)</reg:QuantizationBits>
                    <reg:BlockAlign>\(block)</reg:BlockAlign>
                    <reg:AverageBytesPerSecond>\(samples * block)</reg:AverageBytesPerSecond>
                    <reg:ContainerFormat>\(containerUL)</reg:ContainerFormat>
                    <reg:ChannelAssignment>urn:smpte:ul:060e2b34.0401010d.04020210.04010000</reg:ChannelAssignment>
                    <reg:EssenceLength>\(duration)</reg:EssenceLength>
                  </aaf:WAVEPCMDescriptor>
                </EssenceDescriptor>
                """
        }

        let (primaries, transfer, matrix) = color.imfDescriptorULs
        return """
            <EssenceDescriptor>
              <Id>\(descriptorID)</Id>
              <aaf:CDCIDescriptor>
                <reg:HorizontalSubsampling>\(horizontalSubsampling ?? 2)</reg:HorizontalSubsampling>
                <reg:VerticalSubsampling>\(verticalSubsampling ?? 1)</reg:VerticalSubsampling>
                <reg:ComponentDepth>\(componentDepth ?? 10)</reg:ComponentDepth>
                <reg:BlackRefLevel>64</reg:BlackRefLevel>
                <reg:WhiteRefLevel>940</reg:WhiteRefLevel>
                <reg:ColorRange>897</reg:ColorRange>
                <reg:LinkedTrackID>\(linkedTrackID)</reg:LinkedTrackID>
                <reg:InstanceID>\(SMPTEPackageUtils.urnUUID())</reg:InstanceID>
                <reg:DisplayWidth>\(width ?? 0)</reg:DisplayWidth>
                <reg:DisplayHeight>\(height ?? 0)</reg:DisplayHeight>
                <reg:StoredWidth>\(width ?? 0)</reg:StoredWidth>
                <reg:StoredHeight>\(height ?? 0)</reg:StoredHeight>
                <reg:FrameLayout>FullFrame</reg:FrameLayout>
                <reg:ImageAspectRatio>\(aspectRatio ?? "16/9")</reg:ImageAspectRatio>
                <reg:SampleRate>\(editRate)</reg:SampleRate>
                <reg:TransferCharacteristic>\(transfer)</reg:TransferCharacteristic>
                <reg:ColorPrimaries>\(primaries)</reg:ColorPrimaries>
                <reg:CodingEquations>\(matrix)</reg:CodingEquations>
                <reg:ContainerFormat>\(containerUL)</reg:ContainerFormat>
                <reg:PictureCompression>\(compressionUL ?? "")</reg:PictureCompression>
                <reg:EssenceLength>\(duration)</reg:EssenceLength>
              </aaf:CDCIDescriptor>
            </EssenceDescriptor>
            """
    }
}

private extension IMFColorEncoding {
    var imfDescriptorULs: (String, String, String) {
        let rec709Primaries = "urn:smpte:ul:060e2b34.04010106.04010101.03030000"
        let rec709Transfer = "urn:smpte:ul:060e2b34.04010101.04010101.01020000"
        let rec709Matrix = "urn:smpte:ul:060e2b34.04010101.04010101.02020000"
        let rec2020Primaries = "urn:smpte:ul:060e2b34.0401010d.04010101.03040000"
        let rec2020Matrix = "urn:smpte:ul:060e2b34.0401010d.04010101.02060000"
        switch self {
        case .rec709: return (rec709Primaries, rec709Transfer, rec709Matrix)
        case .rec2020SDR: return (rec2020Primaries, "urn:smpte:ul:060e2b34.0401010d.04010101.01090000", rec2020Matrix)
        case .rec2020PQ: return (rec2020Primaries, "urn:smpte:ul:060e2b34.0401010d.04010101.010a0000", rec2020Matrix)
        case .rec2020HLG: return (rec2020Primaries, "urn:smpte:ul:060e2b34.0401010d.04010101.010b0000", rec2020Matrix)
        }
    }
}
