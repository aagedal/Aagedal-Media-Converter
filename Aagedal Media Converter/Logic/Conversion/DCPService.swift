// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import CryptoKit

/// Service for assembling DCP (Digital Cinema Package) directories
/// Generates SMPTE DCP XML metadata (CPL, PKL, ASSETMAP, VOLINDEX)
actor DCPService {
    static let shared = DCPService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "DCPService")

    private init() {}

    // MARK: - Public API

    /// Assembles a DCP directory from video and audio MXF files
    /// - Parameters:
    ///   - videoMXFURL: The JPEG 2000 video MXF file
    ///   - audioMXFURL: The PCM audio MXF file (nil if source has no audio)
    ///   - outputDirectoryURL: The DCP output directory
    ///   - title: The DCP title (used in CPL)
    ///   - resolution: DCP resolution setting
    ///   - frameRate: DCP frame rate setting
    ///   - frameCount: Total number of video frames
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful
    func assembleDCP(
        videoMXFURL: URL,
        audioMXFURL: URL?,
        outputDirectoryURL: URL,
        title: String,
        resolution: DCPResolution,
        frameRate: DCPFrameRate,
        frameCount: Int,
        itemMetadata: DCPItemMetadata? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        logger.info("Assembling DCP: \(title) (\(resolution.shortLabel), \(frameRate.rawValue), \(frameCount) frames)")

        // Generate UUIDs for all assets
        let cplUUID = dcpUUID()
        let pklUUID = dcpUUID()
        let assetMapUUID = dcpUUID()
        let videoUUID = dcpUUID()
        let audioUUID = audioMXFURL != nil ? dcpUUID() : nil

        // Rename MXF files with DCP-standard names (j2c_ for JPEG 2000, pcm_ for PCM audio)
        let videoFileName = "j2c_\(uuidString(from: videoUUID)).mxf"
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
            let audioFN = "pcm_\(uuidString(from: aUUID)).mxf"
            audioFileName = audioFN
            let aDestURL = outputDirectoryURL.appendingPathComponent(audioFN)
            audioDestURL = aDestURL

            do {
                if audioMXF != aDestURL {
                    if FileManager.default.fileExists(atPath: aDestURL.path) {
                        try FileManager.default.removeItem(at: aDestURL)
                    }
                    try FileManager.default.moveItem(at: audioMXF, to: aDestURL)
                }
            } catch {
                logger.error("Failed to move audio MXF: \(error.localizedDescription)")
                return false
            }
        }

        progress(0.2)

        // Compute SHA-1 hashes
        logger.info("Computing SHA-1 hashes...")
        guard let videoHash = computeSHA1(for: videoDestURL) else {
            logger.error("Failed to compute SHA-1 for video MXF")
            return false
        }
        let videoSize = fileSize(at: videoDestURL)

        progress(0.5)

        var audioHash: String? = nil
        var audioSize: Int64? = nil
        if let aDestURL = audioDestURL {
            audioHash = computeSHA1(for: aDestURL)
            audioSize = fileSize(at: aDestURL)
        }

        progress(0.6)

        // Generate XML files
        let editRate = "\(frameRate.editRateNumerator) \(frameRate.editRateDenominator)"
        let dcpFolderName = outputDirectoryURL.lastPathComponent

        // CPL
        let cplFileName = "cpl_\(uuidString(from: cplUUID)).xml"
        let contentKind = itemMetadata?.contentKind ?? .feature
        let annotationText = itemMetadata?.annotationText ?? ""
        let ratingLabel = itemMetadata?.ratingLabel ?? ""
        let audioLanguage = itemMetadata?.audioLanguage ?? "en"

        let cplContent = generateCPL(
            cplUUID: cplUUID,
            title: title,
            dcpFolderName: dcpFolderName,
            editRate: editRate,
            frameCount: frameCount,
            videoUUID: videoUUID,
            audioUUID: audioUUID,
            resolution: resolution,
            contentKind: contentKind,
            annotationText: annotationText,
            ratingLabel: ratingLabel,
            audioLanguage: audioLanguage,
            videoHash: base64SHA1(hex: videoHash),
            audioHash: audioHash.map { base64SHA1(hex: $0) }
        )

        do {
            let cplURL = outputDirectoryURL.appendingPathComponent(cplFileName)
            try cplContent.write(to: cplURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write CPL: \(error.localizedDescription)")
            return false
        }

        progress(0.7)

        // Compute CPL hash
        let cplURL = outputDirectoryURL.appendingPathComponent(cplFileName)
        guard let cplHash = computeSHA1(for: cplURL) else {
            logger.error("Failed to compute SHA-1 for CPL")
            return false
        }
        let cplSize = fileSize(at: cplURL)

        // Compute PKL size for ASSETMAP (need to generate PKL first, write it, then get size)
        let pklFileName = "pkl_\(uuidString(from: pklUUID)).xml"

        // PKL
        let pklContent = generatePKL(
            pklUUID: pklUUID,
            dcpFolderName: dcpFolderName,
            annotationText: annotationText,
            cplUUID: cplUUID,
            cplHash: cplHash,
            cplSize: cplSize,
            cplFileName: cplFileName,
            videoUUID: videoUUID,
            videoHash: videoHash,
            videoSize: videoSize,
            videoFileName: videoFileName,
            audioUUID: audioUUID,
            audioHash: audioHash,
            audioSize: audioSize,
            audioFileName: audioFileName
        )

        do {
            let pklURL = outputDirectoryURL.appendingPathComponent(pklFileName)
            try pklContent.write(to: pklURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write PKL: \(error.localizedDescription)")
            return false
        }

        let pklURL = outputDirectoryURL.appendingPathComponent(pklFileName)
        let pklSize = fileSize(at: pklURL)

        progress(0.8)

        // VOLINDEX
        let volIndexContent = generateVolumeIndex()
        do {
            let volURL = outputDirectoryURL.appendingPathComponent("VOLINDEX.xml")
            try volIndexContent.write(to: volURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write VOLINDEX: \(error.localizedDescription)")
            return false
        }

        // ASSETMAP (SMPTE uses ASSETMAP.xml)
        let assetMapContent = generateAssetMap(
            assetMapUUID: assetMapUUID,
            dcpFolderName: dcpFolderName,
            cplUUID: cplUUID,
            cplFileName: cplFileName,
            cplSize: cplSize,
            pklUUID: pklUUID,
            pklFileName: pklFileName,
            pklSize: pklSize,
            videoUUID: videoUUID,
            videoFileName: videoFileName,
            videoSize: videoSize,
            audioUUID: audioUUID,
            audioFileName: audioFileName,
            audioSize: audioSize
        )

        do {
            let assetMapURL = outputDirectoryURL.appendingPathComponent("ASSETMAP.xml")
            try assetMapContent.write(to: assetMapURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write ASSETMAP: \(error.localizedDescription)")
            return false
        }

        progress(1.0)
        logger.info("DCP assembly complete: \(outputDirectoryURL.lastPathComponent)")
        return true
    }

    // MARK: - ISDCF Folder Name

    /// Generates an ISDCF-style DCP folder name
    /// Format: ContentTitle_ContentType-ReelCount-FrameRate_AspectRatio_Language_Territory_AudioChannels_Resolution_Date_Standard_PackageType
    func isdcfFolderName(
        title: String,
        contentKind: DCPContentKind,
        frameRate: DCPFrameRate,
        resolution: DCPResolution,
        audioLanguage: String
    ) -> String {
        // Sanitize title: uppercase, replace spaces with hyphens, remove special chars
        let sanitizedTitle = title
            .unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-"
            }.map { String($0) }.joined()
            .replacingOccurrences(of: " ", with: "-")

        // Content type abbreviation
        let contentType: String
        switch contentKind {
        case .feature: contentType = "FTR"
        case .trailer: contentType = "TLR"
        case .short: contentType = "SHR"
        case .advertisement: contentType = "ADV"
        case .teaser: contentType = "TSR"
        case .test: contentType = "TST"
        case .rating: contentType = "RTG"
        case .policy: contentType = "POL"
        case .publicService: contentType = "PSA"
        case .transitional: contentType = "XSN"
        }

        // Aspect ratio code
        let aspectRatio: String
        switch resolution {
        case .twoKFlat, .fourKFlat: aspectRatio = "F"
        case .twoKScope, .fourKScope: aspectRatio = "S"
        case .twoKFull, .fourKFull: aspectRatio = "C"
        }

        // Calculate aspect ratio number (width/height * 100, rounded)
        let arNumber = Int(round(Double(resolution.width) / Double(resolution.height) * 100))

        // Language code (uppercase, max 2 chars)
        let langCode = String(audioLanguage.prefix(2)).uppercased()

        // Resolution tier
        let resTier: String
        switch resolution {
        case .twoKFlat, .twoKScope, .twoKFull: resTier = "2K"
        case .fourKFlat, .fourKScope, .fourKFull: resTier = "4K"
        }

        // Date (YYYYMMDD)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStr = dateFormatter.string(from: Date())

        // Build ISDCF name
        // Format: Title_Type-Reels-FPS_Aspect-ARNum_Lang-Territory_AudioConfig_ResTier_Date_Standard_Package
        return "\(sanitizedTitle)_\(contentType)-1-\(frameRate.ffmpegValue)_\(aspectRatio)-\(arNumber)_\(langCode)-XX_20_\(resTier)_\(dateStr)_SMPTE_OV"
    }

    // MARK: - UUID Helpers (delegate to SMPTEPackageUtils)

    private func dcpUUID() -> String { SMPTEPackageUtils.urnUUID() }

    private func uuidString(from urn: String) -> String { SMPTEPackageUtils.uuidString(from: urn) }

    // MARK: - Hash and Size (delegate to SMPTEPackageUtils)

    private func computeSHA1(for url: URL) -> String? { SMPTEPackageUtils.computeSHA1(for: url) }

    private func fileSize(at url: URL) -> Int64 { SMPTEPackageUtils.fileSize(at: url) }

    // MARK: - XML Generation (SMPTE DCP)

    private func generateCPL(
        cplUUID: String,
        title: String,
        dcpFolderName: String,
        editRate: String,
        frameCount: Int,
        videoUUID: String,
        audioUUID: String?,
        resolution: DCPResolution,
        contentKind: DCPContentKind = .feature,
        annotationText: String = "",
        ratingLabel: String = "",
        audioLanguage: String = "en",
        videoHash: String? = nil,
        audioHash: String? = nil
    ) -> String {
        let escapedTitle = xmlEscape(title.isEmpty ? dcpFolderName : title)
        let escapedAnnotation = xmlEscape(annotationText.isEmpty ? dcpFolderName : annotationText)
        let escapedAudioLanguage = xmlEscape(audioLanguage.isEmpty ? "en" : audioLanguage)
        let now = iso8601Now()
        let contentVersionUUID = dcpUUID()

        // Markers (FFOC = first frame, LFOC = last frame)
        let markersUUID = dcpUUID()
        var reelAssets = """
              <MainMarkers>
                <Id>\(markersUUID)</Id>
                <EditRate>\(editRate)</EditRate>
                <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                <MarkerList>
                  <Marker>
                    <Label>FFOC</Label>
                    <Offset>1</Offset>
                  </Marker>
                  <Marker>
                    <Label>LFOC</Label>
                    <Offset>\(max(frameCount - 1, 1))</Offset>
                  </Marker>
                </MarkerList>
              </MainMarkers>
              <MainPicture>
                <Id>\(videoUUID)</Id>
                <EditRate>\(editRate)</EditRate>
                <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                <EntryPoint>0</EntryPoint>
                <Duration>\(frameCount)</Duration>
                <Hash>\(videoHash ?? "")</Hash>
                <FrameRate>\(editRate)</FrameRate>
                <ScreenAspectRatio>\(resolution.width) \(resolution.height)</ScreenAspectRatio>
              </MainPicture>
        """

        if let aUUID = audioUUID {
            reelAssets += """

                  <MainSound>
                    <Id>\(aUUID)</Id>
                    <EditRate>\(editRate)</EditRate>
                    <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                    <EntryPoint>0</EntryPoint>
                    <Duration>\(frameCount)</Duration>
                    <Hash>\(audioHash ?? "")</Hash>
                    <Language>\(escapedAudioLanguage)</Language>
                  </MainSound>
            """
        }

        let ratingElement: String
        if !ratingLabel.isEmpty {
            ratingElement = """
              <RatingList>
                <Rating>
                  <Agency>http://www.mpaa.org/2003-ratings</Agency>
                  <Label>\(xmlEscape(ratingLabel))</Label>
                </Rating>
              </RatingList>
            """
        } else {
            ratingElement = """
              <RatingList/>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <CompositionPlaylist xmlns="http://www.smpte-ra.org/schemas/429-7/2006/CPL">
          <Id>\(cplUUID)</Id>
          <AnnotationText>\(escapedAnnotation)</AnnotationText>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter</Creator>
          <ContentTitleText>\(escapedTitle)</ContentTitleText>
          <ContentKind>\(contentKind.rawValue)</ContentKind>
          <ContentVersion>
            <Id>\(contentVersionUUID)</Id>
            <LabelText>\(escapedTitle)_v1</LabelText>
          </ContentVersion>
        \(ratingElement)
          <ReelList>
            <Reel>
              <Id>\(dcpUUID())</Id>
              <AssetList>
        \(reelAssets)
              </AssetList>
            </Reel>
          </ReelList>
        </CompositionPlaylist>
        """
    }

    private func generatePKL(
        pklUUID: String,
        dcpFolderName: String,
        annotationText: String,
        cplUUID: String,
        cplHash: String,
        cplSize: Int64,
        cplFileName: String,
        videoUUID: String,
        videoHash: String,
        videoSize: Int64,
        videoFileName: String,
        audioUUID: String?,
        audioHash: String?,
        audioSize: Int64?,
        audioFileName: String?
    ) -> String {
        let escapedAnnotation = xmlEscape(annotationText.isEmpty ? dcpFolderName : annotationText)
        let now = iso8601Now()

        var assetList = """
            <Asset>
              <Id>\(cplUUID)</Id>
              <AnnotationText>\(uuidString(from: cplUUID))</AnnotationText>
              <Hash>\(base64SHA1(hex: cplHash))</Hash>
              <Size>\(cplSize)</Size>
              <Type>text/xml</Type>
              <OriginalFileName>\(cplFileName)</OriginalFileName>
            </Asset>
            <Asset>
              <Id>\(videoUUID)</Id>
              <AnnotationText>\(uuidString(from: videoUUID))</AnnotationText>
              <Hash>\(base64SHA1(hex: videoHash))</Hash>
              <Size>\(videoSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(videoFileName)</OriginalFileName>
            </Asset>
        """

        if let aUUID = audioUUID, let aHash = audioHash, let aSize = audioSize, let aFileName = audioFileName {
            assetList += """

            <Asset>
              <Id>\(aUUID)</Id>
              <AnnotationText>\(uuidString(from: aUUID))</AnnotationText>
              <Hash>\(base64SHA1(hex: aHash))</Hash>
              <Size>\(aSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(aFileName)</OriginalFileName>
            </Asset>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <PackingList xmlns="http://www.smpte-ra.org/schemas/429-8/2007/PKL">
          <Id>\(pklUUID)</Id>
          <AnnotationText>\(escapedAnnotation)</AnnotationText>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter</Creator>
          <AssetList>
        \(assetList)
          </AssetList>
        </PackingList>
        """
    }

    private func generateVolumeIndex() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <VolumeIndex xmlns="http://www.smpte-ra.org/schemas/429-9/2007/AM">
          <Index>1</Index>
        </VolumeIndex>
        """
    }

    private func generateAssetMap(
        assetMapUUID: String,
        dcpFolderName: String,
        cplUUID: String,
        cplFileName: String,
        cplSize: Int64,
        pklUUID: String,
        pklFileName: String,
        pklSize: Int64,
        videoUUID: String,
        videoFileName: String,
        videoSize: Int64,
        audioUUID: String?,
        audioFileName: String?,
        audioSize: Int64?
    ) -> String {
        let escapedFolderName = xmlEscape(dcpFolderName)
        let now = iso8601Now()

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
          <AnnotationText>\(escapedFolderName)</AnnotationText>
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

    // MARK: - Helpers (delegate to SMPTEPackageUtils)

    private func xmlEscape(_ string: String) -> String { SMPTEPackageUtils.xmlEscape(string) }

    private func iso8601Now() -> String { SMPTEPackageUtils.iso8601Now() }

    private func base64SHA1(hex: String) -> String { SMPTEPackageUtils.base64SHA1(hex: hex) }
}
