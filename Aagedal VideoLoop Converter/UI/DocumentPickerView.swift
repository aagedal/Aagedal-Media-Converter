// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct DocumentPickerView: View {
    @Binding var droppedFiles: [VideoItem]
    @Binding var isPresented: Bool
    @Binding var selectedFolder: URL?

    var body: some View {
        VStack {
            // Your UI components
            Button(action: {
                self.isPresented = false
            }) {
                Text("Done")
            }
        }
        .onAppear {
            Task {
                await self.openFolderSelection()
            }
        }
    }

    @MainActor
    private func openFolderSelection() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let response = await withCheckedContinuation { continuation in
            panel.begin { result in
                continuation.resume(returning: result)
            }
        }
        if response == .OK {
            self.selectedFolder = panel.url
        }
        self.isPresented = false
    }
}
