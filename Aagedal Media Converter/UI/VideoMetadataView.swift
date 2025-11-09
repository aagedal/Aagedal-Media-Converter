import SwiftUI

struct VideoMetadataView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: VideoItem

    private var metadata: VideoMetadata? { item.metadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Metadata")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close metadata")
                .keyboardShortcut(.escape, modifiers: [])
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    generalSection
                    videoSection
                    audioSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
    }

    private var generalSection: some View {
        section(title: "General") {
            infoRow("Container", value: metadata?.containerLongName ?? metadata?.formatName)
            infoRow("Duration", value: item.duration)
            infoRow("File Size", value: formattedSize)
            infoRow("Bit Rate", value: formatBitRate(metadata?.bitRate))
            if let comment = item.metadataComment {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Comment")
                        .font(.subheadline.weight(.semibold))
                    Text(comment)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if metadata == nil {
                Text("No detailed metadata available.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var videoSection: some View {
        section(title: "Video") {
            if let stream = metadata?.videoStream {
                infoRow("Codec", value: stream.codecLongName ?? stream.codec)
                infoRow("Profile", value: stream.profile)
                infoRow("Resolution", value: item.videoResolutionDescription)
                infoRow("Display Aspect", value: stream.displayAspectRatio?.stringValue)
                infoRow("Pixel Aspect", value: stream.pixelAspectRatio?.stringValue)
                infoRow("Frame Rate", value: formattedFrameRate(stream.frameRate))
                infoRow("Bit Depth", value: stream.bitDepth.map { "\($0)-bit" })
                infoRow("Color Primaries", value: stream.colorPrimaries)
                infoRow("Color Transfer", value: stream.colorTransfer)
                infoRow("Color Space", value: stream.colorSpace)
                infoRow("Color Range", value: stream.colorRange)
                infoRow("Chroma Location", value: stream.chromaLocation)
                infoRow("Scan Type", value: formattedScanType(stream))
            } else {
                Text("No video stream detected.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var audioSection: some View {
        section(title: "Audio") {
            if let audioStreams = metadata?.audioStreams, !audioStreams.isEmpty {
                ForEach(audioStreams.indices, id: \.self) { index in
                    let stream = audioStreams[index]
                    if audioStreams.count > 1 {
                        Text("Stream \(index + 1)")
                            .font(.body)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                            .padding(.top, index > 0 ? 12 : 0)
                            .padding(.bottom, 2)
                    }
                    infoRow("Codec", value: stream.codecLongName ?? stream.codec)
                    infoRow("Profile", value: stream.profile)
                    infoRow("Sample Rate", value: formatSampleRate(stream.sampleRate))
                    infoRow("Channels", value: stream.channels.map(String.init))
                    infoRow("Channel Layout", value: stream.channelLayout)
                    infoRow("Bit Depth", value: stream.bitDepth.map { "\($0)-bit" })
                    infoRow("Bit Rate", value: formatBitRate(stream.bitRate))
                }
            } else {
                Text("No audio stream detected.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func infoRow(_ title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(.subheadline, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formattedSize: String? {
        let bytes = metadata?.sizeBytes ?? item.size
        return VideoMetadataView.byteFormatter.string(fromByteCount: bytes)
    }

    private func formatBitRate(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        if value >= 1_000_000 {
            return String(format: "%.2f Mbps", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1f kbps", Double(value) / 1_000)
        } else {
            return "\(value) bps"
        }
    }

    private func formattedFrameRate(_ frameRate: VideoMetadata.FrameRate?) -> String? {
        guard let frameRate else { return nil }
        if let value = frameRate.value {
            return String(format: "%.3f fps", value)
        }
        return frameRate.stringValue
    }

    private func formatSampleRate(_ sampleRate: Int?) -> String? {
        guard let sampleRate else { return nil }
        return VideoMetadataView.numberFormatter.string(from: NSNumber(value: sampleRate))?.appending(" Hz")
    }

    private func formattedScanType(_ stream: VideoMetadata.VideoStream) -> String? {
        guard let isInterlaced = stream.isInterlaced else { return stream.fieldOrder }
        return isInterlaced ? "Interlaced" : "Progressive"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = Locale.current.groupingSeparator
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}
