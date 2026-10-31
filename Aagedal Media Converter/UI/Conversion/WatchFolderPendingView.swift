// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Toolbar button shown while watch-folder files are still copying or settling; its popover
/// lists each file and what the import is waiting for.
struct WatchFolderPendingButton: View {
    let files: [WatchFolderPendingFile]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("\(files.count) Waiting", systemImage: "hourglass")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
        .foregroundStyle(.yellow)
        .help(files.count == 1
            ? "1 watch-folder file is waiting to finish copying"
            : "\(files.count) watch-folder files are waiting to finish copying")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            WatchFolderPendingList(files: files)
        }
    }
}

struct WatchFolderPendingList: View {
    let files: [WatchFolderPendingFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Waiting in Watch Folder")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            if files.isEmpty {
                Text("All files have been imported.")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    // Re-render each second so settling countdowns stay current.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(files) { file in
                                row(for: file, now: context.date)
                                if file.id != files.last?.id { Divider().padding(.leading, 40) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 380)
    }

    private func row(for file: WatchFolderPendingFile, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stateIcon(file.state)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
                HStack(spacing: 6) {
                    Text(statusText(for: file, now: now))
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func stateIcon(_ state: WatchFolderPendingFile.State) -> some View {
        switch state {
        case .copying:
            Image(systemName: "arrow.down.doc").foregroundStyle(.blue)
        case .settling:
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .unreadable:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func statusText(for file: WatchFolderPendingFile, now: Date) -> String {
        switch file.state {
        case .copying:
            return "Copying…"
        case .settling:
            guard let readyAt = file.readyAt else { return "Waiting for copying to finish" }
            let seconds = Int(readyAt.timeIntervalSince(now).rounded(.up))
            return seconds > 0 ? "Unchanged, importing in \(seconds) s" : "Importing shortly"
        case .checking:
            return "Checking that the file can be read…"
        case .unreadable:
            return "Can't be read yet, retrying"
        }
    }
}
