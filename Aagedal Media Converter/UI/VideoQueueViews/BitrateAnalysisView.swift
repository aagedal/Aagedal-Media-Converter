// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts

/// Charts stacked on one time axis use a fixed leading label width so their plots line up.
enum AnalysisChartLayout {
    static let yLabelWidth: CGFloat = 40

    @AxisContentBuilder
    static func leadingYAxis() -> some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(number.formatted(.number.precision(.fractionLength(0...1))))
                        .frame(width: yLabelWidth, alignment: .trailing)
                }
            }
        }
    }
}

struct BitrateSeries: Identifiable {
    let name: String
    let color: Color
    let timeline: BitrateTimeline
    var id: String { name }
}

/// The pointer position lives outside the chart's state so hovering only redraws the
/// pointer line and the readout, not every mark of a long file.
@MainActor @Observable
private final class BitrateHover {
    var time: Double?
}

struct BitrateChart: View {
    let series: [BitrateSeries]
    let duration: Double
    let windowSize: Double
    var position: Double? = nil
    var showsKeyframes = false
    var showsReadout = true
    var xAxisLabel = String(localized: "Seconds")
    var onSeek: ((Double) -> Void)? = nil
    @State private var hover = BitrateHover()

    private static let maxKeyframeMarks = 1500

    var body: some View {
        let windows = series.map { $0.timeline.windows(size: windowSize).filter { $0.start < duration } }
        let peak = windows.flatMap { $0.map(\.bitsPerSecond) }.max() ?? 0
        let megabits = BitrateFormatting.usesMegabits(peak: peak)
        let scale = megabits ? 1_000_000.0 : 1_000.0
        let keyframeStride = max(1, series.reduce(0) { $0 + $1.timeline.keyframeTimes.count } / Self.maxKeyframeMarks)
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, entry in
                    if showsKeyframes {
                        ForEach(Array(stride(from: 0, to: entry.timeline.keyframeTimes.count, by: keyframeStride)), id: \.self) { offset in
                            let time = entry.timeline.keyframeTimes[offset]
                            if time < duration {
                                RuleMark(x: .value("Keyframe", time))
                                    .foregroundStyle(entry.color.opacity(0.14))
                                    .lineStyle(StrokeStyle(lineWidth: 1))
                            }
                        }
                    }
                    // A step line shows each window's average over its whole interval.
                    ForEach(windows[index]) { window in
                        LineMark(x: .value("Seconds", window.start),
                                 y: .value("Bitrate", window.bitsPerSecond / scale),
                                 series: .value("File", entry.name))
                            .foregroundStyle(by: .value("File", entry.name))
                            .interpolationMethod(.stepEnd)
                    }
                    if let last = windows[index].last {
                        LineMark(x: .value("Seconds", min(duration, entry.timeline.duration)),
                                 y: .value("Bitrate", last.bitsPerSecond / scale),
                                 series: .value("File", entry.name))
                            .foregroundStyle(by: .value("File", entry.name))
                            .interpolationMethod(.stepEnd)
                    }
                    RuleMark(y: .value("Average", entry.timeline.averageBitsPerSecond / scale))
                        .foregroundStyle(entry.color.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if let position {
                    RuleMark(x: .value("Playback", position)).foregroundStyle(.secondary)
                }
            }
            .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
            .chartLegend(series.count > 1 ? .visible : .hidden)
            .chartXScale(domain: 0...max(0.001, duration))
            .chartYScale(domain: 0...max(peak / scale * 1.08, 0.001))
            .chartYAxis { AnalysisChartLayout.leadingYAxis() }
            .chartXAxisLabel(xAxisLabel)
            .chartYAxisLabel(megabits ? "Mbit/s" : "kbit/s", position: .top, alignment: .leading)
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): hover.time = time(at: location, proxy: proxy, geometry: geometry)
                                case .ended: hover.time = nil
                                }
                            }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                guard let onSeek, let seconds = time(at: value.location, proxy: proxy, geometry: geometry) else { return }
                                onSeek(seconds)
                            })
                        BitrateHoverLine(hover: hover, proxy: proxy, geometry: geometry)
                            .allowsHitTesting(false)
                    }
                }
            }
            .accessibilityLabel("Bitrate over time")
            if showsReadout {
                BitrateReadout(hover: hover, position: position, series: series, windows: windows, windowSize: windowSize)
            }
        }
    }

    private func time(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Double? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        guard frame.width > 0 else { return nil }
        let x = min(frame.width, max(0, location.x - frame.minX))
        guard let seconds: Double = proxy.value(atX: x) else { return nil }
        return max(0, min(seconds, duration))
    }

}

private struct BitrateHoverLine: View {
    let hover: BitrateHover
    let proxy: ChartProxy
    let geometry: GeometryProxy

    var body: some View {
        if let time = hover.time, let plotFrame = proxy.plotFrame, let x = proxy.position(forX: time) {
            let frame = geometry[plotFrame]
            Rectangle().fill(.secondary.opacity(0.5))
                .frame(width: 1, height: frame.height)
                .offset(x: frame.minX + x - 0.5, y: frame.minY)
        }
    }
}

private struct BitrateReadout: View {
    let hover: BitrateHover
    let position: Double?
    let series: [BitrateSeries]
    let windows: [[BitrateWindow]]
    let windowSize: Double

    var body: some View {
        Text(readout(at: hover.time ?? position))
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Windows are contiguous from zero, so the window index is the time divided by its size.
    private func readout(at seconds: Double?) -> String {
        guard let seconds else { return String(localized: "Point at the graph to read the bitrate.") }
        let index = Int(seconds / windowSize)
        let values = zip(series, windows).map { entry, windows in
            let value = windows.indices.contains(index) ? windows[index].bitsPerSecond : nil
            return "\(entry.name): \(BitrateFormatting.string(value))"
        }
        return ([seconds.formatted(.number.precision(.fractionLength(2))) + " s"] + values).joined(separator: " · ")
    }
}

/// Plots the packet sizes of the source and the encoded output for one stream type.
struct BitrateAnalysisView: View {
    let sourceFile: URL
    let outputFile: URL?
    let hasVideo: Bool
    let isActive: Bool

    @State private var stream: BitrateStreamKind
    /// Zero selects the automatic window.
    @State private var windowChoice = 0.0
    @State private var showsKeyframes = true
    @State private var source: BitrateTimeline?
    @State private var output: BitrateTimeline?
    @State private var errors: [String] = []
    @State private var running = false
    @State private var loadedKey: String?

    init(sourceFile: URL, outputFile: URL?, hasVideo: Bool, isActive: Bool) {
        self.sourceFile = sourceFile
        self.outputFile = outputFile
        self.hasVideo = hasVideo
        self.isActive = isActive
        _stream = State(initialValue: hasVideo ? .video : .audio)
    }

    private var loadKey: String { "\(sourceFile.path)|\(outputFile?.path ?? "")|\(stream.rawValue)" }

    private var series: [BitrateSeries] {
        var series: [BitrateSeries] = []
        if let source { series.append(BitrateSeries(name: String(localized: "Source"), color: .blue, timeline: source)) }
        if let output { series.append(BitrateSeries(name: String(localized: "Encoded"), color: .orange, timeline: output)) }
        return series
    }

    private var duration: Double { series.map(\.timeline.duration).max() ?? 0 }
    private var windowOptions: [Double] { BitrateTimeline.windowChoices(duration: duration) }
    private var windowSize: Double {
        windowOptions.contains(windowChoice) ? windowChoice : BitrateTimeline.automaticWindow(duration: duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if hasVideo {
                    Picker("Stream", selection: $stream) {
                        Text("Video").tag(BitrateStreamKind.video)
                        Text("Audio").tag(BitrateStreamKind.audio)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .accessibilityIdentifier("analysis.bitrate.stream")
                }
                Picker("Averaging window", selection: $windowChoice) {
                    Text(String(format: String(localized: "Automatic (%@)"), Self.windowLabel(BitrateTimeline.automaticWindow(duration: duration))))
                        .tag(0.0)
                    ForEach(windowOptions, id: \.self) { size in
                        Text(Self.windowLabel(size)).tag(size)
                    }
                }
                .frame(width: 210)
                .accessibilityIdentifier("analysis.bitrate.window")
                .onChange(of: windowOptions) {
                    if windowChoice > 0, !windowOptions.contains(windowChoice) { windowChoice = 0 }
                }
                if stream == .video {
                    Toggle("Keyframes", isOn: $showsKeyframes)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            Text("Packet sizes are read from the container without decoding. Each point is the average bitrate over one window.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(errors, id: \.self) { error in
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if !series.isEmpty {
                BitrateChart(series: series, duration: duration, windowSize: windowSize,
                             showsKeyframes: showsKeyframes && stream == .video)
                    .frame(height: 300)
                    .accessibilityIdentifier("analysis.bitrate.chart")
                summary
                if output != nil {
                    Text("Each file is plotted from its own first frame, so a trimmed output starts at its trim-in point.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !running && errors.isEmpty {
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: isActive ? loadKey : nil) {
            guard isActive, loadedKey != loadKey else { return }
            await load()
        }
    }

    private var summary: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("File").bold()
                Text("Average").bold()
                Text("Peak").bold()
                Text("Lowest").bold()
                if stream == .video { Text("Keyframe interval").bold() }
                Text("Size").bold()
            }
            ForEach(series) { entry in
                let windows = entry.timeline.windows(size: windowSize)
                GridRow {
                    Label(entry.name, systemImage: "circle.fill")
                        .foregroundStyle(entry.color)
                    Text(BitrateFormatting.string(entry.timeline.averageBitsPerSecond))
                    Text(BitrateFormatting.string(windows.map(\.bitsPerSecond).max()))
                    Text(BitrateFormatting.string(windows.map(\.bitsPerSecond).min()))
                    if stream == .video { Text(entry.timeline.keyframeIntervalDescription) }
                    Text(Int64(entry.timeline.totalBytes).formatted(.byteCount(style: .file)))
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }

    private func load() async {
        running = true
        errors = []
        source = nil
        output = nil
        defer { if !Task.isCancelled { running = false } }
        var failures: [String] = []
        do {
            source = try await BitrateAnalysisService.shared.analyze(file: sourceFile, stream: stream)
        } catch is CancellationError {
            return
        } catch {
            failures.append(String(format: String(localized: "Source: %@"), error.localizedDescription))
        }
        if let outputFile {
            do {
                output = try await BitrateAnalysisService.shared.analyze(file: outputFile, stream: stream)
            } catch is CancellationError {
                return
            } catch {
                failures.append(String(format: String(localized: "Encoded: %@"), error.localizedDescription))
            }
        }
        guard !Task.isCancelled else { return }
        errors = failures
        loadedKey = loadKey
    }

    private static func windowLabel(_ size: Double) -> String {
        size.formatted(.number.precision(.fractionLength(0...1))) + " s"
    }
}
