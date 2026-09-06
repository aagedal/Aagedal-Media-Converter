// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

struct ToolDiagnostic: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String?
    let architecture: String
    let executable: Bool
    let version: String?
    let failure: String?
    var note: String? = nil
}

/// Read-only, bounded checks of the same selected tools used by conversion services.
struct ToolDiagnostics: Sendable {
    private let runner: any SubprocessRunning

    init(runner: any SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
    }

    /// Version flags are restricted to those verified by the dependency manifest.
    /// AVM and Parakeet are inspected without launch: guessing a version flag can
    /// enter their conversion/transcription flows or initialize model dependencies.
    static var helperChecks: [(id: String, name: String, path: String?, arguments: [String]?)] {
        [
            ("bmxtranswrap", "BMX transwrap", BinaryPathResolver.bmxtranswrapPath, ["--version"]),
            ("mxf2raw", "BMX mxf2raw", BinaryPathResolver.mxf2rawPath, ["--version"]),
            ("raw2bmx", "BMX raw2bmx", BinaryPathResolver.raw2bmxPath, ["--version"]),
            ("asdcp-wrap", "AS-DCP wrap", BinaryPathResolver.asdcpWrapPath, ["-V"]),
            ("avmenc", "AV2 encoder", BinaryPathResolver.avmencPath, nil),
            ("avmdec", "AV2 decoder", BinaryPathResolver.avmdecPath, nil),
            ("parakeet", "Parakeet MLX", BinaryPathResolver.parakeetMlxPath, nil)
        ]
    }

    func check(
        id: String,
        name: String,
        path: String?,
        arguments: [String]? = ["--version"],
        configuration: HomebrewPythonExecutor.ToolExecutionConfiguration? = nil
    ) async throws -> ToolDiagnostic {
        try Task.checkCancellation()
        guard let path else {
            return ToolDiagnostic(id: id, name: name, path: nil, architecture: "—", executable: false,
                                  version: nil, failure: String(localized: "No executable is available from the selected source. Check this tool’s settings."))
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let regularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        let executable = regularFile && FileManager.default.isExecutableFile(atPath: path)
        let header = Self.header(at: url) ?? Data()
        let architecture = Self.architecture(header: header)
        guard executable else {
            return ToolDiagnostic(id: id, name: name, path: path, architecture: architecture, executable: false,
                                  version: nil, failure: String(localized: "The selected file is missing or is not executable."))
        }
        if Self.isKnownIncompatible(header: header) {
            return ToolDiagnostic(id: id, name: name, path: path, architecture: architecture,
                                  executable: true, version: nil,
                                  failure: String(localized: "The selected tool’s architecture is not supported on this Mac. Choose a compatible binary or reinstall the app."))
        }
        guard let arguments else {
            return ToolDiagnostic(id: id, name: name, path: path, architecture: architecture,
                                  executable: true, version: nil, failure: nil,
                                  note: String(localized: "Availability and architecture checked. This helper does not have a verified read-only version check."))
        }
        let request = SubprocessRequest(
            executableURL: configuration?.executableURL ?? URL(fileURLWithPath: path),
            arguments: configuration?.arguments ?? arguments,
            environment: configuration?.environment,
            timeout: .seconds(5),
            standardOutputCaptureLimit: 16 * 1024,
            standardErrorCaptureLimit: 16 * 1024,
            sensitiveValues: [path, configuration?.executableURL.path ?? path]
        )
        var version: String?
        var failure: String?
        do {
            let result = try await runner.run(request)
            try Task.checkCancellation()
            if result.succeeded && result.discardedStandardOutputBytes == 0 && result.discardedStandardErrorBytes == 0 {
                let output = result.standardOutput.isEmpty ? result.standardErrorText : result.standardOutputText
                version = output.split(whereSeparator: \.isNewline).first.map { String($0.prefix(300)) }
                if version == nil {
                    failure = String(localized: "The tool exited successfully without version information.")
                }
            } else {
                failure = String(localized: "The version check failed. Review the selected binary in this tool’s settings.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch SubprocessRunnerError.timedOut {
            try Task.checkCancellation()
            failure = String(localized: "The tool could not complete its version check within five seconds. Check its permissions and dependencies.")
        } catch {
            try Task.checkCancellation()
            failure = String(localized: "The tool could not be launched. Check its architecture, permissions, interpreter, and dependencies.")
        }
        return ToolDiagnostic(id: id, name: name, path: path, architecture: architecture,
                              executable: executable, version: version, failure: failure)
    }

    /// O_NONBLOCK prevents a path replaced with a FIFO between stat and open from
    /// blocking. Check the opened descriptor again before reading any bytes.
    static func header(at url: URL) -> Data? {
        var metadata = stat()
        guard stat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &bytes, bytes.count)
        guard count >= 0 else { return nil }
        return Data(bytes.prefix(count))
    }

    static func architecture(at url: URL) -> String {
        architecture(header: header(at: url) ?? Data())
    }

    enum HostArchitecture: Sendable {
        case arm64, x86_64, unknown

        static var current: Self {
            // Query hardware rather than only the build architecture: an x86_64
            // app running through Rosetta can still launch native arm64 helpers.
            var arm64: Int32 = 0
            var size = MemoryLayout.size(ofValue: arm64)
            if sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0, arm64 == 1 {
                return .arm64
            }
            #if arch(arm64)
            return .arm64
            #elseif arch(x86_64)
            return .x86_64
            #else
            return .unknown
            #endif
        }
    }

    /// Reject only understood Mach-O CPU lists that have no usable slice.
    /// Scripts/unknown formats are left to the launcher. x86_64 on Apple Silicon
    /// remains eligible for Rosetta; its installation is not inferred here.
    static func isKnownIncompatible(header: Data, host: HostArchitecture = .current) -> Bool {
        guard let cpus = machOCPUs(header: header),
              cpus.allSatisfy({ [UInt32(0x0100000c), 0x01000007, 12, 7].contains($0) }) else { return false }
        switch host {
        case .arm64: return !cpus.contains(0x0100000c) && !cpus.contains(0x01000007)
        case .x86_64: return !cpus.contains(0x01000007)
        case .unknown: return false
        }
    }

    static func architecture(header: Data) -> String {
        if header.starts(with: [0x23, 0x21]) { return String(localized: "Script (interpreter-dependent)") }
        guard let cpus = machOCPUs(header: header) else { return String(localized: "Unknown") }
        return cpus.map { cpu in
            switch cpu {
            case 0x0100000c: return "arm64"
            case 0x01000007: return "x86_64"
            case 12: return "arm"
            case 7: return "i386"
            default: return String(localized: "Unknown")
            }
        }.joined(separator: ", ")
    }

    /// Recognizes thin/fat Mach-O headers without loading the binary or reading it in full.
    private static func machOCPUs(header: Data) -> [UInt32]? {
        let bytes = Array(header)
        guard bytes.count >= 8 else { return nil }
        func word(_ offset: Int, littleEndian: Bool) -> UInt32 {
            let slice = bytes[offset..<(offset + 4)]
            return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let magic = word(0, littleEndian: false)
        switch magic {
        case 0xcefaedfe, 0xcffaedfe: return [word(4, littleEndian: true)]
        case 0xfeedface, 0xfeedfacf: return [word(4, littleEndian: false)]
        case 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca:
            let littleEndian = magic == 0xbebafeca || magic == 0xbfbafeca
            let count = Int(word(4, littleEndian: littleEndian))
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            guard count > 0, count <= (bytes.count - 8) / stride else { return nil }
            return (0..<count).map { word(8 + $0 * stride, littleEndian: littleEndian) }
        default: return nil
        }
    }
}
