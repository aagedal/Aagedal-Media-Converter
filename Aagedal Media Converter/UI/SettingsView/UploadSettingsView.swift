// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UploadSettingsView: View {
    // MARK: - State

    @State private var rcloneStatus: RcloneInstallationStatus = .notInstalled
    @State private var rcloneVersion: String?
    @State private var rcloneCustomPath: String = ""
    @AppStorage(AppConstants.rcloneBinarySourceKey) private var rcloneBinarySource = BinarySourceSelection.app.rawValue

    @State private var isTesting = false
    @State private var testResult: TestResult?

    // Profiles
    @State private var profiles: [UploadProfile] = UploadProfileStore.loadProfiles()
    @AppStorage(AppConstants.uploadSelectedProfileIDKey) private var selectedProfileID = ""

    // Upload behavior
    @AppStorage(AppConstants.uploadDefaultEnabledKey) private var uploadDefaultEnabled = false
    @AppStorage(AppConstants.uploadRetryCountKey) private var retryCount = AppConstants.defaultUploadRetryCount

    // Transient credential entry state. Actual credentials live in the Keychain,
    // keyed by (server, username) for FTP/SFTP/SMB and by access-key for S3.
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var s3SecretKey = ""
    @State private var hasStoredS3SecretKey = false

    // FileZilla import
    @State private var fileZillaSites: [FileZillaSite] = []
    @State private var isFileZillaSheetPresented = false
    @State private var fileZillaImportError: String?
    @State private var fileZillaImportSummary: String?

    private enum Field: Hashable {
        case name, server, port, username, password, remotePath
        case sftpKeyFile
        case smbShare, smbDomain
        case s3Bucket, s3Region, s3Endpoint, s3AccessKey, s3SecretKey
    }
    @FocusState private var focusedField: Field?

    private enum TestResult {
        case success
        case failure(String)
    }

    // MARK: - Derived

    private var selectedProfileIndex: Int? {
        profiles.firstIndex { $0.id.uuidString == selectedProfileID }
    }

    private var selectedProfile: UploadProfile? {
        guard let index = selectedProfileIndex else { return nil }
        return profiles[index]
    }

    private var availableBackends: [UploadBackendType] {
        UploadBackendType.allCases.filter { $0.isImplemented }
    }

    var body: some View {
        Form {
            rcloneStatusSection
            profileSection
            uploadBehaviorSection
            testConnectionSection
        }
        .formStyle(.grouped)
        .task { await loadInitialState() }
        .onChange(of: selectedProfileID) { oldValue, _ in
            commitPendingCredentials(forProfileID: oldValue)
            refreshCredentialState()
            UploadManager.shared.refreshConfiguredStatus()
            testResult = nil
        }
        .onChange(of: focusedField) { oldValue, newValue in
            // Save credentials when focus leaves the password/secret field,
            // rather than on every keystroke (which would overwrite the
            // Keychain entry with each character).
            if oldValue == .password, newValue != .password, !password.isEmpty {
                savePassword()
            }
            if oldValue == .s3SecretKey, newValue != .s3SecretKey, !s3SecretKey.isEmpty {
                saveS3SecretKey()
            }
        }
        .onChange(of: rcloneBinarySource) { _, _ in
            Task { await refreshRcloneStatus() }
        }
        .onKeyPress(.tab, phases: .down) { keyPress in
            guard let current = focusedField else { return .ignored }
            let goingBackward = keyPress.modifiers.contains(.shift)
            let target = goingBackward ? previousField(before: current) : nextField(after: current)
            guard let target else { return .ignored }
            focusedField = target
            return .handled
        }
        .sheet(isPresented: $isFileZillaSheetPresented) {
            FileZillaImportSheet(
                sites: fileZillaSites,
                onCancel: { isFileZillaSheetPresented = false },
                onImport: { selected in
                    isFileZillaSheetPresented = false
                    completeFileZillaImport(selected)
                }
            )
        }
        .alert(
            "Could Not Import FileZilla File",
            isPresented: Binding(
                get: { fileZillaImportError != nil },
                set: { if !$0 { fileZillaImportError = nil } }
            ),
            presenting: fileZillaImportError
        ) { _ in
            Button("OK") { fileZillaImportError = nil }
        } message: { error in
            Text(error)
        }
        .alert(
            "FileZilla Import",
            isPresented: Binding(
                get: { fileZillaImportSummary != nil },
                set: { if !$0 { fileZillaImportSummary = nil } }
            ),
            presenting: fileZillaImportSummary
        ) { _ in
            Button("OK") { fileZillaImportSummary = nil }
        } message: { summary in
            Text(summary)
        }
    }

    // MARK: - rclone status

    private var selectedRcloneSource: BinarySourceSelection {
        BinarySourceSelection(rawValue: rcloneBinarySource) ?? .app
    }

    private var rcloneStatusText: Text {
        switch rcloneStatus {
        case .notInstalled:
            return Text("Not installed")
        case .bundled:
            return Text("Bundled")
        case .customPath(let path):
            return Text("Custom: \(path)")
        case .systemAvailable(let path):
            return Text("Homebrew: \(path)")
        }
    }

    private var rcloneStatusSection: some View {
        Section(header: Text("rclone")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: rcloneStatus.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(rcloneStatus.isAvailable ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        rcloneStatusText
                            .font(.headline)
                    }

                    Spacer()

                    if let version = rcloneVersion {
                        Text(version)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text("Source:")
                        .frame(width: 60, alignment: .trailing)
                    Picker("Source", selection: $rcloneBinarySource) {
                        Text("App (Bundled)").tag(BinarySourceSelection.app.rawValue)
                        Text("Homebrew").tag(BinarySourceSelection.homebrew.rawValue)
                        Text("Custom").tag(BinarySourceSelection.custom.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer()
                }

                switch selectedRcloneSource {
                case .app:
                    Text("Using a minimal rclone build shipped with the app, trimmed to only the backends this app needs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .homebrew:
                    if rcloneStatus.isAvailable {
                        Text("Using the rclone installed via Homebrew at /opt/homebrew/bin/rclone.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        homebrewInstallHint
                    }
                case .custom:
                    customPathPicker
                }
            }
            .padding(8)
        }
    }

    private var homebrewInstallHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("rclone was not found at /opt/homebrew/bin/rclone.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("To install via Homebrew, run this in Terminal:")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("brew install rclone")
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install rclone", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
            }

            Link("Don't have Homebrew? Install it first", destination: URL(string: "https://brew.sh")!)
                .font(.caption)
        }
    }

    private var customPathPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Custom rclone path:")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                TextField("Select rclone binary", text: $rcloneCustomPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button("Browse...") {
                    selectRcloneBinary()
                }

                if !rcloneCustomPath.isEmpty {
                    Button(role: .destructive) {
                        rcloneCustomPath = ""
                        saveRclonePath()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !rcloneCustomPath.isEmpty && !rcloneStatus.isAvailable {
                Text("This file is not a valid rclone binary (failed `--version` check).")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onChange(of: rcloneCustomPath) { _, _ in
            saveRclonePath()
        }
    }

    // MARK: - Profile

    @ViewBuilder
    private var profileSection: some View {
        Section(header: Text("Upload Profile")) {
            VStack(alignment: .leading, spacing: 10) {
                profilePicker

                if selectedProfile != nil {
                    Divider().padding(.vertical, 4)

                    LabeledContent("Profile Name") {
                        TextField("", text: binding(\.name, default: ""))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .name)
                    }

                    LabeledContent("Protocol") {
                        HStack {
                            Picker("Protocol", selection: backendBinding) {
                                ForEach(availableBackends, id: \.self) { backend in
                                    Text(backend.displayName).tag(backend)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }
                    }

                    Divider().padding(.vertical, 4)

                    backendSpecificFields
                } else {
                    Text("No upload profiles yet. Click + to create one.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                }
            }
            .padding(8)
        }
    }

    private var profilePicker: some View {
        LabeledContent("Profile") {
            HStack {
                Picker("", selection: $selectedProfileID) {
                    if profiles.isEmpty {
                        Text("No profiles").tag("")
                    } else {
                        ForEach(profiles) { profile in
                            Text(profile.displayLabel).tag(profile.id.uuidString)
                        }
                    }
                }
                .labelsHidden()
                .disabled(profiles.isEmpty)

                Menu {
                    ForEach(availableBackends, id: \.self) { backend in
                        Button("New \(backend.displayName) Profile") {
                            addProfile(backend: backend)
                        }
                    }
                    Divider()
                    Button("Import from FileZilla…") {
                        beginFileZillaImport()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add profile")

                Button {
                    deleteSelectedProfile()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(selectedProfile == nil)
                .help("Delete profile")
            }
        }
    }

    @ViewBuilder
    private var backendSpecificFields: some View {
        switch selectedProfile?.backend ?? .ftp {
        case .ftp:    ftpFields
        case .sftp:   sftpFields
        case .smb:    smbFields
        case .s3:     s3Fields
        case .gdrive: gdrivePlaceholder
        }
    }

    private var ftpFields: some View {
        Group {
            serverPortUserRow
            passwordField
            remotePathRow

            Toggle("Use FTPS (TLS encryption)", isOn: binding(\.useFTPS, default: false))
                .toggleStyle(SwitchToggleStyle())
        }
    }

    private var sftpFields: some View {
        Group {
            serverPortUserRow

            LabeledContent("Auth") {
                HStack {
                    Picker("", selection: binding(\.useKeyAuth, default: false)) {
                        Text("Password").tag(false)
                        Text("SSH Key").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                }
            }

            if selectedProfile?.useKeyAuth == true {
                LabeledContent("Key File") {
                    HStack {
                        TextField("", text: binding(\.keyFilePath, default: ""))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .sftpKeyFile)
                        Button("Browse...") { selectSSHKeyFile() }
                    }
                }
            } else {
                passwordField
            }

            remotePathRow
        }
    }

    private var smbFields: some View {
        Group {
            serverPortUserRow

            LabeledContent("Share") {
                TextField("", text: binding(\.smbShare, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .smbShare)
            }

            LabeledContent("Domain") {
                TextField("", text: binding(\.smbDomain, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .smbDomain)
            }

            passwordField
            remotePathRow
        }
    }

    private var s3Fields: some View {
        Group {
            LabeledContent("Bucket") {
                TextField("", text: binding(\.bucket, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .s3Bucket)
            }

            LabeledContent("Region") {
                HStack {
                    Picker("", selection: binding(\.region, default: "us-east-1")) {
                        Text("us-east-1 (N. Virginia)").tag("us-east-1")
                        Text("us-east-2 (Ohio)").tag("us-east-2")
                        Text("us-west-1 (N. California)").tag("us-west-1")
                        Text("us-west-2 (Oregon)").tag("us-west-2")
                        Text("eu-west-1 (Ireland)").tag("eu-west-1")
                        Text("eu-west-2 (London)").tag("eu-west-2")
                        Text("eu-central-1 (Frankfurt)").tag("eu-central-1")
                        Text("eu-north-1 (Stockholm)").tag("eu-north-1")
                        Text("ap-northeast-1 (Tokyo)").tag("ap-northeast-1")
                        Text("ap-southeast-1 (Singapore)").tag("ap-southeast-1")
                        Text("ap-southeast-2 (Sydney)").tag("ap-southeast-2")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240)
                    Spacer()
                }
            }

            LabeledContent("Endpoint") {
                TextField("Leave empty for AWS (or enter custom endpoint)", text: binding(\.endpoint, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .s3Endpoint)
            }

            Divider()

            LabeledContent("Access Key") {
                TextField("", text: binding(\.accessKeyID, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .s3AccessKey)
                    .onSubmit { focusedField = .s3SecretKey }
            }

            LabeledContent("Secret Key") {
                HStack {
                    SecureField(hasStoredS3SecretKey ? "••••••••" : "Secret Access Key", text: $s3SecretKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .s3SecretKey)
                        .onSubmit {
                            saveS3SecretKey()
                            focusedField = .remotePath
                        }
                    if hasStoredS3SecretKey {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .help("Secret key saved in Keychain")
                    }
                }
            }

            Divider()

            LabeledContent("Path/Prefix") {
                TextField("", text: binding(\.remotePath, default: "/"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .remotePath)
            }

            let bucket = selectedProfile?.bucket ?? ""
            let path = selectedProfile?.remotePath ?? ""
            Text("Files will be uploaded to: s3://\(bucket.isEmpty ? "bucket" : bucket)/\(path.isEmpty ? "" : path + "/")<filename>")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var gdrivePlaceholder: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Google Drive support is not yet implemented.")
                .foregroundColor(.secondary)
            Text("Please use FTP, SFTP, SMB, or S3 for now.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    // MARK: - Shared rows

    private var serverPortUserRow: some View {
        Group {
            LabeledContent("Server") {
                TextField("", text: binding(\.server, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .server)
                    .onSubmit { focusedField = .port }
            }

            LabeledContent("Port") {
                HStack {
                    TextField("", value: binding(\.port, default: AppConstants.defaultUploadPort), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .username }
                    Spacer()
                }
            }

            LabeledContent("Username") {
                TextField("", text: binding(\.username, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
            }
        }
    }

    private var remotePathRow: some View {
        LabeledContent("Path") {
            TextField("", text: binding(\.remotePath, default: "/"))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .remotePath)
                .onSubmit { focusedField = nil }
        }
    }

    private var passwordField: some View {
        LabeledContent("Password") {
            HStack {
                SecureField(hasStoredPassword ? "••••••••" : "Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        savePassword()
                        focusedField = .remotePath
                    }
                if hasStoredPassword {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .help("Password saved in Keychain")
                }
            }
        }
    }

    // MARK: - Upload behavior

    private var uploadBehaviorSection: some View {
        Section(header: Text("Upload Behavior")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable upload by default for new items", isOn: $uploadDefaultEnabled)
                    .toggleStyle(SwitchToggleStyle())

                Text("When enabled, new items added to the queue will automatically upload after conversion.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                LabeledContent("Retry attempts") {
                    Stepper("\(retryCount)", value: $retryCount, in: 0...5)
                        .frame(width: 120)
                }

                Text("Number of times to retry a failed upload before giving up.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Test connection

    private var testConnectionSection: some View {
        Section(header: Text("Test Connection")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting || !isConfigurationComplete)

                    if isTesting {
                        ProgressView().scaleEffect(0.7)
                    }

                    Spacer()

                    if let result = testResult {
                        switch result {
                        case .success:
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("Connection successful").foregroundColor(.green)
                            }
                        case .failure(let error):
                            HStack {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                Text(error).foregroundColor(.red).lineLimit(2)
                            }
                        }
                    }
                }

                if !isConfigurationComplete, let hint = configurationHint {
                    Text(hint).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var isConfigurationComplete: Bool {
        guard let profile = selectedProfile else { return false }
        switch profile.backend {
        case .ftp:
            return !profile.server.isEmpty && !profile.username.isEmpty && hasStoredPassword
        case .sftp:
            if profile.useKeyAuth {
                return !profile.server.isEmpty && !profile.username.isEmpty && !profile.keyFilePath.isEmpty
            }
            return !profile.server.isEmpty && !profile.username.isEmpty && hasStoredPassword
        case .smb:
            return !profile.server.isEmpty && !profile.username.isEmpty && !profile.smbShare.isEmpty && hasStoredPassword
        case .s3:
            return !profile.bucket.isEmpty && !profile.accessKeyID.isEmpty && hasStoredS3SecretKey
        case .gdrive:
            return false
        }
    }

    private var configurationHint: String? {
        guard let profile = selectedProfile else {
            return "Create a profile to configure uploads."
        }
        switch profile.backend {
        case .ftp:
            return "Enter server, username, and password to test the connection."
        case .sftp:
            return profile.useKeyAuth
                ? "Enter server, username, and select an SSH key file to test."
                : "Enter server, username, and password to test the connection."
        case .smb:
            return "Enter server, share name, username, and password to test."
        case .s3:
            return "Enter bucket name, access key, and secret key to test."
        case .gdrive:
            return "Google Drive is not yet implemented."
        }
    }

    // MARK: - Bindings

    /// Generic writable-keypath binding into the currently selected profile.
    /// Writes through to the profile store on every mutation.
    private func binding<Value>(_ keyPath: WritableKeyPath<UploadProfile, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: {
                guard let index = selectedProfileIndex else { return defaultValue }
                return profiles[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = selectedProfileIndex else { return }
                profiles[index][keyPath: keyPath] = newValue
                UploadProfileStore.saveProfiles(profiles)
                // Credentials are keyed by (server, username) / access key — refresh when those change.
                if keyPath == \UploadProfile.server || keyPath == \UploadProfile.username || keyPath == \UploadProfile.accessKeyID {
                    refreshCredentialState()
                }
                UploadManager.shared.refreshConfiguredStatus()
            }
        )
    }

    private var backendBinding: Binding<UploadBackendType> {
        Binding(
            get: { selectedProfile?.backend ?? .ftp },
            set: { newBackend in
                guard let index = selectedProfileIndex,
                      profiles[index].backend != newBackend else { return }
                changeBackend(of: index, to: newBackend)
            }
        )
    }

    // MARK: - Actions

    private func loadInitialState() async {
        rcloneCustomPath = RcloneUpdateService.shared.getCustomPath() ?? ""
        await refreshRcloneStatus()

        if profiles.isEmpty {
            // First-run: create a default FTP profile so the view always has something to show.
            let profile = UploadProfile.new(backend: .ftp)
            profiles = [profile]
            UploadProfileStore.saveProfiles(profiles)
            selectedProfileID = profile.id.uuidString
        } else if selectedProfileIndex == nil {
            selectedProfileID = profiles[0].id.uuidString
        }

        refreshCredentialState()
    }

    private func addProfile(backend: UploadBackendType) {
        var profile = UploadProfile.new(backend: backend)
        profile.name = uniqueProfileName(from: profile.name)
        profiles.append(profile)
        UploadProfileStore.saveProfiles(profiles)
        selectedProfileID = profile.id.uuidString
        refreshCredentialState()
    }

    private func beginFileZillaImport() {
        let panel = NSOpenPanel()
        panel.title = "Select FileZilla Site Manager File"
        panel.message = "Choose your FileZilla sitemanager.xml or an exported sites file."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.xml]
        // FileZilla's config lives at ~/.config/filezilla/sitemanager.xml on macOS.
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        panel.directoryURL = homeURL.appendingPathComponent(".config/filezilla", isDirectory: true)
        panel.showsHiddenFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let sites = try FileZillaImporter.parse(url: url)
            if sites.isEmpty {
                fileZillaImportError = "No site entries were found in the selected file."
                return
            }
            fileZillaSites = sites
            isFileZillaSheetPresented = true
        } catch {
            fileZillaImportError = error.localizedDescription
        }
    }

    private func completeFileZillaImport(_ sitesToImport: [FileZillaSite]) {
        guard !sitesToImport.isEmpty else { return }

        var importedCount = 0
        var passwordsSavedCount = 0
        var firstImportedID: UUID?

        for site in sitesToImport {
            var profile = UploadProfile.from(fileZillaSite: site)
            profile.name = uniqueProfileName(from: profile.name)
            profiles.append(profile)
            importedCount += 1
            if firstImportedID == nil { firstImportedID = profile.id }

            // Save the password to the Keychain when we have one and the site is fully importable.
            if case .importable = site.status,
               let plain = site.plainPassword,
               !plain.isEmpty,
               !profile.server.isEmpty,
               !profile.username.isEmpty {
                do {
                    try KeychainCredentialManager.shared.saveCredential(
                        server: profile.server,
                        username: profile.username,
                        password: plain
                    )
                    passwordsSavedCount += 1
                } catch {
                    // Keychain failures are non-fatal; the user can re-enter the password manually.
                }
            }
        }

        UploadProfileStore.saveProfiles(profiles)
        if let id = firstImportedID {
            selectedProfileID = id.uuidString
        }
        refreshCredentialState()
        UploadManager.shared.refreshConfiguredStatus()

        let pieces = [
            "Imported \(importedCount) profile\(importedCount == 1 ? "" : "s").",
            passwordsSavedCount > 0 ? "Saved \(passwordsSavedCount) password\(passwordsSavedCount == 1 ? "" : "s") to the Keychain." : nil,
            (importedCount - passwordsSavedCount) > 0 ? "You'll need to enter passwords for the remaining \(importedCount - passwordsSavedCount) profile\(importedCount - passwordsSavedCount == 1 ? "" : "s")." : nil
        ].compactMap { $0 }
        fileZillaImportSummary = pieces.joined(separator: " ")
    }

    private func deleteSelectedProfile() {
        guard let index = selectedProfileIndex else { return }
        profiles.remove(at: index)
        UploadProfileStore.saveProfiles(profiles)
        if let next = profiles.first {
            selectedProfileID = next.id.uuidString
        } else {
            selectedProfileID = ""
        }
        refreshCredentialState()
    }

    /// Changes the backend of a profile, keeping shared fields (server/username/remotePath)
    /// and resetting the fields that belong to the previous backend.
    private func changeBackend(of index: Int, to newBackend: UploadBackendType) {
        profiles[index].backend = newBackend
        profiles[index].port = newBackend.defaultPort > 0 ? newBackend.defaultPort : AppConstants.defaultUploadPort
        profiles[index].useFTPS = false
        profiles[index].useKeyAuth = false
        profiles[index].keyFilePath = ""
        profiles[index].smbShare = ""
        profiles[index].smbDomain = ""
        profiles[index].bucket = ""
        profiles[index].region = "us-east-1"
        profiles[index].endpoint = ""
        profiles[index].accessKeyID = ""
        UploadProfileStore.saveProfiles(profiles)
        refreshCredentialState()
        testResult = nil
    }

    private func uniqueProfileName(from baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "Upload Profile" : trimmed
        let existing = Set(profiles.map { $0.name })
        if !existing.contains(seed) { return seed }
        var index = 2
        var candidate = "\(seed) \(index)"
        while existing.contains(candidate) {
            index += 1
            candidate = "\(seed) \(index)"
        }
        return candidate
    }

    /// Returns the next field to focus when the user presses Tab in the given field.
    /// The chain is backend-aware so we skip fields that aren't visible for the
    /// current profile (e.g. password is hidden for SFTP+key auth).
    private func nextField(after current: Field) -> Field? {
        let backend = selectedProfile?.backend ?? .ftp
        let useKeyAuth = selectedProfile?.useKeyAuth ?? false
        switch current {
        case .name:
            return backend == .s3 ? .s3Bucket : .server
        case .server:
            return .port
        case .port:
            return .username
        case .username:
            switch backend {
            case .ftp: return .password
            case .sftp: return useKeyAuth ? .sftpKeyFile : .password
            case .smb: return .smbShare
            case .s3, .gdrive: return nil
            }
        case .smbShare:
            return .smbDomain
        case .smbDomain:
            return .password
        case .sftpKeyFile:
            return .remotePath
        case .password:
            return .remotePath
        case .remotePath:
            return nil
        case .s3Bucket:
            return .s3Endpoint
        case .s3Endpoint:
            return .s3AccessKey
        case .s3AccessKey:
            return .s3SecretKey
        case .s3SecretKey:
            return .remotePath
        case .s3Region:
            return .s3Endpoint
        }
    }

    private func previousField(before current: Field) -> Field? {
        let backend = selectedProfile?.backend ?? .ftp
        let useKeyAuth = selectedProfile?.useKeyAuth ?? false
        switch current {
        case .name:
            return nil
        case .server:
            return .name
        case .port:
            return .server
        case .username:
            return .port
        case .smbShare:
            return .username
        case .smbDomain:
            return .smbShare
        case .sftpKeyFile:
            return .username
        case .password:
            switch backend {
            case .ftp: return .username
            case .sftp: return useKeyAuth ? .sftpKeyFile : .username
            case .smb: return .smbDomain
            case .s3, .gdrive: return nil
            }
        case .remotePath:
            switch backend {
            case .ftp: return .password
            case .sftp: return useKeyAuth ? .sftpKeyFile : .password
            case .smb: return .password
            case .s3: return .s3SecretKey
            case .gdrive: return nil
            }
        case .s3Bucket:
            return .name
        case .s3Endpoint:
            return .s3Bucket
        case .s3AccessKey:
            return .s3Endpoint
        case .s3SecretKey:
            return .s3AccessKey
        case .s3Region:
            return .s3Bucket
        }
    }

    /// Persists any password/secret-key that was typed but not yet committed,
    /// using the profile that was selected *before* the switch. Without this,
    /// switching profiles via the picker would discard unsaved credentials.
    private func commitPendingCredentials(forProfileID profileID: String) {
        guard let oldProfile = profiles.first(where: { $0.id.uuidString == profileID }) else { return }

        if !password.isEmpty,
           !oldProfile.server.isEmpty,
           !oldProfile.username.isEmpty {
            try? KeychainCredentialManager.shared.saveCredential(
                server: oldProfile.server,
                username: oldProfile.username,
                password: password
            )
        }

        if !s3SecretKey.isEmpty, !oldProfile.accessKeyID.isEmpty {
            try? KeychainCredentialManager.shared.saveS3SecretKey(
                accessKeyID: oldProfile.accessKeyID,
                secretKey: s3SecretKey
            )
        }
    }

    private func refreshCredentialState() {
        password = ""
        s3SecretKey = ""

        guard let profile = selectedProfile else {
            hasStoredPassword = false
            hasStoredS3SecretKey = false
            return
        }

        switch profile.backend {
        case .ftp, .sftp, .smb:
            if !profile.server.isEmpty, !profile.username.isEmpty {
                hasStoredPassword = KeychainCredentialManager.shared.hasCredential(
                    server: profile.server,
                    username: profile.username
                )
            } else {
                hasStoredPassword = false
            }
            hasStoredS3SecretKey = false
        case .s3:
            hasStoredPassword = false
            hasStoredS3SecretKey = !profile.accessKeyID.isEmpty
                && KeychainCredentialManager.shared.hasS3SecretKey(accessKeyID: profile.accessKeyID)
        case .gdrive:
            hasStoredPassword = false
            hasStoredS3SecretKey = false
        }
    }

    private func refreshRcloneStatus() async {
        let status = RcloneUpdateService.shared.getInstallationStatus()
        let version = await RcloneUpdateService.shared.getCurrentVersion()
        await MainActor.run {
            rcloneStatus = status
            rcloneVersion = version
        }
    }

    private func saveRclonePath() {
        let trimmed = rcloneCustomPath.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if trimmed.isEmpty {
                await RcloneUpdateService.shared.clearCustomPath()
            } else {
                await RcloneUpdateService.shared.saveCustomPath(trimmed)
            }
            await refreshRcloneStatus()
        }
    }

    private func selectRcloneBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Select rclone Binary"
        panel.message = "Choose the rclone executable you want this app to use."
        panel.prompt = "Select"
        panel.allowedContentTypes = [.unixExecutable, .exe, .item]
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = false
        panel.resolvesAliases = false

        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        }

        if panel.runModal() == .OK, let url = panel.url {
            rcloneCustomPath = url.path
        }
    }

    private func savePassword() {
        guard let profile = selectedProfile,
              !profile.server.isEmpty,
              !profile.username.isEmpty,
              !password.isEmpty else { return }

        do {
            try KeychainCredentialManager.shared.saveCredential(
                server: profile.server,
                username: profile.username,
                password: password
            )
            hasStoredPassword = true
            password = ""
        } catch {
            // Surfaced to the user implicitly by hasStoredPassword staying false.
        }
    }

    private func saveS3SecretKey() {
        guard let profile = selectedProfile,
              !profile.accessKeyID.isEmpty,
              !s3SecretKey.isEmpty else { return }

        do {
            try KeychainCredentialManager.shared.saveS3SecretKey(
                accessKeyID: profile.accessKeyID,
                secretKey: s3SecretKey
            )
            hasStoredS3SecretKey = true
            s3SecretKey = ""
        } catch {
            // Surfaced to the user implicitly.
        }
    }

    private func selectSSHKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            guard let index = selectedProfileIndex else { return }
            profiles[index].keyFilePath = url.path
            UploadProfileStore.saveProfiles(profiles)
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil

        do {
            let success = try await UploadManager.shared.testConnection()
            testResult = success ? .success : .failure("Connection test failed")
        } catch {
            testResult = .failure(error.localizedDescription)
        }

        isTesting = false
    }
}

#Preview {
    UploadSettingsView()
        .frame(width: 600, height: 700)
}
