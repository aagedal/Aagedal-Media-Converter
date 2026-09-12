// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct DCPMetadataView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: VideoItem

    @State private var contentTitleText: String = ""
    @State private var contentKind: DCPContentKind = .feature
    @State private var annotationText: String = ""
    @State private var ratingLabel: String = ""
    @State private var audioLanguage: String = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DCP Metadata")
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
                .accessibilityLabel("Close DCP metadata")
                .keyboardShortcut(.escape, modifiers: [])
            }

            // Form fields
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content Title")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("Title shown on cinema server", text: $contentTitleText)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Content Kind")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Picker("", selection: $contentKind) {
                            ForEach(DCPContentKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rating")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("e.g. PG-13", text: $ratingLabel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
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

                Text("These fields are embedded in the DCP's Composition Playlist (CPL) and Packing List (PKL).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 640, height: 360)
        .onAppear {
            let meta = PackageMetadataSettings().resolveDCPMetadata(item.dcpMetadata, inputURL: item.url)
            contentTitleText = meta.contentTitleText
            contentKind = meta.contentKind
            annotationText = meta.annotationText
            ratingLabel = meta.ratingLabel
            audioLanguage = meta.audioLanguage
        }
    }

    private func save() {
        item.dcpMetadata = DCPItemMetadata(
            contentTitleText: contentTitleText,
            contentKind: contentKind,
            annotationText: annotationText,
            ratingLabel: ratingLabel,
            audioLanguage: audioLanguage.isEmpty ? "en" : audioLanguage
        )
        UserDefaults.standard.set(contentKind.rawValue, forKey: AppConstants.lastDCPContentKindKey)
    }
}
