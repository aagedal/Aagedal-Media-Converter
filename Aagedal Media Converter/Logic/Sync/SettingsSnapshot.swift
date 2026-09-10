// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// A portable, versioned snapshot of the user's syncable settings.
///
/// Serialized to a single JSON file that powers all three sync modes: iCloud
/// Drive (a file in `~/Library/Mobile Documents/com~apple~CloudDocs`), a custom
/// folder, and manual export/import. Only allowlisted keys are captured — see
/// `SettingsSyncKeys` — so machine-specific data (folder paths, security-scoped
/// bookmarks, binary install state) never crosses devices.
struct SettingsSnapshot: Codable {
    /// Bumped only on incompatible format changes. Imports with a higher version
    /// than this app understands are rejected rather than partially applied.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// `CFBundleShortVersionString` of the app that wrote the snapshot (informational).
    var appVersion: String
    /// Human-readable name of the writing Mac, surfaced in the "updated from X" notice.
    var deviceName: String
    /// When the snapshot was written. Drives newest-wins conflict resolution.
    var modifiedAt: Date
    /// Allowlisted UserDefaults key → value.
    var defaults: [String: JSONValue]

    init(defaults: [String: JSONValue], modifiedAt: Date) {
        self.schemaVersion = SettingsSnapshot.currentSchemaVersion
        self.appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        self.deviceName = Host.current().localizedName ?? "Unknown Mac"
        self.modifiedAt = modifiedAt
        self.defaults = defaults
    }
}

/// A JSON-codable wrapper for the plist-scalar value types stored in
/// `UserDefaults` (string, bool, int, double, plus arrays/dictionaries of the
/// same). Lets mixed-type settings round-trip cleanly through JSON.
enum JSONValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    // MARK: - Bridging to/from UserDefaults values

    /// Converts a value read from `UserDefaults` into a `JSONValue`, or `nil`
    /// for unsupported types (e.g. `Data`, which is never allowlisted).
    static func from(_ any: Any) -> JSONValue? {
        // NSNumber covers Bool, Int and Double after Swift bridging. Booleans
        // must be detected first via CFBoolean, otherwise `true` would be
        // captured as the integer 1 and lose its type on the other device.
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                guard number.doubleValue.isFinite else { return nil }
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        }
        if let string = any as? String {
            return .string(string)
        }
        if let array = any as? [Any] {
            var values: [JSONValue] = []
            for value in array {
                guard let converted = JSONValue.from(value) else { return nil }
                values.append(converted)
            }
            return .array(values)
        }
        if let dict = any as? [String: Any] {
            var object: [String: JSONValue] = [:]
            for (key, value) in dict {
                guard let converted = JSONValue.from(value) else { return nil }
                object[key] = converted
            }
            return .object(object)
        }
        return nil
    }

    /// Nested nulls cannot be stored in UserDefaults. Only a top-level null is
    /// supported by the snapshot format, where it explicitly removes a key.
    var isPropertyListCompatible: Bool {
        switch self {
        case .string, .bool, .int: return true
        case .double(let value): return value.isFinite
        case .array(let values): return values.allSatisfy(\.isPropertyListCompatible)
        case .object(let values): return values.values.allSatisfy(\.isPropertyListCompatible)
        case .null: return false
        }
    }

    /// The plain value suitable for `UserDefaults.set(_:forKey:)`. `null` maps to
    /// `NSNull`; callers should treat that as "remove the key" instead of storing it.
    var propertyListValue: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .array(let values): return values.map { $0.propertyListValue }
        case .object(let values): return values.mapValues { $0.propertyListValue }
        case .null: return NSNull()
        }
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value in settings snapshot"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
