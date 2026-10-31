// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

/// One `c2pa.actions` entry: what was done to the asset, and with which tool.
struct C2PAActionInfo: Codable, Sendable, Equatable {
    /// Raw action, e.g. "c2pa.color_adjustments".
    let action: String
    let softwareAgent: String?
    let digitalSourceType: String?
    let description: String?

    var displayName: String { C2PAFormatting.actionName(action) }

    /// "Color Adjustments — Adobe Premiere Pro 25.1 (Generative fill)".
    var summary: String {
        var text = displayName
        if let softwareAgent, !softwareAgent.isEmpty { text += " — \(softwareAgent)" }
        if let description, !description.isEmpty { text += " (\(description))" }
        return text
    }
}

/// An asset this one was made from (`c2pa.ingredient`).
struct C2PAIngredientInfo: Codable, Sendable, Equatable {
    let title: String?
    let format: String?
    /// "parentOf", "componentOf" or "inputTo".
    let relationship: String?

    var summary: String {
        let details = [
            format.map(C2PAFormatting.mimeName),
            relationship.map(C2PAFormatting.relationshipName)
        ].compactMap { $0 }
        let name = title ?? "Untitled"
        return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
    }
}

/// Who signed the manifest, read from its certificate chain. This is presence information
/// only: the app does not verify the signature or check the signer against a trust list.
struct C2PASignatureInfo: Codable, Sendable, Equatable {
    let signer: String?
    let signerOrganization: String?
    let issuer: String?
    let algorithm: String?
    /// Time from the RFC 3161 time-stamp token, when the signature carries one.
    let timestamp: Date?
    let hasTimestamp: Bool
    let certificateExpiry: Date?

    var signerDescription: String? {
        switch (signer, signerOrganization) {
        case let (name?, org?) where name != org: return "\(name) (\(org))"
        case let (name?, _): return name
        case let (nil, org?): return org
        default: return nil
        }
    }
}

/// A `c2pa.training-mining` declaration, e.g. generative AI training not allowed.
struct C2PATrainingPermission: Codable, Sendable, Equatable {
    let category: String
    let use: String
    let constraintInfo: String?

    var summary: String {
        var text = "\(C2PAFormatting.trainingCategoryName(category)): \(C2PAFormatting.trainingUseName(use))"
        if let constraintInfo, !constraintInfo.isEmpty { text += " (\(constraintInfo))" }
        return text
    }
}

/// One step in the provenance chain (one manifest in the store).
struct C2PAManifestSummary: Codable, Sendable, Equatable {
    let label: String
    let generator: String?
    let signer: String?
    let actions: [String]

    var summary: String {
        var text = generator ?? "Unknown app"
        if !actions.isEmpty { text += ": " + actions.joined(separator: ", ") }
        if let signer { text += " — signed by \(signer)" }
        return text
    }
}

/// Human-readable names for C2PA and IPTC vocabulary.
enum C2PAFormatting {
    static func actionName(_ raw: String) -> String {
        let known: [String: String] = [
            "c2pa.created": "Created",
            "c2pa.opened": "Opened",
            "c2pa.placed": "Placed",
            "c2pa.edited": "Edited",
            "c2pa.edited.metadata": "Edited Metadata",
            "c2pa.cropped": "Cropped",
            "c2pa.resized": "Resized",
            "c2pa.orientation": "Rotated or Flipped",
            "c2pa.color_adjustments": "Color Adjustments",
            "c2pa.filtered": "Filtered",
            "c2pa.drawing": "Drawn On",
            "c2pa.converted": "Converted",
            "c2pa.transcoded": "Transcoded",
            "c2pa.repackaged": "Repackaged",
            "c2pa.published": "Published",
            "c2pa.removed": "Removed Content",
            "c2pa.redacted": "Redacted",
            "c2pa.watermarked": "Watermarked",
            "c2pa.watermarked.bound": "Watermarked",
            "c2pa.watermarked.unbound": "Watermarked",
            "c2pa.unknown": "Unknown Edits"
        ]
        if let name = known[raw] { return name }
        let stripped = raw.hasPrefix("c2pa.") ? String(raw.dropFirst(5)) : raw
        return stripped.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ").capitalized
    }

    /// Accepts the full IPTC URI or its last path component.
    static func digitalSourceTypeName(_ raw: String) -> String {
        let key = raw.split(separator: "/").last.map(String.init) ?? raw
        let known: [String: String] = [
            "digitalCapture": "Digital Capture",
            "computationalCapture": "Computational Capture",
            "negativeFilm": "Scanned Negative",
            "positiveFilm": "Scanned Positive",
            "print": "Scanned Print",
            "humanEdits": "Human-Edited",
            "minorHumanEdits": "Minor Human Edits",
            "compositeWithTrainedAlgorithmicMedia": "Edited Using Generative AI",
            "algorithmicallyEnhanced": "Algorithmically Altered",
            "digitalCreation": "Digital Creation",
            "digitalArt": "Digital Art",
            "dataDrivenMedia": "Data-Driven Media",
            "trainedAlgorithmicMedia": "Created Using Generative AI",
            "algorithmicMedia": "Pure Algorithmic Media",
            "screenCapture": "Screen Capture",
            "virtualRecording": "Virtual Event Recording",
            "composite": "Composite (Unspecified Elements)",
            "compositeCapture": "Composite (Capture)",
            "compositeSynthetic": "Composite (Includes Generative AI)"
        ]
        return known[key] ?? key
    }

    /// True for source types that declare generative AI involvement.
    static func isGenerativeAI(_ raw: String) -> Bool {
        let key = raw.split(separator: "/").last.map(String.init) ?? raw
        return ["trainedAlgorithmicMedia", "compositeWithTrainedAlgorithmicMedia", "compositeSynthetic"].contains(key)
    }

    static func mimeName(_ mime: String) -> String {
        let known: [String: String] = [
            "video/mp4": "MP4", "video/quicktime": "QuickTime", "video/x-m4v": "M4V",
            "audio/mp4": "MPEG-4 Audio", "audio/mpeg": "MP3", "audio/wav": "WAV", "audio/x-wav": "WAV",
            "image/jpeg": "JPEG", "image/png": "PNG", "image/heic": "HEIC", "image/heif": "HEIF",
            "image/tiff": "TIFF", "image/webp": "WebP", "image/avif": "AVIF", "image/x-adobe-dng": "DNG"
        ]
        if let name = known[mime.lowercased()] { return name }
        guard let slash = mime.firstIndex(of: "/") else { return mime }
        return String(mime[mime.index(after: slash)...]).uppercased()
    }

    static func relationshipName(_ raw: String) -> String {
        switch raw {
        case "parentOf": return "source"
        case "componentOf": return "component"
        case "inputTo": return "input"
        default: return raw
        }
    }

    static func trainingCategoryName(_ raw: String) -> String {
        switch raw {
        case "c2pa.ai_generative_training", "cawg.ai_generative_training": return "Generative AI training"
        case "c2pa.ai_training", "cawg.ai_training": return "AI training"
        case "c2pa.ai_inference", "cawg.ai_inference": return "AI inference"
        case "c2pa.data_mining", "cawg.data_mining": return "Data mining"
        default: return actionName(raw)
        }
    }

    static func trainingUseName(_ raw: String) -> String {
        switch raw {
        case "allowed": return "Allowed"
        case "notAllowed": return "Not allowed"
        case "constrained": return "Constrained"
        default: return raw
        }
    }
}

/// Reads signer details from a C2PA COSE certificate chain (DER, leaf first).
enum C2PACertificateReader {
    struct Details {
        var commonName: String?
        var organization: String?
        var issuer: String?
        var expiry: Date?
    }

    static func details(fromChain chain: [Data]) -> Details {
        var details = Details()
        guard let leafData = chain.first,
              let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else { return details }
        details.commonName = SecCertificateCopySubjectSummary(leaf) as String?
        details.organization = nameComponent(kSecOIDOrganizationName, of: kSecOIDX509V1SubjectName, in: leaf)
        details.issuer = nameComponent(kSecOIDOrganizationName, of: kSecOIDX509V1IssuerName, in: leaf)
            ?? nameComponent(kSecOIDCommonName, of: kSecOIDX509V1IssuerName, in: leaf)
        details.expiry = SecCertificateCopyNotValidAfterDate(leaf) as Date?
        return details
    }

    /// Pulls one attribute (e.g. O=) out of a certificate's subject or issuer name.
    private static func nameComponent(_ attribute: CFString, of name: CFString, in certificate: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(certificate, [name] as CFArray, nil) as? [String: Any],
              let nameEntry = values[name as String] as? [String: Any],
              let parts = nameEntry[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        for part in parts where (part[kSecPropertyKeyLabel as String] as? String) == attribute as String {
            if let value = part[kSecPropertyKeyValue as String] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

/// Extracts the signing time from an RFC 3161 time-stamp token without full CMS parsing.
/// The token's TSTInfo (which holds `genTime`) precedes its certificates, so the first
/// well-formed DER GeneralizedTime is the time-stamp.
enum C2PATimestampReader {
    static func signingTime(fromToken token: Data) -> Date? {
        let bytes = [UInt8](token)
        var index = 0
        while index + 2 < bytes.count {
            // GeneralizedTime: tag 0x18, short-form length 15…24 ("YYYYMMDDHHMMSS[.fff]Z").
            if bytes[index] == 0x18 {
                let length = Int(bytes[index + 1])
                let start = index + 2
                if (15...24).contains(length), start + length <= bytes.count,
                   let text = String(bytes: bytes[start..<(start + length)], encoding: .ascii),
                   let date = parse(text) {
                    return date
                }
            }
            index += 1
        }
        return nil
    }

    private static func parse(_ text: String) -> Date? {
        guard text.hasSuffix("Z") else { return nil }
        let body = text.dropLast()
        let whole = body.split(separator: ".", maxSplits: 1).first.map(String.init) ?? String(body)
        guard whole.count == 14, whole.allSatisfy(\.isNumber) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        guard let date = formatter.date(from: whole) else { return nil }
        // Reject implausible matches (e.g. stray bytes that happen to look like a time).
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return (2000...2100).contains(year) ? date : nil
    }
}

/// Rows shown for Content Credentials in the metadata window and PDF export, in order.
enum C2PADisplayField: CaseIterable {
    case signedBy, issuer, signedAt, algorithm, certificateExpiry
    case app, claimGenerator, title, format, authors, copyright
    case sourceType, actions, ingredients, trainingMining, identity, redactions
    case history, manifest, assertions

    var label: String {
        switch self {
        case .signedBy: return "Signed By"
        case .issuer: return "Certificate Issuer"
        case .signedAt: return "Signed At"
        case .algorithm: return "Signature Algorithm"
        case .certificateExpiry: return "Certificate Valid Until"
        case .app: return "App or Device"
        case .claimGenerator: return "Claim Generator"
        case .title: return "Title"
        case .format: return "Format"
        case .authors: return "Author"
        case .copyright: return "Copyright"
        case .sourceType: return "Source Type"
        case .actions: return "Actions"
        case .ingredients: return "Ingredients"
        case .trainingMining: return "AI Training and Mining"
        case .identity: return "Identity Assertion"
        case .redactions: return "Redactions"
        case .history: return "Edit History"
        case .manifest: return "Active Manifest"
        case .assertions: return "Assertions"
        }
    }
}

extension C2PAMetadata {
    /// "Adobe Premiere Pro 25.1", falling back to the raw claim generator string.
    var appDescription: String? {
        if let name = claimGeneratorInfoName, !name.isEmpty {
            return [name, claimGeneratorVersion].compactMap { $0 }.joined(separator: " ")
        }
        return claimGenerator
    }

    func displayValue(for field: C2PADisplayField) -> String? {
        guard hasContentCredentials else { return nil }
        switch field {
        case .signedBy:
            guard hasSignature else { return "Not signed" }
            return signature?.signerDescription ?? "Signed (signer not readable)"
        case .issuer:
            return signature?.issuer
        case .signedAt:
            if let timestamp = signature?.timestamp { return Self.dateFormatter.string(from: timestamp) + " (time-stamped)" }
            return signature?.hasTimestamp == true ? "Time-stamped" : nil
        case .algorithm:
            return signature?.algorithm
        case .certificateExpiry:
            return signature?.certificateExpiry.map(Self.dateFormatter.string(from:))
        case .app:
            return appDescription
        case .claimGenerator:
            // Only worth a row when it says more than the app name and version.
            guard let claimGenerator, claimGenerator != appDescription else { return nil }
            return claimGenerator
        case .title:
            return title
        case .format:
            return format.map { "\(C2PAFormatting.mimeName($0)) (\($0))" }
        case .authors:
            return authors?.joined(separator: ", ")
        case .copyright:
            return copyright
        case .sourceType:
            return digitalSourceType.map(C2PAFormatting.digitalSourceTypeName)
        case .actions:
            if let actions, !actions.isEmpty { return actions.map(\.summary).joined(separator: "\n") }
            return actionsAction.map(C2PAFormatting.actionName)
        case .ingredients:
            return ingredients?.map(\.summary).joined(separator: "\n")
        case .trainingMining:
            return trainingMining?.map(\.summary).joined(separator: "\n")
        case .identity:
            return hasIdentityAssertion == true ? "Present (CAWG identity)" : nil
        case .redactions:
            return redactionCount.map { $0 == 1 ? "1 assertion redacted" : "\($0) assertions redacted" }
        case .history:
            guard let history, history.count > 1 else { return nil }
            return history.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
        case .manifest:
            return manifestStore
        case .assertions:
            return assertions?.joined(separator: ", ")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
