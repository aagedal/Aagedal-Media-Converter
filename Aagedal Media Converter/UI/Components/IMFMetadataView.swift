// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct IMFMetadataView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: VideoItem

    @State private var contentTitleText: String = ""
    @State private var contentKind: IMFContentKind = .feature
    @State private var annotationText: String = ""
    @State private var audioLanguage: String = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IMF Metadata")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    save()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close IMF metadata")
                .keyboardShortcut(.escape, modifiers: [])
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content Title")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("Title shown by IMF players", text: $contentTitleText)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Content Kind")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Picker("", selection: $contentKind) {
                            ForEach(IMFContentKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio Language")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("e.g. en, fr, nb", text: $audioLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Annotation")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("Optional note", text: $annotationText)
                        .textFieldStyle(.roundedBorder)
                }

                Text("These fields are embedded in the Composition Playlist (CPL) and Packing List (PKL).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 640, height: 340)
        .onAppear {
            let meta = PackageMetadataSettings().resolveIMFMetadata(item.imfMetadata, inputURL: item.url)
            contentTitleText = meta.contentTitleText
            contentKind = meta.contentKind
            annotationText = meta.annotationText
            audioLanguage = meta.audioLanguage
        }
    }

    private func save() {
        item.imfMetadata = IMFItemMetadata(
            contentTitleText: contentTitleText,
            contentKind: contentKind,
            annotationText: annotationText,
            audioLanguage: audioLanguage.isEmpty ? "en" : audioLanguage
        )
        UserDefaults.standard.set(contentKind.rawValue, forKey: AppConstants.lastIMFContentKindKey)
    }
}
