// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Container view for the metadata window that switches between empty state,
/// single item view, and comparison view based on selection.
struct MetadataWindowContent: View {
    @State private var state = MetadataWindowState.shared
    @State private var searchText = ""
    @State private var differencesOnly = false

    var body: some View {
        Group {
            if state.selectedItems.isEmpty {
                emptyStateView
            } else {
                // Use comparison view for both single and multiple items
                ComparisonMetadataView(
                    items: state.selectedItems,
                    searchText: $searchText,
                    differencesOnly: $differencesOnly
                )
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "info.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Selection")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select one or more items in the queue\nto view their metadata.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
