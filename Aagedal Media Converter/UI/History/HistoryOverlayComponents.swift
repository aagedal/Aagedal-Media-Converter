//
//  HistoryOverlayComponents.swift
//  Aagedal Media Converter
//
//  Shared pieces for the encode history and last-session overlays.
//

import AppKit
import SwiftUI

/// Dimmed full-window overlay with a material panel, matching URLInputOverlay.
struct HistoryOverlayPanel<Content: View, Footer: View>: View {
    @Binding var isPresented: Bool
    let title: LocalizedStringKey
    let systemImage: String
    var width: CGFloat = 640
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 14) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close")
                }
                content
                footer
            }
            .padding(20)
            .frame(width: width)
            // Hug the content; scrollable sections cap their own height.
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .padding(40)
        }
    }
}

/// Small buttons in the queue's lower-left corner.
struct HistoryCornerButtons: View {
    let showHistoryButton: Bool
    let lastSessionCount: Int
    let onShowHistory: () -> Void
    let onShowLastSession: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if showHistoryButton {
                Button(action: onShowHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(CornerButtonStyle())
                .help("Encode History")
                .accessibilityIdentifier("encodeHistoryButton")
            }
            if lastSessionCount > 0 {
                Button(action: onShowLastSession) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                        Text("Last session · \(lastSessionCount)")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                }
                .buttonStyle(CornerButtonStyle())
                .help("Restore unfinished items from the last session")
                .accessibilityIdentifier("lastSessionButton")
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lastSessionCount)
    }

    private struct CornerButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

struct EncodeOutcomeIcon: View {
    let outcome: EncodeOutcome

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .help(label)
    }

    var symbol: String {
        switch outcome {
        case .running: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch outcome {
        case .running: return .secondary
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .interrupted: return .orange
        }
    }

    var label: String {
        switch outcome {
        case .running: return String(localized: "Running", comment: "Encode history outcome.")
        case .completed: return String(localized: "Completed", comment: "Encode history outcome.")
        case .failed: return String(localized: "Failed", comment: "Encode history outcome.")
        case .cancelled: return String(localized: "Cancelled", comment: "Encode history outcome.")
        case .interrupted: return String(localized: "Interrupted", comment: "Encode history outcome: the app quit or crashed during the encode.")
        }
    }
}

/// Finds moved source files.
@MainActor
enum HistoryRelinker {
    /// Asks the user to locate a missing file.
    static func chooseReplacement(for missingPath: String) -> URL? {
        let missing = URL(fileURLWithPath: missingPath)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate “\(missing.lastPathComponent)”", comment: "Open panel title for finding a moved source file.")
        panel.message = String(localized: "The file was moved or deleted. Choose its new location.")
        panel.prompt = String(localized: "Relink", comment: "Open panel button that points history at a moved file.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let parent = missing.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { panel.directoryURL = parent }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// For other missing files that lived in the same folder as the relinked
    /// one, returns matches with the same name in the new folder.
    static func siblingMatches(
        missingPaths: [String],
        relinkedFrom oldPath: String,
        to newURL: URL
    ) -> [String: URL] {
        let oldFolder = URL(fileURLWithPath: oldPath).deletingLastPathComponent().path
        let newFolder = newURL.deletingLastPathComponent()
        var matches: [String: URL] = [:]
        for path in missingPaths where path != oldPath {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().path == oldFolder else { continue }
            let candidate = newFolder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) { matches[path] = candidate }
        }
        return matches
    }
}

extension Date {
    /// "Today 14:02", "Yesterday 09:15", "Mon 12 Oct 18:40".
    var historySessionLabel: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return String(localized: "Today \(time)", comment: "History session label; the argument is a time.") }
        if calendar.isDateInYesterday(self) { return String(localized: "Yesterday \(time)", comment: "History session label; the argument is a time.") }
        let sameYear = calendar.component(.year, from: self) == calendar.component(.year, from: Date())
        let day = sameYear
            ? formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            : formatted(.dateTime.day().month(.abbreviated).year())
        return "\(day) \(time)"
    }
}
