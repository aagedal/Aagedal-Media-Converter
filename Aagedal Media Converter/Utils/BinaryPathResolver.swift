// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

enum BinarySourceSelection: String, CaseIterable {
    case app
    case homebrew
    case custom
}

enum BinaryVersionOutputStream: Sendable {
    case standardOutput
    case standardError
}

/// Bounded subprocess boundary for lightweight version checks shared by binary
/// settings panes. Some tools report their version on stdout while others use
/// stderr, so the expected stream is explicit instead of inferred from output.
struct BinaryVersionProbe: Sendable {
    static let timeout: Duration = .seconds(5)
    static let captureLimit = 64 * 1024

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func firstLine(
        at path: String,
        arguments: [String],
        outputStream: BinaryVersionOutputStream
    ) async -> String? {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            timeout: Self.timeout,
            standardOutputCaptureLimit: Self.captureLimit,
            standardErrorCaptureLimit: Self.captureLimit,
            sensitiveValues: [path]
        )

        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else { return nil }

            let data: Data
            switch outputStream {
            case .standardOutput:
                guard result.discardedStandardOutputBytes == 0 else { return nil }
                data = result.standardOutput
            case .standardError:
                guard result.discardedStandardErrorBytes == 0 else { return nil }
                data = result.standardError
            }

            let firstLine = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return firstLine.isEmpty ? nil : firstLine
        } catch {
            return nil
        }
    }
}

/// Resolves paths to external binaries (ffmpeg, ffprobe, yt-dlp)
/// Priority: 1) Custom path from settings, 2) Bundled in app
enum BinaryPathResolver {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "BinaryPathResolver")

    // MARK: - FFmpeg

    /// Resolves the path to ffmpeg binary
    /// Priority: custom path > bundled
    static var ffmpegPath: String? {
        if let selection = selectedFFmpegSource() {
            switch selection {
            case .custom:
                return resolveCustomFFmpegPath()
            case .homebrew:
                return resolveHomebrewFFmpegPath()
            case .app:
                return resolveBundledFFmpegPath()
            }
        }

        // Check custom path first
        if let customPath = resolveCustomFFmpegPath() {
            return customPath
        }

        // Fall back to bundled
        return resolveBundledFFmpegPath()
    }

    // MARK: - BMX Tools (MXF handling)

    /// Resolves the path to bmxtranswrap binary (MXF transcoding)
    static var bmxtranswrapPath: String? {
        Bundle.main.path(forResource: "bmxtranswrap", ofType: nil)
    }

    /// Resolves the path to mxf2raw binary (MXF extraction/analysis)
    static var mxf2rawPath: String? {
        Bundle.main.path(forResource: "mxf2raw", ofType: nil)
    }

    /// Resolves the path to asdcp-wrap binary (DCP-compliant MXF audio wrapping)
    static var asdcpWrapPath: String? {
        Bundle.main.path(forResource: "asdcp-wrap", ofType: nil)
    }

    /// Resolves the path to raw2bmx binary (IMF App #2e J2C → MXF wrapping with full picture descriptor)
    static var raw2bmxPath: String? {
        Bundle.main.path(forResource: "raw2bmx", ofType: nil)
    }

    // MARK: - AV2 (experimental)

    /// Resolves the path to the bundled avmenc binary (AOM AVM reference AV2 encoder).
    /// Bundled-only — there is no homebrew/custom override for this experimental encoder.
    static var avmencPath: String? {
        Bundle.main.path(forResource: "avmenc", ofType: nil)
    }

    /// Resolves the path to the bundled avmdec binary (AOM AVM reference AV2 decoder).
    /// Used to decode AV2 `.ivf` sources to raw frames piped into FFmpeg.
    static var avmdecPath: String? {
        Bundle.main.path(forResource: "avmdec", ofType: nil)
    }

    // MARK: - Version Info

    /// Gets the version of a binary by running it with --version
    static func getVersion(at path: String) async -> String? {
        await BinaryVersionProbe().firstLine(
            at: path,
            arguments: ["-version"],
            outputStream: .standardOutput
        )
    }

    /// Gets ffmpeg version string
    static func getFFmpegVersion() async -> String? {
        guard let path = ffmpegPath else { return nil }
        return await getVersion(at: path)
    }

    // MARK: - Path Info

    /// Returns whether a custom ffmpeg path is configured
    static var isUsingCustomFFmpeg: Bool {
        guard let customPath = UserDefaults.standard.string(forKey: AppConstants.customFFmpegPathKey),
              !customPath.isEmpty else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: customPath)
    }

    /// Saves a custom ffmpeg path
    static func saveCustomFFmpegPath(_ path: String?) {
        if let path = path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: AppConstants.customFFmpegPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.customFFmpegPathKey)
        }
    }

    // MARK: - Source Selection Helpers

    private static func selectedFFmpegSource() -> BinarySourceSelection? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppConstants.ffmpegBinarySourceKey),
              !rawValue.isEmpty else {
            return nil
        }
        return BinarySourceSelection(rawValue: rawValue)
    }

    private static func resolveCustomFFmpegPath() -> String? {
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.customFFmpegPathKey),
           !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }
        return nil
    }

    private static func resolveHomebrewFFmpegPath() -> String? {
        let homebrewPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]
        for path in homebrewPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func resolveBundledFFmpegPath() -> String? {
        Bundle.main.path(forResource: "ffmpeg", ofType: nil)
    }

    // MARK: - Tesseract

    /// Resolves the path to the tesseract binary.
    /// Priority: custom path > Homebrew > bundled
    static var tesseractPath: String? {
        if let selection = selectedTesseractSource() {
            switch selection {
            case .custom:
                return resolveCustomTesseractPath()
            case .homebrew:
                return resolveHomebrewTesseractPath()
            case .app:
                return resolveBundledTesseractPath()
            }
        }
        // Auto-detection fallback: bundled > Homebrew
        if let bundled = resolveBundledTesseractPath() { return bundled }
        return resolveHomebrewTesseractPath()
    }

    /// Resolves the tessdata directory to pass as TESSDATA_PREFIX.
    /// Priority: user Application Support tessdata > bundled Resources/tessdata > Homebrew tessdata
    static var tessdataDirectory: String? {
        let candidates: [String] = [
            AppConstants.tesseractTessdataDirectory.path,
            Bundle.main.path(forResource: "tessdata", ofType: nil) ?? "",
            "/opt/homebrew/share/tessdata",
            "/usr/local/share/tessdata",
        ]
        return candidates.first { path in
            !path.isEmpty &&
            ((try? FileManager.default.contentsOfDirectory(atPath: path)
                .contains { $0.hasSuffix(".traineddata") }) ?? false)
        }
    }

    /// Returns the tesseract version string
    static func getTesseractVersion() async -> String? {
        guard let path = tesseractPath else { return nil }
        return await BinaryVersionProbe().firstLine(
            at: path,
            arguments: ["--version"],
            outputStream: .standardOutput
        )
    }

    private static func selectedTesseractSource() -> BinarySourceSelection? {
        guard let raw = UserDefaults.standard.string(forKey: AppConstants.tesseractBinarySourceKey),
              !raw.isEmpty else { return nil }
        return BinarySourceSelection(rawValue: raw)
    }

    private static func resolveCustomTesseractPath() -> String? {
        if let path = UserDefaults.standard.string(forKey: AppConstants.tesseractCustomPathKey),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func resolveHomebrewTesseractPath() -> String? {
        let candidates = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func resolveBundledTesseractPath() -> String? {
        Bundle.main.path(forResource: "tesseract", ofType: nil)
    }

    // MARK: - SSIMULACRA2

    /// Resolves the path to the ssimulacra2_rs binary.
    /// Priority: custom path > cargo bin > bundled
    static var ssimulacra2Path: String? {
        if let customPath = resolveCustomSSIMULACRA2Path() {
            return customPath
        }
        if let cargoPath = resolveCargoSSIMULACRA2Path() {
            return cargoPath
        }
        return resolveBundledSSIMULACRA2Path()
    }

    /// Returns whether ssimulacra2_rs is available
    static var isSSIMULACRA2Available: Bool {
        ssimulacra2Path != nil
    }

    /// Saves a custom ssimulacra2_rs path
    static func saveCustomSSIMULACRA2Path(_ path: String?) {
        if let path = path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: AppConstants.ssimulacra2CustomPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.ssimulacra2CustomPathKey)
        }
    }

    private static func resolveCustomSSIMULACRA2Path() -> String? {
        if let path = UserDefaults.standard.string(forKey: AppConstants.ssimulacra2CustomPathKey),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func resolveCargoSSIMULACRA2Path() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(homeDir)/.cargo/bin/ssimulacra2_rs",
            "/opt/homebrew/bin/ssimulacra2_rs",
            "/usr/local/bin/ssimulacra2_rs"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func resolveBundledSSIMULACRA2Path() -> String? {
        Bundle.main.path(forResource: "ssimulacra2_rs", ofType: nil)
    }

    // MARK: - Parakeet-MLX

    /// Resolves the path to the parakeet-mlx binary.
    /// Priority: custom path > common pip/uv/Homebrew locations
    static var parakeetMlxPath: String? {
        // 1. Custom path from settings
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.parakeetCustomPathKey),
           !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }

        // 2. Common pip/uv/Homebrew install locations
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(homeDir)/.local/bin/parakeet-mlx",
            "/opt/homebrew/bin/parakeet-mlx",
            "/usr/local/bin/parakeet-mlx",
            "\(homeDir)/.cargo/bin/parakeet-mlx",
            "\(homeDir)/Library/Python/3.14/bin/parakeet-mlx",
            "\(homeDir)/Library/Python/3.13/bin/parakeet-mlx",
            "\(homeDir)/Library/Python/3.12/bin/parakeet-mlx",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns whether a custom parakeet-mlx path is configured
    static var isUsingCustomParakeetMlx: Bool {
        guard let customPath = UserDefaults.standard.string(forKey: AppConstants.parakeetCustomPathKey),
              !customPath.isEmpty else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: customPath)
    }

    /// Saves a custom parakeet-mlx path
    static func saveCustomParakeetMlxPath(_ path: String?) {
        if let path = path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: AppConstants.parakeetCustomPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.parakeetCustomPathKey)
        }
    }

    /// Gets parakeet-mlx version string
    static func getParakeetMlxVersion() async -> String? {
        guard let path = parakeetMlxPath else { return nil }
        return await getVersion(at: path)
    }
}

// MARK: - Homebrew Python Script Executor

/// Helper to detect and execute Homebrew Python scripts (like yt-dlp) properly
/// Homebrew installs Python tools with venv interpreters that may be blocked by Hardened Runtime.
/// This helper detects such scripts and executes them using the main Homebrew Python instead.
enum HomebrewPythonExecutor {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "HomebrewPythonExecutor")

    private static let commonPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin"
    ]

    private static func mergedPath(from entries: [String]) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !seen.contains(trimmed) {
                result.append(trimmed)
                seen.insert(trimmed)
            }
        }
        return result.joined(separator: ":")
    }

    /// Execution info for a Homebrew Python script
    struct ExecutionInfo {
        let pythonPath: String      // The venv Python from shebang
        let mainPythonPath: String  // Main Homebrew Python to use
        let sitePackages: String    // PYTHONPATH to set
    }

    /// Checks if a script is a Homebrew Python script and returns execution info
    static func executionInfo(for scriptPath: String) -> ExecutionInfo? {
        // Read the shebang line - resolve symlinks first
        let resolvedPath = (scriptPath as NSString).resolvingSymlinksInPath

        guard let data = FileManager.default.contents(atPath: resolvedPath),
              let content = String(data: data, encoding: .utf8) else {
            logger.error("Failed to read file at: \(resolvedPath, privacy: .public)")
            return nil
        }

        let firstLine = content.components(separatedBy: .newlines).first ?? ""
        logger.debug("First line: \(firstLine, privacy: .public)")

        // Check if it's a Homebrew Cellar Python shebang
        // e.g., #!/opt/homebrew/Cellar/yt-dlp/2025.12.8/libexec/bin/python
        guard firstLine.hasPrefix("#!"),
              firstLine.contains("/opt/homebrew/Cellar/") else {
            logger.debug("Not a Homebrew Python script")
            return nil
        }

        // Extract the Cellar path (e.g., /opt/homebrew/Cellar/yt-dlp/2025.12.8)
        let shebangPath = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        logger.debug("Shebang path: \(shebangPath, privacy: .public)")

        // Find the libexec part and extract the base Cellar path
        guard let libexecRange = shebangPath.range(of: "/libexec/") else {
            logger.warning("No /libexec/ found in shebang")
            return nil
        }

        let cellarBasePath = String(shebangPath[..<libexecRange.lowerBound])
        logger.debug("Cellar base: \(cellarBasePath, privacy: .public)")

        // Find Python version by trying common versions
        // (Can't list directory due to Hardened Runtime restrictions)
        let libPath = cellarBasePath + "/libexec/lib"
        logger.debug("Lib path: \(libPath, privacy: .public)")

        // Try common Python versions in order (newest first)
        let pythonVersions = ["3.14", "3.13", "3.12", "3.11", "3.10", "3.9"]
        var foundVersion: String?
        var sitePackages: String?

        for version in pythonVersions {
            let testPath = "\(libPath)/python\(version)/site-packages"
            if FileManager.default.fileExists(atPath: testPath) {
                foundVersion = version
                sitePackages = testPath
                logger.debug("Found Python \(version, privacy: .public) at: \(testPath, privacy: .public)")
                break
            }
        }

        guard let pythonVersion = foundVersion, let packages = sitePackages else {
            logger.warning("No Python site-packages found for versions: \(pythonVersions, privacy: .public)")
            return nil
        }

        // Use main Homebrew Python with matching version
        let python3Path = "/opt/homebrew/bin/python\(pythonVersion)"

        // Fallback to generic python3 if specific version not found
        let finalPythonPath = FileManager.default.fileExists(atPath: python3Path)
            ? python3Path
            : "/opt/homebrew/bin/python3"

        let finalSitePackages = packages

        logger.debug("Resolved Python: \(finalPythonPath, privacy: .public), PYTHONPATH: \(finalSitePackages, privacy: .public)")
        return ExecutionInfo(
            pythonPath: shebangPath,
            mainPythonPath: finalPythonPath,
            sitePackages: finalSitePackages
        )
    }

    /// Checks if a file is a Mach-O binary (standalone executable) vs a script
    static func isStandaloneBinary(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              data.count >= 4 else {
            return false
        }

        // Check for Mach-O magic numbers
        let magic = data.prefix(4)
        let machO64 = Data([0xCF, 0xFA, 0xED, 0xFE])  // 64-bit Mach-O
        let machO32 = Data([0xCE, 0xFA, 0xED, 0xFE])  // 32-bit Mach-O
        let fatBinary = Data([0xCA, 0xFE, 0xBA, 0xBE]) // Universal binary

        return magic == machO64 || magic == machO32 || magic == fatBinary
    }

    struct ToolExecutionConfiguration: Sendable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    /// Resolves how to execute yt-dlp without constructing or owning a process.
    /// Handles both standalone binaries (yt-dlp_macos) and Python scripts (Homebrew).
    static func ytDLPExecutionConfiguration(
        scriptPath: String,
        arguments: [String]
    ) -> ToolExecutionConfiguration {
        // Check if it's a standalone binary (like yt-dlp_macos from GitHub)
        if isStandaloneBinary(at: scriptPath) {
            logger.debug("Using standalone binary: \(scriptPath, privacy: .public)")

            // Add bundled ffmpeg to PATH so yt-dlp can find it for post-processing
            var env = ProcessInfo.processInfo.environment
            var pathEntries: [String] = []
            if let ffmpegPath = BinaryPathResolver.ffmpegPath {
                let ffmpegDir = (ffmpegPath as NSString).deletingLastPathComponent
                pathEntries.append(ffmpegDir)
                logger.debug("Added ffmpeg to PATH: \(ffmpegDir, privacy: .public)")
            }
            pathEntries.append(contentsOf: commonPathEntries)
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            // Enable unbuffered output for PyInstaller-frozen binaries (like yt-dlp_macos)
            env["PYTHONUNBUFFERED"] = "1"
            return ToolExecutionConfiguration(
                executableURL: URL(fileURLWithPath: scriptPath),
                arguments: arguments,
                environment: env
            )
        }

        // It's a Python script - try Homebrew detection with PYTHONPATH
        if let info = executionInfo(for: scriptPath) {
            // Prefer Homebrew Python that matches the detected site-packages.
            let cltPython = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3"
            let xcodePython = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3"
            let systemPython = "/usr/bin/python3"

            let pythonCandidates = [
                info.mainPythonPath,
                info.pythonPath,
                cltPython,
                xcodePython,
                systemPython
            ]
            let pythonPath = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? info.mainPythonPath

            logger.debug("Using \(pythonPath, privacy: .public) with PYTHONPATH: \(info.sitePackages, privacy: .public)")
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = info.sitePackages
            // Also set PYTHONUNBUFFERED for extra safety
            env["PYTHONUNBUFFERED"] = "1"
            var pathEntries = commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            return ToolExecutionConfiguration(
                executableURL: URL(fileURLWithPath: pythonPath),
                // Use -u for unbuffered stdout/stderr to ensure real-time progress output.
                arguments: ["-u", "-m", "yt_dlp"] + arguments,
                environment: env
            )
        } else {
            // Last resort - try executing directly (may work for scripts with valid shebangs)
            logger.warning("Executing directly as last resort: \(scriptPath, privacy: .public)")
            var env = ProcessInfo.processInfo.environment
            var pathEntries = commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            // Enable unbuffered output for Python scripts
            env["PYTHONUNBUFFERED"] = "1"
            return ToolExecutionConfiguration(
                executableURL: URL(fileURLWithPath: scriptPath),
                arguments: arguments,
                environment: env
            )
        }
    }

    /// Reads the shebang from a script and returns the Python interpreter path if it exists.
    /// Works for uv, pip --user, and other virtualenv-based installations.
    static func resolveShebangPython(for scriptPath: String) -> String? {
        let resolvedPath = (scriptPath as NSString).resolvingSymlinksInPath
        guard let data = FileManager.default.contents(atPath: resolvedPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let firstLine = content.components(separatedBy: .newlines).first ?? ""
        guard firstLine.hasPrefix("#!") else { return nil }

        let shebangPath = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        if FileManager.default.isExecutableFile(atPath: shebangPath) {
            logger.debug("Resolved shebang Python: \(shebangPath, privacy: .public)")
            return shebangPath
        }

        return nil
    }

    /// Resolves how to execute a generic Python CLI tool installed via pip/uv/Homebrew.
    /// Unlike the yt-dlp-specific variant, this runs the script file directly rather than using -m module.
    /// - Parameters:
    ///   - scriptPath: Path to the Python script/binary
    ///   - arguments: Arguments to pass to the script
    ///   - extraPathEntries: Additional PATH entries (e.g. bundled ffmpeg directory)
    static func pythonToolExecutionConfiguration(
        scriptPath: String,
        arguments: [String],
        extraPathEntries: [String] = []
    ) -> ToolExecutionConfiguration {
        // Check if it's a standalone binary (e.g. PyInstaller-frozen)
        if isStandaloneBinary(at: scriptPath) {
            logger.debug("Using standalone binary: \(scriptPath, privacy: .public)")
            var env = ProcessInfo.processInfo.environment
            var pathEntries = extraPathEntries + commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            env["PYTHONUNBUFFERED"] = "1"
            return ToolExecutionConfiguration(
                executableURL: URL(fileURLWithPath: scriptPath),
                arguments: arguments,
                environment: env
            )
        }

        // It's a Python script - try Homebrew detection with PYTHONPATH
        if let info = executionInfo(for: scriptPath) {
            let pythonCandidates = [
                info.mainPythonPath,
                info.pythonPath,
                "/usr/bin/python3"
            ]
            let pythonPath = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? info.mainPythonPath

            logger.debug("Using \(pythonPath, privacy: .public) to run \(scriptPath, privacy: .public)")
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = info.sitePackages
            env["PYTHONUNBUFFERED"] = "1"
            var pathEntries = extraPathEntries + commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            return ToolExecutionConfiguration(
                executableURL: URL(fileURLWithPath: pythonPath),
                arguments: ["-u", scriptPath] + arguments,
                environment: env
            )
        } else if resolveShebangPython(for: scriptPath) != nil {
            // Script has a valid Python shebang (uv, pip --user, virtualenv, etc.)
            // Execute the script directly so the OS invokes the shebang interpreter,
            // preserving venv isolation (Process resolves symlinks which breaks venv detection).
            logger.debug("Executing via shebang: \(scriptPath, privacy: .public)")
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            var pathEntries = extraPathEntries + commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            return ToolExecutionConfiguration(
                executableURL: URL(fileURLWithPath: scriptPath),
                arguments: arguments,
                environment: env
            )
        } else {
            // Last resort - try executing directly
            logger.warning("Executing directly as last resort: \(scriptPath, privacy: .public)")
            var env = ProcessInfo.processInfo.environment
            var pathEntries = extraPathEntries + commonPathEntries
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            pathEntries.append(contentsOf: currentPath.components(separatedBy: ":"))
            env["PATH"] = mergedPath(from: pathEntries)
            env["PYTHONUNBUFFERED"] = "1"
            return ToolExecutionConfiguration(
                executableURL: URL(fileURLWithPath: scriptPath),
                arguments: arguments,
                environment: env
            )
        }
    }
}
