// Aagedal VideoLoop Converter 2.0
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AVFoundation
import Cocoa
import OSLog

struct VideoFileUtils: Sendable {
    static func isVideoFile(url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return AppConstants.supportedVideoExtensions.contains(fileExtension)
    }
    
    static func createVideoItem(from url: URL, outputFolder: String? = nil, preset: ExportPreset = .videoLoop, comment: String = "") async -> VideoItem? {
        guard isVideoFile(url: url) else { return nil }
        
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        
        // First try to get duration using FFprobe, fall back to AVFoundation if not available
        var durationSec: Double = 0.0
        let fileName = url.lastPathComponent
        
        // Try FFprobe if available
        if Bundle.main.path(forResource: "ffprobe", ofType: nil) != nil {
            Logger().info("Attempting to get duration using FFprobe for: \(fileName)")
            durationSec = await FFMPEGConverter.getVideoDuration(url: url) ?? 0.0
            
            if durationSec > 0 {
                Logger().info("Successfully got duration from FFprobe: \(durationSec) seconds for \(fileName)")
            } else {
                Logger().warning("FFprobe returned 0 duration for \(fileName), falling back to AVFoundation")
            }
        } else {
            Logger().info("FFprobe not found in bundle, using AVFoundation for \(fileName)")
        }
        
        // If FFprobe failed or not available, use AVFoundation
        if durationSec <= 0 {
            Logger().info("Using AVFoundation to get duration for: \(fileName)")
            let asset = AVURLAsset(url: url)
            let cmDuration = try? await asset.load(.duration)
            durationSec = CMTimeGetSeconds(cmDuration ?? CMTime.zero)
            Logger().info("AVFoundation returned duration: \(durationSec) seconds for \(fileName)")
        }
        
        let durationString = formatDuration(seconds: durationSec)
        let thumbnailData = await getVideoThumbnail(url: url)
        
        // Generate output URL if output folder is provided
        var outputURL: URL? = nil
        if let outputFolder = outputFolder {
            let sanitizedBaseName = FileNameProcessor.processFileName(url.deletingPathExtension().lastPathComponent)
            let outputFileName = sanitizedBaseName + preset.fileSuffix + "." + preset.fileExtension
            outputURL = URL(fileURLWithPath: outputFolder).appendingPathComponent(outputFileName)
        }
        
        return VideoItem(
            url: url,
            name: name,
            size: size,
            duration: durationString,
            durationSeconds: durationSec,
            thumbnailData: thumbnailData,
            status: .waiting,
            progress: 0.0,
            eta: nil,
            outputURL: outputURL,
            comment: comment
        )
    }
    // utility to format seconds into hh:mm:ss or mm:ss
    private static func formatDuration(seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    @available(macOS 13.0, *)
    private static func getDurationFromAVFoundation(url: URL) async -> Double? {
        do {
            let asset = AVURLAsset(url: url)
            let cmDuration = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(cmDuration)
            Logger().info("AVFoundation duration: \(duration) seconds for \(url.lastPathComponent)")
            return duration
        } catch {
            Logger().error("Error getting duration from AVFoundation: \(error.localizedDescription) for \(url.lastPathComponent)")
            return nil
        }
    }
    
    static func getVideoDuration(url: URL) async -> String {
        let fileName = url.lastPathComponent
        var duration: Double = 0.0
        
        if Bundle.main.path(forResource: "ffprobe", ofType: nil) != nil {
            Logger().info("[getVideoDuration] Attempting FFprobe for: \(fileName)")
            let ffprobeDuration = await FFMPEGConverter.getVideoDuration(url: url)
            
            if let ffprobeDuration = ffprobeDuration, ffprobeDuration > 0 {
                duration = ffprobeDuration
                Logger().info("[getVideoDuration] FFprobe success: \(duration) seconds for \(fileName)")
            } else {
                Logger().warning("[getVideoDuration] FFprobe failed or returned 0, falling back to AVFoundation for \(fileName)")
                if let durationFromAV = await getDurationFromAVFoundation(url: url) {
                    duration = durationFromAV
                }
            }
        } else {
            Logger().info("[getVideoDuration] FFprobe not found, using AVFoundation for \(fileName)")
            if let durationFromAV = await getDurationFromAVFoundation(url: url) {
                duration = durationFromAV
            }
        }
        
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    static func getVideoThumbnail(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let assetImageGenerator = AVAssetImageGenerator(asset: asset)
        assetImageGenerator.appliesPreferredTrackTransform = true
        assetImageGenerator.apertureMode = .cleanAperture
        assetImageGenerator.maximumSize = CGSize(width: 320, height: 180) // Thumbnail size
        
        // Get a more representative timestamp (10% into the video)
        let duration = try? await asset.load(.duration)
        let seconds = min(CMTimeGetSeconds(duration ?? CMTime(seconds: 1, preferredTimescale: 1)) * 0.1, 60)
        let time = CMTime(seconds: max(seconds, 0.5), preferredTimescale: 600) // Minimum 0.5 seconds
        
        do {
            let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                assetImageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                    switch result {
                    case .succeeded where image != nil:
                        continuation.resume(returning: image!)
                    case .failed where error != nil:
                        continuation.resume(throwing: error!)
                    case .cancelled:
                        continuation.resume(throwing: NSError(domain: "com.aagedal.videoloop", code: -1, userInfo: [NSLocalizedDescriptionKey: "Thumbnail generation was cancelled"]))
                    default:
                        continuation.resume(throwing: NSError(domain: "com.aagedal.videoloop", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown error generating thumbnail"]))
                    }
                }
            }
            
            // Convert CGImage to PNG data directly without going through NSImage
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            bitmapRep.size = CGSize(width: cgImage.width, height: cgImage.height)
            
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                print("Failed to create PNG data from thumbnail")
                return nil
            }
            
            return pngData
            
        } catch {
            print("Error generating thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}

struct VideoItem: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    var url: URL
    var name: String
    var size: Int64
    var duration: String
    var durationSeconds: Double = 0.0
    var thumbnailData: Data?
    var status: ConversionManager.ConversionStatus
    var progress: Double
    var eta: String?
    var outputURL: URL?
    var comment: String = ""
    
    /// Human-readable file size string (<1 MB ⇒ KB, 1–600 MB ⇒ MB, ≥600 MB ⇒ GB)
    var formattedSize: String {
        let bytes = Double(size)
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        
        if bytes < mb {
            return String(format: "%.0f KB", bytes / kb)
        } else if bytes < 600 * mb {
            return String(format: "%.1f MB", bytes / mb)
        } else {
            return String(format: "%.1f GB", bytes / gb)
        }
    }
    
    var outputFileExists: Bool {
        guard let outputURL = outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }
}
