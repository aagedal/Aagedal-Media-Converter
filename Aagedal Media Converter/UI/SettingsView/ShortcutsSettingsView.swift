// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AppKit
import Carbon.HIToolbox
import Combine
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The keyboard shortcut editor: an on-screen keyboard showing what each key does with
/// each modifier combination, a searchable command list with two shortcuts per command,
/// and presets that can be saved, switched, and shared as files.
struct ShortcutsSettingsView: View {
    @ObservedObject private var registry = ShortcutRegistry.shared
    @StateObject private var recorder = ShortcutRecorder()
    @State private var layout = VirtualKeyboardLayout.current()
    @State private var context = ShortcutContext.main
    /// Modifier keys clicked on the on-screen keyboard; held modifiers take precedence.
    @State private var clickedModifiers: ShortcutModifiers = []
    @State private var selectedKeyID: VirtualKey.ID?
    @State private var selectedCommandID: ShortcutCommand.ID?
    @State private var search = ""
    @State private var category: ShortcutCategory?
    @State private var filter = AssignmentFilter.all
    @State private var status: Status?
    @State private var pendingReassignment: Assignment?
    @State private var pendingDiscard: PresetAction?
    @State private var namePrompt: NamePrompt?
    @State private var proposedName = ""
    @State private var confirmDelete = false
    @State private var showsBuiltInShortcuts = false

    private var layer: ShortcutModifiers { recorder.heldModifiers.isEmpty ? clickedModifiers : recorder.heldModifiers }
    private var selectedKey: VirtualKey? { layout.key(id: selectedKeyID) }
    private var selectedCommand: ShortcutCommand? {
        get { selectedCommandID.flatMap(ShortcutCommand.init(rawValue:)) }
        nonmutating set { selectedCommandID = newValue?.id }
    }
    private var activePresetTitle: String { ShortcutRegistry.displayName(ofPreset: registry.activePresetName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetBar
            contextBar
            VirtualKeyboardView(layout: layout, context: context, commands: registry.commandsByBinding(in: context), layer: layer,
                                selectedKeyID: selectedKeyID, highlightedKeyIDs: highlightedKeyIDs,
                                select: { selectedKeyID = $0.id },
                                toggleModifier: { clickedModifiers.formSymmetricDifference($0) },
                                drop: dropCommand)
                .frame(maxWidth: .infinity)
            legend
            filterBar
            HStack(alignment: .top, spacing: 12) {
                commandTable
                KeyDetailView(key: selectedKey, context: context, commands: registry.commandsByBinding(in: context), layer: layer, selectedCommand: selectedCommand,
                              assign: { binding in selectedCommand.map { assign(binding, to: $0, slot: nil) } },
                              remove: { binding in remove(binding) },
                              selectCommand: { selectedCommand = $0 })
                    .frame(width: 240)
            }
            statusLine
        }
        .padding(16)
        .accessibilityIdentifier("settings.shortcuts")
        .onAppear {
            recorder.install()
            recorder.record = { binding, target in assign(binding, to: target.command, slot: target.slot) }
            recorder.onCancel = { status = nil }
        }
        .onDisappear { recorder.uninstall() }
        .onChange(of: context) { _, _ in
            recorder.cancel()
            category = nil
            if selectedCommand?.context != context { selectedCommand = nil }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
            layout = .current()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == KeyboardPreset.fileExtension }) else { return false }
            recorder.cancel()
            importPreset(from: url)
            return true
        }
        .sheet(isPresented: $showsBuiltInShortcuts) { BuiltInShortcutsSheet() }
        .confirmationDialog(pendingReassignment.map { String(localized: "\($0.binding.display) is assigned to “\($0.current.title)”.") } ?? "",
                            isPresented: Binding(get: { pendingReassignment != nil }, set: { if !$0 { pendingReassignment = nil } }),
                            presenting: pendingReassignment) { pending in
            Button(String(localized: "Reassign to “\(pending.command.title)”")) {
                if let error = registry.reassign(pending.binding, to: pending.command, slot: pending.slot) {
                    status = .error(error)
                } else {
                    status = .info(String(localized: "\(pending.binding.display) now runs “\(pending.command.title)” instead of “\(pending.current.title)”."))
                    selectedKeyID = layout.key(for: pending.binding)?.id ?? selectedKeyID
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("Reassigning removes the shortcut from “\(pending.current.title)”.")
        }
        .confirmationDialog(String(localized: "Discard the changes to “\(activePresetTitle)”?"),
                            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
                            presenting: pendingDiscard) { action in
            Button("Discard Changes", role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your current shortcuts have not been saved to a preset. Use Save As to keep them.")
        }
        .confirmationDialog(String(localized: "Delete the preset “\(activePresetTitle)”?"), isPresented: $confirmDelete) {
            Button("Delete Preset", role: .destructive) {
                let name = registry.activePresetName
                registry.deletePreset(named: name)
                status = .info(String(localized: "Deleted “\(name)”. Your current shortcuts are unchanged."))
            }
        } message: {
            Text("The current shortcuts stay as they are. Exported copies of the preset are not affected.")
        }
        .alert(namePrompt?.title ?? "", isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } }),
               presenting: namePrompt) { prompt in
            TextField("Preset name", text: $proposedName)
            Button(prompt == .rename ? String(localized: "Rename") : String(localized: "Save")) { submitName(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt == .rename ? String(localized: "Enter a new name for this preset.") : String(localized: "Save the current shortcuts as a new preset."))
        }
    }

    // MARK: Presets

    private var presetBar: some View {
        HStack(spacing: 8) {
            Text("Preset").foregroundStyle(.secondary)
            Picker("Preset", selection: Binding(get: { registry.activePresetName }, set: { name in
                guard name != registry.activePresetName else { return }
                confirmingDiscard(.switchTo(name))
            })) {
                Text(ShortcutRegistry.displayName(ofPreset: KeyboardPreset.builtInName)).tag(KeyboardPreset.builtInName)
                if !registry.presets.isEmpty { Divider() }
                ForEach(registry.presets) { Text(verbatim: $0.name).tag($0.name) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier("settings.shortcuts.preset")
            if registry.isModified {
                Text("Modified")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .help("The shortcuts differ from the saved preset.")
            }
            Spacer()
            Button("Save") {
                if let error = registry.savePreset(named: registry.activePresetName) { status = .error(error) }
                else { status = .info(String(localized: "Saved “\(activePresetTitle)”.")) }
            }
            .disabled(registry.isBuiltInPresetActive || !registry.isModified)
            .help(registry.isBuiltInPresetActive ? String(localized: "The built-in preset cannot be changed. Use Save As.") : String(localized: "Save the changes to this preset."))
            Button("Save As…") { prompt(.saveAs) }
            Menu {
                Button("Import…", action: chooseImport)
                    .help(String(localized: "Add a preset from a .\(KeyboardPreset.fileExtension) file. You can also drop the file on this window."))
                Button("Export…", action: export)
                Divider()
                Button("Rename…") { prompt(.rename) }.disabled(registry.isBuiltInPresetActive)
                Button("Delete…") {
                    recorder.cancel()
                    confirmDelete = true
                }.disabled(registry.isBuiltInPresetActive)
                Divider()
                Button("Revert to Saved Preset") { confirmingDiscard(.switchTo(registry.activePresetName)) }.disabled(!registry.isModified)
                Button("Restore Defaults") { confirmingDiscard(.switchTo(KeyboardPreset.builtInName)) }
                    .disabled(registry.isBuiltInPresetActive && !registry.isModified)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More preset actions")
            .accessibilityLabel("More preset actions")
            ShareLink(item: KeyboardPresetShareItem(name: activePresetTitle, preset: registry.currentPreset),
                      preview: SharePreview(activePresetTitle, image: Image(systemName: "keyboard"))) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share the current shortcuts as a preset file.")
        }
    }

    private enum PresetAction { case switchTo(String), importPreset(KeyboardPreset) }
    private enum NamePrompt: Equatable {
        case saveAs, rename
        var title: String { self == .saveAs ? String(localized: "Save Preset As") : String(localized: "Rename Preset") }
    }

    private func confirmingDiscard(_ action: PresetAction) {
        recorder.cancel()
        if registry.isModified { pendingDiscard = action } else { perform(action) }
    }
    private func perform(_ action: PresetAction) {
        switch action {
        case let .switchTo(name):
            let rejected = registry.applyPreset(named: name)
            status = .info(String(localized: "Switched to “\(ShortcutRegistry.displayName(ofPreset: name))”.") + Self.skippedNote(rejected))
        case let .importPreset(preset):
            let result = registry.importPreset(preset)
            status = .info(String(localized: "Imported “\(result.name)”.") + Self.skippedNote(result.rejected))
        }
    }
    private static func skippedNote(_ rejected: Int) -> String {
        rejected == 0 ? "" : " " + String(localized: "Shortcuts skipped because they are reserved or duplicated: \(rejected)")
    }
    private func prompt(_ prompt: NamePrompt) {
        recorder.cancel()
        proposedName = prompt == .rename || !registry.isBuiltInPresetActive ? registry.activePresetName : String(localized: "My Shortcuts")
        if prompt == .saveAs, registry.preset(named: proposedName) != nil { proposedName += " " + String(localized: "Copy") }
        namePrompt = prompt
    }
    private func submitName(_ prompt: NamePrompt) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .saveAs:
            if name != registry.activePresetName, registry.preset(named: name) != nil {
                status = .error(String(localized: "A preset named “\(name)” already exists. Choose it and use Save, or pick another name."))
            } else if let error = registry.savePreset(named: name) {
                status = .error(error)
            } else {
                status = .info(String(localized: "Saved “\(name)”."))
            }
        case .rename:
            let oldName = registry.activePresetName
            if let error = registry.renamePreset(oldName, to: name) { status = .error(error) }
            else { status = .info(String(localized: "Renamed “\(oldName)” to “\(name)”.")) }
        }
    }
    private func chooseImport() {
        recorder.cancel()
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Keyboard Preset")
        panel.allowedContentTypes = [.mediaConverterKeyboardPreset, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPreset(from: url)
    }
    private func importPreset(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { confirmingDiscard(.importPreset(try KeyboardPreset(fileData: Data(contentsOf: url)))) }
        catch { status = .error(String(localized: "Could not import \(url.lastPathComponent): \(error.localizedDescription)")) }
    }
    private func export() {
        recorder.cancel()
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Keyboard Preset")
        panel.nameFieldStringValue = KeyboardPresetShareItem.fileName(for: activePresetTitle)
        panel.allowedContentTypes = [.mediaConverterKeyboardPreset]
        panel.message = String(localized: "Anyone with Media Converter can import this file in Settings → Shortcuts.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try registry.currentPreset.fileData().write(to: url, options: .atomic)
            status = .info(String(localized: "Exported \(url.lastPathComponent)."))
        } catch { status = .error(String(localized: "Could not export the preset: \(error.localizedDescription)")) }
    }

    // MARK: Keyboard

    private var contextBar: some View {
        HStack(spacing: 10) {
            Picker("Shortcuts for", selection: $context) {
                ForEach(ShortcutContext.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("settings.shortcuts.context")
            Spacer()
            Button("Built-in Shortcuts…") {
                recorder.cancel()
                showsBuiltInShortcuts = true
            }
                .buttonStyle(.link)
                .help("Shortcuts in overlays, sheets and other windows, which cannot be changed")
        }
    }

    /// Keys holding any shortcut of the selected command, in any modifier layer.
    private var highlightedKeyIDs: Set<VirtualKey.ID> {
        guard let selectedCommand, selectedCommand.context == context else { return [] }
        return Set(registry.bindings(for: selectedCommand).flatMap { binding in
            layout.keys.filter { $0.candidates(with: binding.modifiers).contains(binding) }.map(\.id)
        })
    }

    private var contextCategories: [ShortcutCategory] {
        ShortcutCategory.allCases.filter { category in ShortcutCommand.allCases.contains { $0.context == context && $0.category == category } }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(contextCategories) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 10, height: 10)
                    Text(verbatim: category.title)
                }
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 10, height: 10)
                Text("Reserved")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func dropCommand(_ command: ShortcutCommand, on key: VirtualKey) -> Bool {
        guard command.context == context, let binding = key.binding(with: layer) else { return false }
        selectedKeyID = key.id
        selectedCommand = command
        assign(binding, to: command, slot: nil)
        return true
    }

    // MARK: Commands

    private enum AssignmentFilter: CaseIterable, Identifiable {
        case all, assigned, unassigned, changed
        var id: Self { self }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .assigned: String(localized: "Assigned")
            case .unassigned: String(localized: "Unassigned")
            case .changed: String(localized: "Changed")
            }
        }
    }

    private var filteredCommands: [ShortcutCommand] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let categoryOrder = ShortcutCategory.allCases
        return ShortcutCommand.allCases.filter { command in
            guard command.context == context else { return false }
            let bindings = registry.bindings(for: command)
            if let category, command.category != category { return false }
            switch filter {
            case .all: break
            case .assigned: if bindings.isEmpty { return false }
            case .unassigned: if !bindings.isEmpty { return false }
            case .changed: if bindings == command.defaultBindings { return false }
            }
            guard !words.isEmpty else { return true }
            let text = ([command.title, command.shortTitle, command.category.title] + bindings.map(\.searchText)).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        .sorted {
            let order = (categoryOrder.firstIndex(of: $0.category) ?? 0, categoryOrder.firstIndex(of: $1.category) ?? 0)
            return order.0 != order.1 ? order.0 < order.1 : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("Search", text: $search, prompt: Text("Search commands or shortcuts, such as “trim” or “cmd t”"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.shortcuts.search")
            Picker("Category", selection: $category) {
                Text("All Categories").tag(ShortcutCategory?.none)
                Divider()
                ForEach(contextCategories) { Text(verbatim: $0.title).tag(ShortcutCategory?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Show", selection: $filter) {
                ForEach(AssignmentFilter.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var commandTable: some View {
        Table(of: ShortcutCommand.self, selection: $selectedCommandID) {
            TableColumn("Command") { command in
                HStack(spacing: 6) {
                    Circle().fill(command.category.color).frame(width: 7, height: 7)
                    Text(verbatim: command.title).lineLimit(1)
                }
                .help(String(localized: "\(command.title) · \(command.category.title). Drag onto a key to assign it."))
            }
            TableColumn("Shortcut") { command in shortcutField(command, slot: 0) }.width(min: 70, ideal: 90, max: 120)
            TableColumn("Alternate") { command in shortcutField(command, slot: 1) }.width(min: 70, ideal: 90, max: 120)
        } rows: {
            ForEach(filteredCommands) { command in
                TableRow(command).draggable(command.rawValue)
            }
        }
        .frame(minHeight: 150)
    }

    private func shortcutField(_ command: ShortcutCommand, slot: Int) -> some View {
        let target = ShortcutRecorder.Target(command: command, slot: slot)
        let binding = registry.keymap.binding(for: command, slot: slot)
        // The alternate field waits for the first, since a command's shortcuts stay in order.
        let available = slot < registry.bindings(for: command).count + 1
        return ShortcutField(binding: binding, isRecording: recorder.target == target, heldModifiers: recorder.heldModifiers,
                             isAvailable: available, identifier: "settings.shortcuts.\(command.rawValue).\(slot)",
                             toggle: {
                                 selectedCommand = command
                                 recorder.toggle(target)
                                 if recorder.target != nil {
                                     status = .info(String(localized: "Press the new shortcut for “\(command.title)”. Click the field again to cancel."))
                                 } else {
                                     status = nil
                                 }
                             },
                             clear: { remove(binding) })
    }

    // MARK: Assigning

    private struct Assignment {
        let binding: ShortcutBinding
        let command: ShortcutCommand
        let slot: Int
        let current: ShortcutCommand
    }

    /// Assigns after checking for reserved keys and conflicts. Without a slot, the
    /// shortcut fills the command's free slot, or replaces its alternate.
    private func assign(_ binding: ShortcutBinding, to command: ShortcutCommand, slot: Int?) {
        let keymap = registry.keymap
        if keymap.bindings(for: command).contains(binding.normalized) {
            status = .info(String(localized: "\(binding.display) already runs “\(command.title)”."))
            return
        }
        let slot = slot ?? min(keymap.bindings(for: command).count, Keymap.slotCount - 1)
        if binding.validationError(for: command) == nil,
           let current = keymap.conflict(for: binding, command: command, slot: slot), current != command {
            pendingReassignment = Assignment(binding: binding.normalized, command: command, slot: slot, current: current)
            return
        }
        if let error = registry.set(binding, for: command, slot: slot) {
            status = .error("\(binding.display): \(error)")
        } else {
            let shortcuts = registry.bindings(for: command).map(\.display).joined(separator: ", ")
            status = .info("\(command.title): \(shortcuts)")
            selectedKeyID = layout.key(for: binding)?.id ?? selectedKeyID
        }
    }
    private func remove(_ binding: ShortcutBinding) {
        guard let found = registry.keymap.assignment(of: binding, in: context) else { return }
        _ = registry.set(ShortcutBinding(key: ""), for: found.command, slot: found.slot)
        status = .info(String(localized: "Removed \(binding.display) from “\(found.command.title)”."))
    }

    // MARK: Status

    private enum Status {
        case info(String), error(String)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch status {
            case let .error(text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(verbatim: text).foregroundStyle(.red)
            case let .info(text):
                Text(verbatim: text).foregroundStyle(.secondary)
            case nil:
                Text("Click a shortcut field and press keys to record, or drag a command onto a key. Click or hold ⌘ ⌥ ⌃ ⇧ to see other layers. Each command can have two shortcuts.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(2)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
        .accessibilityIdentifier("settings.shortcuts.status")
    }
}

extension UTType {
    static let mediaConverterKeyboardPreset = UTType(exportedAs: KeyboardPreset.fileFormat, conformingTo: .json)
}

/// The current shortcuts as a preset file, for the share menu.
struct KeyboardPresetShareItem: Transferable {
    let name: String
    let preset: KeyboardPreset

    static func fileName(for name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-") + "." + KeyboardPreset.fileExtension
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mediaConverterKeyboardPreset) { item in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName(for: item.name))
            try item.preset.fileData().write(to: url)
            return SentTransferredFile(url)
        }
    }
}

/// Records the next key press for a command's shortcut, and tracks held modifiers so
/// the on-screen keyboard can show that layer.
@MainActor
final class ShortcutRecorder: ObservableObject {
    struct Target: Equatable {
        let command: ShortcutCommand
        let slot: Int
    }
    @Published private(set) var target: Target? {
        // Keeps the text-editing guard from handing the recorded key to a focused field.
        didSet {
            let active = target != nil
            isActivelyRecording = active
            ShortcutRegistry.shared.isRecording = active
            if !active {
                removeWindowObservers()
                window = nil
            }
        }
    }
    @Published private(set) var heldModifiers: ShortcutModifiers = []
    var record: ((ShortcutBinding, Target) -> Void)?
    var onCancel: (() -> Void)?
    nonisolated(unsafe) private var monitors: [Any] = []
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var isActivelyRecording = false
    private weak var window: NSWindow?

    func toggle(_ newTarget: Target, in targetWindow: NSWindow? = NSApp.keyWindow) {
        if target == newTarget {
            target = nil
        } else {
            window = targetWindow
            target = newTarget
            observeWindow(targetWindow)
        }
    }
    func cancel() {
        let wasRecording = target != nil
        target = nil
        if wasRecording { onCancel?() }
    }
    func install() {
        guard monitors.isEmpty else { return }
        // Recording takes every key in the editor's window, including ones menus would
        // otherwise handle, so that reserved chords can be explained rather than run.
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let window = event.window
            // Recorded by U.S. position where the layout types another character, so the
            // shortcut keeps working after a switch to another layout.
            let pressed = ShortcutBinding.recorded(event)
            let recorded = !event.isARepeat && MainActor.assumeIsolated { () -> Bool in
                guard let self, let target = self.target, window === self.window else { return false }
                self.target = nil
                if let pressed {
                    self.record?(pressed, target)
                } else {
                    self.onCancel?()
                }
                return true
            }
            return recorded ? nil : event
        }
        let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.heldModifiers = ShortcutModifiers(event.modifierFlags) }
            return event
        }
        monitors = [keyMonitor, flagsMonitor].compactMap { $0 }
    }
    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        removeWindowObservers()
        target = nil
        heldModifiers = []
    }

    private func observeWindow(_ window: NSWindow?) {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
    }

    private func removeWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if isActivelyRecording {
            if Thread.isMainThread {
                MainActor.assumeIsolated { ShortcutRegistry.shared.isRecording = false }
            } else {
                Task { @MainActor in ShortcutRegistry.shared.isRecording = false }
            }
        }
    }
}

private struct ShortcutField: View {
    let binding: ShortcutBinding
    let isRecording: Bool
    let heldModifiers: ShortcutModifiers
    let isAvailable: Bool
    let identifier: String
    let toggle: () -> Void
    let clear: () -> Void
    @State private var hovering = false

    private var label: String {
        if isRecording { return heldModifiers.isEmpty ? String(localized: "Type shortcut…") : heldModifiers.symbols + "…" }
        return binding.display
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: toggle) {
                Text(verbatim: label)
                    .font(binding.isEmpty || isRecording ? .callout : .callout.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(isRecording ? Color.accentColor : binding.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(hovering ? 0.15 : 0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isRecording ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .help(isRecording ? String(localized: "Press keys to record. Click again to cancel.") : String(localized: "Click, then press the shortcut to record it."))
            .accessibilityLabel(binding.isEmpty ? String(localized: "No shortcut. Record shortcut") : String(localized: "Shortcut \(binding.display). Record new shortcut"))
            .accessibilityValue(binding.display)
            .accessibilityIdentifier(identifier)
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(binding.isEmpty || isRecording ? 0 : 1)
                .disabled(binding.isEmpty || isRecording)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove this shortcut")
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Built-in shortcuts

/// Shortcuts in overlays, sheets and other windows, which the editor cannot change.
private struct BuiltInShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(Self.groups, id: \.title) { group in
                    Section(header: Text(LocalizedStringKey(group.title))) {
                        ForEach(group.shortcuts, id: \.description) { shortcut in
                            HStack(alignment: .center, spacing: 16) {
                                Text(LocalizedStringKey(shortcut.description)).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                KeyboardShortcutBadge(keys: shortcut.keys)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
    }

    private struct Group {
        let title: String
        let shortcuts: [(keys: String, description: String)]
    }

    private static let groups: [Group] = [
        Group(title: "Main Window – Other", shortcuts: [
            ("Cmd + ,", "Open Settings"),
            ("Escape", "Close the overlay (settings automatically saved)"),
        ]),
        Group(title: "Trim View – Timecode Input", shortcuts: [
            ("+/-", "Jump seconds back/forward when pressing Enter"),
            ("0-9", "Activate timecode input, press Enter to jump"),
            ("Full timecode", "hours:minutes:seconds:frames supported"),
        ]),
        Group(title: "Trim View – Tools", shortcuts: [
            ("Escape", "Close editor"),
        ]),
        Group(title: "Trim View – Timeline Modifiers", shortcuts: [
            ("Cmd", "Range selection: click and drag to set in/out points"),
            ("Shift", "Range sliding: drag to move entire trim range"),
            ("Option", "Symmetric scaling: drag handle to move both symmetrically"),
        ]),
        Group(title: "Crop Mode", shortcuts: [
            ("Shift", "Hold before dragging to keep the crop box’s shape"),
        ]),
        Group(title: "Fullscreen Player – Other", shortcuts: [
            ("0-9, +, -, ., :, ;", "Activate timecode input"),
            ("Escape", "Close fullscreen player"),
        ]),
        Group(title: "Metadata Window", shortcuts: [
            ("Cmd + F", "Search fields and values"),
            ("Escape", "Clear search"),
        ]),
        Group(title: "Audio Routing View", shortcuts: [
            ("Ctrl + M", "Toggle mute audio"),
            ("Cmd + 1-8", "Toggle individual audio track (1-8)"),
            ("Cmd + Option + 1-9", "Toggle stereo for output track position"),
            ("Cmd + Option + S", "Toggle stereo for all surround tracks"),
            ("Escape", "Close audio routing"),
        ]),
        Group(title: "Timecode Configuration View", shortcuts: [
            ("Cmd + 1", "Switch to Preserve Source mode"),
            ("Cmd + 2", "Switch to Manual mode"),
            ("Cmd + 3", "Switch to Disabled mode"),
            ("0-9", "Start typing in manual mode"),
            ("Escape", "Close timecode configuration"),
        ]),
        Group(title: "Settings Window", shortcuts: [
            ("Ctrl + 1", "General"),
            ("Ctrl + 2", "Metadata"),
            ("Ctrl + 3", "Presets"),
            ("Ctrl + 4", "Screen Capture"),
            ("Ctrl + 5", "Waveform"),
            ("Ctrl + 6", "Watch Folder"),
            ("Ctrl + 7", "Downloads"),
            ("Ctrl + 8", "Upload"),
            ("Ctrl + 9", "Transcription"),
            ("Ctrl + 0", "Analytics"),
            ("Ctrl + A", "Updates"),
            ("Ctrl + K", "Shortcuts"),
        ]),
        Group(title: "URL Input Overlay", shortcuts: [
            ("Down Arrow", "Navigate into download history (older entries)"),
            ("Up Arrow", "Navigate back (newer entries or original text)"),
            ("Return", "Submit URL and start download"),
            ("Escape", "Close URL input overlay"),
        ]),
        Group(title: "Preset Quick-Select Overlay", shortcuts: [
            ("Up Arrow", "Navigate through presets"),
            ("Down Arrow", "Navigate through presets"),
            ("Return", "Confirm selection"),
            ("Cmd + 1-9, 0", "Instantly select preset (0 = 10th)"),
            ("Escape", "Close without changing"),
        ]),
        Group(title: "Capture Mode", shortcuts: [
            ("Escape", "Close/Cancel capture mode"),
            ("Cmd + .", "Close/Cancel capture mode"),
        ]),
    ]
}

private struct KeyboardShortcutBadge: View {
    let keys: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys.components(separatedBy: " + "), id: \.self) { key in
                KeyCap(key: key)
            }
        }
    }
}

private struct KeyCap: View {
    let key: String

    var body: some View {
        Text(displayKey(key))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
    }

    private func displayKey(_ key: String) -> String {
        // Convert key names to symbols where appropriate
        switch key.lowercased() {
        case "cmd", "command": return "\u{2318}"
        case "option", "alt": return "\u{2325}"
        case "shift": return "\u{21E7}"
        case "control", "ctrl": return "\u{2303}"
        case "return", "enter": return "\u{21A9}"
        case "backspace", "delete": return "\u{232B}"
        case "escape", "esc": return "\u{238B}"
        case "tab": return "\u{21E5}"
        case "space": return "\u{2423}"
        case "up arrow": return "\u{2191}"
        case "down arrow": return "\u{2193}"
        case "left arrow": return "\u{2190}"
        case "right arrow": return "\u{2192}"
        default: return key
        }
    }
}
