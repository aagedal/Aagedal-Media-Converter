// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import UniformTypeIdentifiers

struct DropViewDelegate: DropDelegate {
    let item: VideoItem
    @Binding var items: [VideoItem]
    @Binding var isReordering: Bool
    @Binding var isEncoding: Bool
    var onMove: (IndexSet, Int) -> Void
    
    func performDrop(info: DropInfo) -> Bool {
        isReordering = false
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard !isEncoding else { return }
        
        guard let fromIndex = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        
        guard let toIndex = items.firstIndex(where: { $0.id == (info.itemProviders(for: [.text])
            .first?.loadObject(ofClass: NSString.self) { str, _ in
                if let str = str as? String {
                    DispatchQueue.main.async {
                        self.moveItem(from: fromIndex, to: toIndex, with: str)
                    }
                }
            }
        )}) else {
            return
        }
        
        if fromIndex != toIndex {
            withAnimation {
                let from = min(fromIndex, toIndex)
                let to = max(fromIndex, toIndex)
                
                var updatedItems = items
                updatedItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                
                // Only update if the order actually changed
                if updatedItems != items {
                    items = updatedItems
                    // Call the onMove callback to update the parent view
                    onMove(IndexSet(integer: from), toIndex)
                }
            }
        }
    }
    
    private func moveItem(from fromIndex: Int, to toIndex: Int, with itemId: String) {
        guard fromIndex != toIndex,
              let from = items.firstIndex(where: { $0.id == itemId }) else {
            return
        }
        
        withAnimation {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: toIndex > from ? toIndex + 1 : toIndex)
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: isEncoding ? .forbidden : .move)
    }
    
    func dropExited(info: DropInfo) {
        isReordering = false
    }
}
