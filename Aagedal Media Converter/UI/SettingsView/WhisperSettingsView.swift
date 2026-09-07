// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct WhisperSettingsView: View {
    @State private var installationStatus: WhisperInstallationStatus = .notInstalled
    @State private var isCheckingStatus = true

    @State private var downloadedModels: [WhisperModel] = []
    @State private var modelDownloadProgress: [WhisperModel: Double] = [:]
    @State private var modelDownloading: Set<WhisperModel> = []
    @State private var downloadError: String?
    @State private var showDeleteAllModelsConfirmation = false

    @AppStorage(AppConstants.whisperModelKey) private var selectedModel = AppConstants.defaultWhisperModel
    @AppStorage(AppConstants.whisperCustomModelPathKey) private var customModelPath = ""
    @AppStorage(AppConstants.whisperLanguageKey) private var selectedLanguage = AppConstants.defaultWhisperLanguage
    @AppStorage(AppConstants.whisperDefaultEnabledKey) private var defaultEnabled = false
    @AppStorage(AppConstants.whisperMaxLineLengthKey) private var maxLineLength = AppConstants.defaultWhisperMaxLineLength

    var body: some View {
        Group {
            whisperStatusSection
            modelManagementSection
            defaultSettingsSection
            aboutSection
        }
        .task {
            await loadState()
        }
        .onChange(of: customModelPath) { _, _ in
            if selectedModel == WhisperModel.custom.rawValue && !customModelExists {
                selectedModel = AppConstants.defaultWhisperModel
            }
        }
        .confirmationDialog(
            "Delete All Models",
            isPresented: $showDeleteAllModelsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Models", role: .destructive) {
                deleteAllModels()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete all downloaded Whisper models. You will need to re-download them to use transcription.")
        }
    }

    // MARK: - Whisper Status Section

    private var whisperStatusSection: some View {
        Section(header: Text("whisper.cpp (Subtitle Generation)")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if isCheckingStatus {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Checking...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    } else {
                        switch installationStatus {
                        case .notInstalled:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("whisper.cpp not available")
                                .font(.headline)
                        case .installed(let version):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Ready")
                                .font(.headline)
                            Spacer()
                            Text(version)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        case .updateAvailable(_, _):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Ready")
                                .font(.headline)
                        }
                    }
                }

                if downloadedModels.isEmpty && !isCheckingStatus {
                    Text("Download a model below to enable subtitle generation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Model Management Section

    private var modelManagementSection: some View {
        Section(header: Text("Models")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Download models for transcription. Larger models are more accurate but slower and require more RAM.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                let models = WhisperModel.downloadableCases
                ForEach(models, id: \.self) { model in
                    modelRow(for: model)
                    if model != models.last {
                        Divider()
                    }
                }

                if !models.isEmpty {
                    Divider()
                }

                customModelRow

                if let error = downloadError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if !downloadedModels.isEmpty {
                    Divider()

                    HStack {
                        let totalSize = formatBytes(getTotalModelsSize())
                        Text("Total size: \(totalSize)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            revealModelsInFinder()
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Show in Finder")

                        Spacer()

                        Button(role: .destructive) {
                            showDeleteAllModelsConfirmation = true
                        } label: {
                            Text("Delete All Models")
                        }
                        .disabled(modelDownloading.count > 0)
                    }
                }
            }
            .padding(8)
        }
    }

    private func modelRow(for model: WhisperModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.displayName)
                        .font(.headline)

                    if selectedModel == model.rawValue {
                        Text("Selected")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }

                Text(LocalizedStringKey(model.description))
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Text(model.fileSize)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("RAM: \(model.ramRequirement)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if modelDownloading.contains(model) {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: modelDownloadProgress[model] ?? 0)
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                        Text("\(Int((modelDownloadProgress[model] ?? 0) * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        cancelDownload(model)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
            } else if downloadedModels.contains(model) {
                HStack(spacing: 8) {
                    if selectedModel != model.rawValue {
                        Button("Select") {
                            selectedModel = model.rawValue
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(role: .destructive) {
                        deleteModel(model)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    downloadModel(model)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Default Settings Section

    private var defaultSettingsSection: some View {
        Section(header: Text("Default Settings")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable subtitles by default for new items", isOn: $defaultEnabled)
                    .toggleStyle(SwitchToggleStyle())

                Text("When enabled, new video files added to the queue will have subtitle generation enabled automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text("Default model:")
                        .frame(width: 100, alignment: .trailing)

                    Picker("", selection: $selectedModel) {
                        ForEach(selectableModels, id: \.self) { model in
                            HStack {
                                Text(model.displayName)
                                if model.isCustom {
                                    Text("(custom file)")
                                        .foregroundColor(.secondary)
                                } else if !downloadedModels.contains(model) {
                                    Text("(not downloaded)")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tag(model.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                HStack {
                    Text("Default language:")
                        .frame(width: 100, alignment: .trailing)

                    Picker("", selection: $selectedLanguage) {
                        ForEach(WhisperLanguage.allCases, id: \.self) { language in
                            Text(language.displayName)
                                .tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                Text("Use 'Auto-detect' for mixed-language content. Specifying a language can improve accuracy for single-language audio.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text("Max line length:")
                        .frame(width: 100, alignment: .trailing)

                    Slider(value: Binding(
                        get: { Double(maxLineLength) },
                        set: { maxLineLength = Int($0) }
                    ), in: 20...80, step: 1)
                    .frame(width: 150)

                    Text("\(maxLineLength) chars")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80)
                }

                Text("Controls the maximum characters per subtitle line. Default is 42, which works well for most video players. Use lower values for mobile devices.")
                    .font(.caption)
                    .foregroundColor(.secondary)

            }
            .padding(8)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section(header: Text("About")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("whisper.cpp is a high-performance C++ implementation of OpenAI's Whisper speech recognition model. It can transcribe audio in multiple languages and generate SRT subtitle files.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Subtitles are generated from the audio track after conversion completes. The SRT file is saved alongside the output video.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Link("whisper.cpp", destination: URL(string: "https://github.com/ggerganov/whisper.cpp")!)
                    Spacer()
                    Link("OpenAI Whisper", destination: URL(string: "https://openai.com/research/whisper")!)
                }
                .font(.callout)
            }
            .padding(8)
        }
    }

    // MARK: - Actions

    private func loadState() async {
        isCheckingStatus = true
        downloadedModels = WhisperModelManager.shared.getDownloadedModels()

        if selectedModel == WhisperModel.custom.rawValue && !customModelExists {
            selectedModel = AppConstants.defaultWhisperModel
        }

        let updates = await WhisperUpdateService.shared.stateUpdates()
        for await state in updates {
            guard !Task.isCancelled else { return }
            isCheckingStatus = state.installationStatus == nil
            if let status = state.installationStatus {
                installationStatus = status
            }
        }
    }

    private func downloadModel(_ model: WhisperModel) {
        modelDownloading.insert(model)
        modelDownloadProgress[model] = 0
        downloadError = nil

        Task {
            do {
                try await WhisperModelManager.shared.downloadModel(model) { progress in
                    Task { @MainActor in
                        modelDownloadProgress[model] = progress
                    }
                }
                await MainActor.run {
                    downloadedModels = WhisperModelManager.shared.getDownloadedModels()
                    modelDownloading.remove(model)
                    modelDownloadProgress.removeValue(forKey: model)

                    // Auto-select if it's the first model
                    if downloadedModels.count == 1 {
                        selectedModel = model.rawValue
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    modelDownloading.remove(model)
                    modelDownloadProgress.removeValue(forKey: model)
                }
            } catch {
                await MainActor.run {
                    modelDownloading.remove(model)
                    modelDownloadProgress.removeValue(forKey: model)
                    downloadError = "Failed to download \(model.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelDownload(_ model: WhisperModel) {
        Task {
            await WhisperModelManager.shared.cancelDownload(for: model)
            await MainActor.run {
                modelDownloading.remove(model)
                modelDownloadProgress.removeValue(forKey: model)
            }
        }
    }

    private func deleteModel(_ model: WhisperModel) {
        Task {
            do {
                try await WhisperModelManager.shared.deleteModel(model)
                await MainActor.run {
                    downloadedModels = WhisperModelManager.shared.getDownloadedModels()
                }
            } catch {
                await MainActor.run {
                    downloadError = "Failed to delete \(model.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteAllModels() {
        Task {
            do {
                try await WhisperModelManager.shared.deleteAllModels()
                await MainActor.run {
                    downloadedModels = []
                }
            } catch {
                await MainActor.run {
                    downloadError = "Failed to delete models: \(error.localizedDescription)"
                }
            }
        }
    }

    private func getTotalModelsSize() -> Int64 {
        var total: Int64 = 0
        for model in downloadedModels {
            total += model.fileSizeBytes
        }
        return total
    }

    private func revealModelsInFinder() {
        let directory = AppConstants.whisperModelsDirectory
        let urls = downloadedModels
            .map { WhisperModelManager.shared.modelPath(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let bytesDouble = Double(bytes)

        if bytesDouble < mb {
            return String(format: "%.0f KB", bytesDouble / kb)
        } else if bytesDouble < gb {
            return String(format: "%.1f MB", bytesDouble / mb)
        } else {
            return String(format: "%.2f GB", bytesDouble / gb)
        }
    }

    private var customModelURL: URL? {
        let trimmed = customModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    private var customModelExists: Bool {
        guard let url = customModelURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var selectableModels: [WhisperModel] {
        var models = WhisperModel.downloadableCases
        if customModelExists {
            models.append(.custom)
        }
        return models
    }

    private var customModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Custom model path:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if selectedModel == WhisperModel.custom.rawValue {
                    Text("Selected")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                }
            }

            HStack(spacing: 8) {
                TextField("Select Whisper model (.bin)", text: $customModelPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button("Browse...") {
                    selectCustomModel()
                }

                if !customModelPath.isEmpty {
                    Button(role: .destructive) {
                        clearCustomModel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !customModelPath.isEmpty && !customModelExists {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Custom model not found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func selectCustomModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Whisper model"
        panel.message = "Choose a GGML Whisper model file (.bin)."
        panel.prompt = "Select"
        panel.allowedContentTypes = [.data]
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = false
        panel.resolvesAliases = false

        if panel.runModal() == .OK, let url = panel.url {
            customModelPath = url.path
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
            selectedModel = WhisperModel.custom.rawValue
        }
    }

    private func clearCustomModel() {
        customModelPath = ""
        if selectedModel == WhisperModel.custom.rawValue {
            selectedModel = AppConstants.defaultWhisperModel
        }
    }
}

#Preview {
    Form {
        WhisperSettingsView()
    }
    .formStyle(.grouped)
}
