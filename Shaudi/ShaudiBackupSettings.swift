import Foundation
import SwiftData
import SwiftUI
import UIKit

enum ShaudiBackupSettingsError: LocalizedError, Equatable {
    case wrongFileType
    case inaccessibleFile
    case noPreview
    case noExportSelection
    case noExportableSongs(Int)

    var errorDescription: String? {
        switch self {
        case .wrongFileType: "Choose a CSV backup file."
        case .inaccessibleFile: "This file could not be opened. Try saving it to Files and selecting it again."
        case .noPreview: "Choose a backup file before importing."
        case .noExportSelection: "Select at least one playlist to export."
        case .noExportableSongs(let count): "No songs could be backed up. \(count) songs have missing or invalid YouTube IDs."
        }
    }
}

enum ShaudiBackupExportMode {
    case one, multiple, full

    static func selection(
        for mode: Self,
        playlists: [Playlist],
        selectedIDs: Set<ObjectIdentifier>
    ) -> ShaudiBackupSelection? {
        switch mode {
        case .one:
            guard let playlist = playlists.first(where: { selectedIDs.contains(ObjectIdentifier($0)) }) else { return nil }
            return .playlist(playlist)
        case .multiple:
            let selected = playlists.filter { selectedIDs.contains(ObjectIdentifier($0)) }
            return selected.isEmpty ? nil : .playlists(selected)
        case .full:
            return .fullBackup
        }
    }
}

enum ShaudiBackupTemporaryFile {
    static func write(_ result: ShaudiBackupExportResult, in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = root.appendingPathComponent("ShaudiBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let url = folder.appendingPathComponent(result.suggestedFilename, isDirectory: false)
            try result.csvData.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@MainActor @Observable
final class ShaudiBackupCoordinator {
    private(set) var preview: ShaudiBackupImportPreview?
    private(set) var result: ShaudiBackupImportResult?
    private(set) var isApplying = false
    var errorMessage: String?

    func prepareImport(from url: URL) throws {
        guard ["csv", "txt"].contains(url.pathExtension.lowercased()) else {
            throw ShaudiBackupSettingsError.wrongFileType
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ShaudiBackupSettingsError.inaccessibleFile
        }
        try prepareImport(data: data)
    }

    func prepareImport(data: Data) throws {
        preview = nil
        result = nil
        preview = try ShaudiBackupImporter.preview(data: data)
    }

    func cancelImport() {
        guard !isApplying else { return }
        preview = nil
        result = nil
        errorMessage = nil
    }

    func beginImport() -> Bool {
        guard !isApplying, preview != nil else { return false }
        isApplying = true
        return true
    }

    @discardableResult
    func confirmImport(in context: ModelContext) throws -> Bool {
        guard isApplying else { return false }
        guard let preview else { throw ShaudiBackupSettingsError.noPreview }
        defer { isApplying = false }
        result = try ShaudiBackupImporter.apply(preview, in: context)
        return true
    }
}

private struct ShaudiBackupShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShaudiBackupExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.dateCreated, order: .reverse) private var playlists: [Playlist]
    @Query(sort: \Track.dateAdded, order: .reverse) private var libraryTracks: [Track]

    @State private var mode: ShaudiBackupExportMode?
    @State private var selectedIDs = Set<ObjectIdentifier>()
    @State private var exportResult: ShaudiBackupExportResult?
    @State private var exportURL: URL?
    @State private var isShowingShare = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let exportResult, exportResult.skippedTrackCount > 0 {
                    warningContent(exportResult)
                } else if let mode, mode != .full {
                    playlistContent(multiple: mode == .multiple)
                } else {
                    choiceContent
                }
            }
            .navigationTitle(exportResult == nil ? "Export Backup" : "Backup Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if mode == .multiple && exportResult == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Export") { exportSelected() }
                            .disabled(selectedIDs.isEmpty)
                    }
                }
            }
        }
        .tint(ShaudiTheme.accent)
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $isShowingShare, onDismiss: {
            ShaudiBackupTemporaryFile.remove(exportURL)
            exportURL = nil
            dismiss()
        }) {
            if let exportURL { ShaudiBackupShareSheet(url: exportURL) }
        }
        .alert("Unable to Export", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            if !isShowingShare { ShaudiBackupTemporaryFile.remove(exportURL) }
        }
    }

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            choiceButton("One Playlist", icon: "music.note.list") { mode = .one }
            choiceButton("Multiple Playlists", icon: "checklist") { mode = .multiple }
            choiceButton("Full Shaudi Backup", icon: "square.stack") {
                mode = .full
                exportSelected()
            }
            Spacer()
        }
        .padding(20)
        .background(ShaudiTheme.dashboardBackground)
    }

    private func choiceButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .body))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(ShaudiTheme.dashboardCard, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func playlistContent(multiple: Bool) -> some View {
        List {
            if playlists.isEmpty {
                Text("No playlists yet.")
                    .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
            }
            ForEach(playlists) { playlist in
                Button {
                    let id = ObjectIdentifier(playlist)
                    if multiple {
                        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
                    } else {
                        selectedIDs = [id]
                        exportSelected()
                    }
                } label: {
                    HStack {
                        Text(playlist.name)
                        Spacer()
                        if multiple {
                            Image(systemName: selectedIDs.contains(ObjectIdentifier(playlist)) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(ShaudiTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .listRowBackground(ShaudiTheme.dashboardCard)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ShaudiTheme.dashboardBackground)
    }

    private func warningContent(_ result: ShaudiBackupExportResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(result.exportedSongCount) songs exported")
            Text("\(result.skippedTrackCount) songs could not be backed up")
            ForEach(Array(result.skippedTracks.prefix(5).enumerated()), id: \.offset) { _, track in
                Text("\(track.title): \(track.reason)")
                    .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .caption))
                    .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
            }
            Button("Continue & Share") { share(result) }
                .buttonStyle(.borderedProminent)
            Button("Cancel") { dismiss() }
            Spacer()
        }
        .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .body))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(ShaudiTheme.dashboardBackground)
    }

    private func exportSelected() {
        guard let mode,
              let selection = ShaudiBackupExportMode.selection(for: mode, playlists: playlists, selectedIDs: selectedIDs)
        else { errorMessage = ShaudiBackupSettingsError.noExportSelection.localizedDescription; return }
        do {
            let result = try ShaudiBackupExporter.export(selection, allPlaylists: playlists, libraryTracks: libraryTracks)
            exportResult = result
            if result.skippedTrackCount == 0 { share(result) }
        } catch ShaudiBackupExportError.noValidRows(let skipped) {
            errorMessage = ShaudiBackupSettingsError.noExportableSongs(skipped.count).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func share(_ result: ShaudiBackupExportResult) {
        do {
            exportURL = try ShaudiBackupTemporaryFile.write(result)
            isShowingShare = true
        } catch {
            errorMessage = "The backup file could not be created. \(error.localizedDescription)"
        }
    }
}

struct ShaudiBackupImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let backup: ShaudiBackupCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = backup.result {
                        resultContent(result)
                    } else if let preview = backup.preview {
                        previewContent(preview)
                    }
                }
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(ShaudiTheme.dashboardBackground)
            .navigationTitle(backup.result == nil ? "Restore Shaudi Backup" : "Import Complete")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(backup.isApplying)
        }
        .tint(ShaudiTheme.accent)
        .presentationDetents([.medium, .large])
        .alert("Import Failed", isPresented: Binding(
            get: { backup.errorMessage != nil },
            set: { if !$0 { backup.errorMessage = nil } }
        )) {
            Button("OK") { backup.errorMessage = nil }
        } message: {
            Text(backup.errorMessage ?? "")
        }
    }

    private func previewContent(_ preview: ShaudiBackupImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(preview.playlistNames.count) playlists")
            Text("\(preview.uniqueTrackVideoIDs.count) songs")
            Text("Your existing library will not be deleted. Imported data will be merged with your current library.")
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
            if preview.invalidRowCount > 0 {
                Text("\(preview.invalidRowCount) invalid rows will be skipped")
                ForEach(Array(preview.warnings.prefix(5).enumerated()), id: \.offset) { _, warning in
                    Text("Row \(warning.rowNumber): \(warning.reason)")
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .caption))
                        .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                }
            }
            HStack {
                Button("Cancel") {
                    backup.cancelImport()
                    dismiss()
                }
                .disabled(backup.isApplying)
                Spacer()
                Button {
                    guard backup.beginImport() else { return }
                    Task { @MainActor in
                        await Task.yield()
                        do { try backup.confirmImport(in: modelContext) }
                        catch { backup.errorMessage = error.localizedDescription }
                    }
                } label: {
                    if backup.isApplying { ProgressView() } else { Text("Import") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(backup.isApplying)
            }
        }
    }

    private func resultContent(_ result: ShaudiBackupImportResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(result.importedTrackCount) tracks added")
            Text("\(result.reusedTrackCount) existing tracks reused")
            Text("\(result.createdPlaylistCount) playlists created")
            Text("\(result.reusedPlaylistCount) playlists reused")
            Text("\(result.addedMembershipCount) playlist memberships added")
            Text("\(result.skippedDuplicateMembershipCount) duplicates skipped")
            if result.skippedInvalidRowCount > 0 {
                Text("\(result.skippedInvalidRowCount) invalid rows skipped")
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
    }
}
