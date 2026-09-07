#!/usr/bin/env swift
// Verify the distributed archive against the public key embedded in the app.
import Foundation
import CryptoKit

func verify() throws {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "ReleaseSignature", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Usage: verify-update-signature.swift ARCHIVE INFO_PLIST SIGNATURE"])
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let plist = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
          let encodedKey = info["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: encodedKey),
          let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
        throw NSError(domain: "ReleaseSignature", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "Missing or malformed Sparkle public key or signature"])
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "ReleaseSignature", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "Update signature does not match the archive and the app's SUPublicEDKey"])
    }
}

do {
    try verify()
    print("Verified update signature against the exported app's public key")
} catch {
    FileHandle.standardError.write(Data("Release signature validation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
