// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts
import UniformTypeIdentifiers

struct VideoEventAnalysisRequest: Identifiable {
    enum Kind: String { case black, sceneCuts }

    let id = UUID()
    let file: URL
    let kind: Kind
    let durationSeconds: Double
}

/// Black and scene cut detection on the complete source video, with a paused
/// preview for inspecting each detected event.
struct VideoEventAnalysisView: View {
    let request: VideoEventAnalysisRequest
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = MPVPlayer()
    @State private var blackMinimumDuration = 0.5
    @State private var pictureBlackRatio = 0.98
    @State private var pixelThreshold = 0.10
    @State private var sceneThreshold = 10.0
    @State private var blackResult: BlackDetectionResult?
    @State private var sceneOutput: SceneCutAnalysisOutput?
    @State private var analysisTimestamp: Date?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisID: UUID?
    @State private var progress = 0.0
    @State private var errorMessage: String?
    @State private var exportMessage: String?
    @State private var position = 0.0
    @State private var media: StitchMarkerMedia?
    @State private var previewAccess: SecurityScopedAccess = .none
    @State private var thumbnailDirectory: URL?

    private var file: URL { request.file }
    private var isBlack: Bool { request.kind == .black }
    private var isAnalyzing: Bool { analysisID != nil }
    private var previewReady: Bool { player.isFileLoaded }
    private var hasResult: Bool { isBlack ? blackResult != nil : sceneOutput != nil }
    private var timelineDuration: Double {
        max(0.1, player.duration.isFinite ? player.duration : 0, request.durationSeconds,
            blackResult?.intervals.last?.end ?? 0, sceneOutput?.result.cuts.last?.time ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    (isBlack ? Text("Detect Black Frames") : Text("Detect Scene Cuts")).font(.title2.bold())
                    Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("analysis.videoEvents.close")
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    settings
                    HStack {
                        Button("Scan Video") { analyze() }
                            .disabled(isAnalyzing)
                            .accessibilityIdentifier("analysis.videoEvents.run")
                        if isAnalyzing {
                            Button("Cancel") { analysisTask?.cancel() }
                                .accessibilityIdentifier("analysis.videoEvents.cancel")
                        }
                    }
                    if isAnalyzing {
                        ProgressView(value: progress)
                            .accessibilityIdentifier("analysis.videoEvents.progress")
                    }
                    HStack {
                        Button("Export JSON") { exportJSON() }
                            .disabled(isAnalyzing || !hasResult)
                            .accessibilityIdentifier("analysis.videoEvents.exportJSON")
                        Button { exportEDL() } label: {
                            isBlack ? Text("Export Black as EDL Markers") : Text("Export Cuts as EDL Markers")
                        }
                            .disabled(isAnalyzing || !hasResult)
                            .accessibilityIdentifier("analysis.videoEvents.exportEDL")
                    }
                    (isBlack
                     ? Text("Scans the complete first video stream. A picture counts as black when the share of black pixels reaches the picture ratio; a pixel is black at or below the pixel threshold.")
                     : Text("Scans the complete first video stream. A cut is reported where the scene change score reaches the threshold. Dark or low-contrast material can need a lower threshold."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(.red)
                    }
                    if let exportMessage {
                        Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    if let blackResult { blackList(blackResult) }
                    if let sceneOutput { cutList(sceneOutput) }
                    Spacer(minLength: 0)
                }
                .frame(width: 360)
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        MPVVideoView(player: player, keyHandler: { key, _, _ in
                            guard key == " ", previewReady else { return false }
                            player.togglePause()
                            return true
                        })
                        if let error = player.error {
                            Text(error).foregroundStyle(.white).padding()
                        } else if !player.isFileLoaded {
                            ProgressView("Preparing preview…").tint(.white)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button { player.togglePause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))
                        .disabled(!previewReady)
                        Slider(value: Binding(get: { position }, set: { seconds in seek(seconds) }), in: 0...timelineDuration)
                            .accessibilityLabel("Inspection playback position")
                            .disabled(!previewReady)
                        Text(verbatim: timecode(position))
                            .font(.caption).monospacedDigit()
                            .accessibilityIdentifier("analysis.videoEvents.time")
                    }
                    timeline
                    Text("Click an event to seek and pause. Times are relative to the file; trims and conversion settings are not applied.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(width: 960, height: 680)
        .onAppear {
            previewAccess = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
            player.load(url: file)
        }
        .task {
            // Timecode display and EDL export use the source's rate and start timecode.
            media = try? await StitchMarkerMedia.read(file)
        }
        .onChange(of: player.timePos) { _, seconds in
            if seconds.isFinite { position = max(0, seconds) }
        }
        .onChange(of: blackMinimumDuration) { clearResult() }
        .onChange(of: pictureBlackRatio) { clearResult() }
        .onChange(of: pixelThreshold) { clearResult() }
        .onChange(of: sceneThreshold) { clearResult() }
        .onDisappear {
            analysisID = nil
            analysisTask?.cancel()
            player.stop()
            removeThumbnailDirectory()
            SecurityScopedBookmarkManager.shared.stopAccessing(previewAccess)
            previewAccess = .none
        }
    }

    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isBlack {
                Picker("Minimum black duration", selection: $blackMinimumDuration) {
                    ForEach([0.1, 0.25, 0.5, 1, 2, 5], id: \.self) { value in
                        Text(verbatim: seconds(value)).tag(value)
                    }
                }
                .accessibilityIdentifier("analysis.black.duration")
                Picker("Black picture ratio", selection: $pictureBlackRatio) {
                    ForEach([0.9, 0.95, 0.98, 0.99, 1], id: \.self) { value in
                        Text(verbatim: percent(value)).tag(value)
                    }
                }
                .accessibilityIdentifier("analysis.black.pictureRatio")
                Picker("Black pixel threshold", selection: $pixelThreshold) {
                    ForEach([0.02, 0.05, 0.08, 0.1, 0.15, 0.2], id: \.self) { value in
                        Text(verbatim: percent(value)).tag(value)
                    }
                }
                .accessibilityIdentifier("analysis.black.pixelThreshold")
            } else {
                Picker("Scene cut threshold", selection: $sceneThreshold) {
                    ForEach([3.0, 5, 8, 10, 15, 20, 30, 40], id: \.self) { value in
                        Text(verbatim: value.formatted(.number.precision(.fractionLength(0)))).tag(value)
                    }
                }
                .accessibilityIdentifier("analysis.sceneCuts.threshold")
            }
        }
        .disabled(isAnalyzing)
    }

    private func blackList(_ result: BlackDetectionResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Black intervals: \(result.intervals.count)").font(.headline)
                .accessibilityIdentifier("analysis.black.summary")
            if result.intervals.isEmpty {
                Text("No black intervals meet these settings.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.intervals.enumerated()), id: \.element.id) { index, interval in
                        HStack {
                            Button { seek(interval.start) } label: {
                                Label(timecode(interval.start), systemImage: "play.circle")
                            }
                            .accessibilityLabel(Text("Start") + Text(verbatim: ": \(timecode(interval.start))"))
                            .accessibilityIdentifier("analysis.black.start.\(index)")
                            Button { seek(interval.end) } label: {
                                Text(verbatim: timecode(interval.end))
                            }
                            .accessibilityLabel(Text("End of black") + Text(verbatim: ": \(timecode(interval.end))"))
                            .accessibilityIdentifier("analysis.black.end.\(index)")
                            Spacer()
                            Text(verbatim: seconds(interval.duration)).foregroundStyle(.secondary)
                        }
                        .font(.caption).monospacedDigit()
                        .disabled(!previewReady)
                    }
                }
            }
        }
    }

    private func cutList(_ output: SceneCutAnalysisOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scene cuts: \(output.result.cuts.count)").font(.headline)
                .accessibilityIdentifier("analysis.sceneCuts.summary")
            if output.result.cuts.isEmpty {
                Text("No cuts meet this threshold.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(output.result.cuts.enumerated()), id: \.element.id) { index, cut in
                        Button { seek(cut.time) } label: {
                            HStack {
                                if output.thumbnails.indices.contains(index),
                                   let image = NSImage(contentsOf: output.thumbnails[index]) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                        .frame(width: 80, height: 45)
                                        .background(.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                Label(timecode(cut.time), systemImage: "play.circle")
                                Spacer()
                                Text(verbatim: cut.score.formatted(.number.precision(.fractionLength(1))))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Scene cut") + Text(verbatim: ": \(timecode(cut.time))"))
                        .accessibilityIdentifier("analysis.sceneCuts.cut.\(index)")
                        .font(.caption).monospacedDigit()
                        .disabled(!previewReady)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if blackResult != nil || sceneOutput != nil {
            Chart {
                ForEach(blackResult?.intervals ?? []) { interval in
                    RectangleMark(xStart: .value("Start", interval.start), xEnd: .value("End", interval.end),
                                  yStart: .value("Black", 0), yEnd: .value("Black", 1))
                        .foregroundStyle(.gray.opacity(0.6))
                }
                ForEach(sceneOutput?.result.cuts ?? []) { cut in
                    RuleMark(x: .value("Cut", cut.time)).foregroundStyle(.orange)
                }
                RuleMark(x: .value("Position", position)).foregroundStyle(.primary)
            }
            .chartXScale(domain: 0...timelineDuration)
            .chartYScale(domain: 0...1)
            .chartYAxis(.hidden)
            .chartXAxisLabel("Seconds")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geometry[frame].origin.x
                            if let seconds: Double = proxy.value(atX: x) { seek(seconds) }
                        }
                }
            }
            .frame(height: 100)
            .accessibilityLabel(isBlack ? Text("Black frame timeline") : Text("Scene cut timeline"))
        }
    }

    private func seek(_ seconds: Double) {
        guard seconds.isFinite, previewReady else { return }
        let lastPlayableTime = player.duration > 0 ? max(0, player.duration - 0.05) : timelineDuration
        position = max(0, min(seconds, lastPlayableTime))
        player.pause()
        player.seek(to: position)
    }

    private func clearResult() {
        blackResult = nil
        sceneOutput = nil
        analysisTimestamp = nil
        errorMessage = nil
        exportMessage = nil
        removeThumbnailDirectory()
    }

    private func removeThumbnailDirectory() {
        if let thumbnailDirectory { try? FileManager.default.removeItem(at: thumbnailDirectory) }
        thumbnailDirectory = nil
    }

    private func analyze() {
        guard !isAnalyzing else { return }
        clearResult()
        let id = UUID()
        analysisID = id
        progress = 0
        let file = file
        let duration = request.durationSeconds > 0 ? request.durationSeconds : player.duration
        let update: @Sendable (Double) -> Void = { value in
            Task { @MainActor in if analysisID == id { progress = value } }
        }
        if isBlack {
            let settings = BlackDetectionSettings(minimumDuration: blackMinimumDuration,
                                                  pictureBlackRatio: pictureBlackRatio,
                                                  pixelThreshold: pixelThreshold)
            analysisTask = Task { @MainActor in
                do {
                    let measured = try await VideoEventAnalysisService.shared.detectBlack(
                        file: file, settings: settings, durationSeconds: duration, progress: update)
                    try Task.checkCancellation()
                    if analysisID == id {
                        blackResult = measured
                        analysisTimestamp = Date()
                    }
                } catch is CancellationError {
                    // Cancelled scans do not publish incomplete intervals.
                } catch {
                    if analysisID == id, !Task.isCancelled { errorMessage = error.localizedDescription }
                }
                finish(id)
            }
        } else {
            let settings = SceneCutSettings(threshold: sceneThreshold)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AagedalSceneCutThumbnails", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
            thumbnailDirectory = directory
            analysisTask = Task { @MainActor in
                do {
                    let measured = try await VideoEventAnalysisService.shared.detectSceneCuts(
                        file: file, settings: settings, durationSeconds: duration,
                        thumbnailDirectory: directory, progress: update)
                    try Task.checkCancellation()
                    if analysisID == id {
                        sceneOutput = measured
                        analysisTimestamp = Date()
                    } else {
                        try? FileManager.default.removeItem(at: directory)
                    }
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: directory)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    if analysisID == id, !Task.isCancelled { errorMessage = error.localizedDescription }
                }
                finish(id)
            }
        }
    }

    private func finish(_ id: UUID) {
        if analysisID == id {
            analysisID = nil
            analysisTask = nil
        }
    }

    private var reportStem: String {
        file.deletingPathExtension().lastPathComponent + (isBlack ? "_video_black" : "_video_scene_cuts")
    }

    private func exportJSON() {
        guard let timestamp = analysisTimestamp, !isAnalyzing else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = reportStem + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        do {
            if let blackResult {
                try AnalyticsExporter.exportBlackJSON(result: blackResult, sourceFile: file, timestamp: timestamp, to: url)
            } else if let sceneOutput {
                try AnalyticsExporter.exportSceneCutJSON(result: sceneOutput.result, sourceFile: file,
                                                         timestamp: timestamp, to: url)
            }
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Export Failed") + ": " + error.localizedDescription
        }
    }

    private func exportEDL() {
        guard !isAnalyzing else { return }
        let markers: [StitchCutMarker]
        if let blackResult { markers = AnalyticsExporter.blackMarkers(blackResult) }
        else if let sceneOutput { markers = AnalyticsExporter.sceneCutMarkers(sceneOutput.result) }
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "edl") ?? .plainText]
        panel.nameFieldStringValue = reportStem + ".edl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let file = file
        let ranges = isBlack
        let title = file.lastPathComponent + (isBlack ? " Black Frames" : " Scene Cuts")
        Task { @MainActor in
            let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
            defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
            do {
                try await AnalyticsExporter.exportVideoEventEDL(markers: markers, sourceFile: file, title: title,
                                                                ranges: ranges, to: url)
                errorMessage = nil
                exportMessage = String(format: String(localized: "Exported %lld markers to %@"),
                                       Int64(markers.count), url.lastPathComponent)
            } catch {
                exportMessage = nil
                errorMessage = String(localized: "Export Failed") + ": " + error.localizedDescription
            }
        }
    }

    /// Source timecode when the file's rate is known, otherwise seconds.
    private func timecode(_ value: Double) -> String {
        guard let media, value.isFinite, value >= 0 else { return seconds(value) }
        if let code = StitchMarkerExport.sourceTimecode(media, trimStart: value) { return code }
        guard let fps = media.frameRate, fps.isFinite, fps >= 1, fps <= 240 else { return seconds(value) }
        let rate = StitchMarkerTimecodeRate(frameRate: fps)
        guard let frames = rate.frameCount(forSeconds: value) else { return seconds(value) }
        return rate.timecode(forFrameCount: frames)
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    private func percent(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(0))) + " %"
    }
}
