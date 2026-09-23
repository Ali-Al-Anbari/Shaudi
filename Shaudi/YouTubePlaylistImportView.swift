//
//  YouTubePlaylistImportView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct YouTubePlaylistImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var existingPlaylists: [Playlist]

    private enum Step {
        case input
        case fetching
        case preview
        case destination
        case saving
        case result
    }

    private enum DestinationSelection: Hashable {
        case libraryOnly
        case newPlaylist
        case existingPlaylist(PersistentIdentifier)
    }

    // Input state
    @State private var urlText = ""
    @State private var step: Step = .input
    @State private var errorMessage: String?

    // Fetch state
    @State private var fetchTask: Task<Void, Never>?
    @State private var fetchedItemsLoadedCount = 0

    // Extracted data
    @State private var extractedPlaylist: ExtractedYouTubePlaylist?
    @State private var pendingItems: [PendingYouTubePlaylistItem] = []

    // Destination state
    @State private var destinationSelection: DestinationSelection = .libraryOnly
    @State private var newPlaylistName = ""

    // Result state
    @State private var importSummary: YouTubePlaylistImportSummary?

    private let extractionClient = YouTubePlaylistExtractionClient()

    var body: some View {
        NavigationStack {
            ZStack {
                ShaudiTheme.canvas
                    .ignoresSafeArea()

                Group {
                    switch step {
                    case .input:
                        inputView
                    case .fetching:
                        fetchingView
                    case .preview:
                        previewView
                    case .destination:
                        destinationView
                    case .saving:
                        savingView
                    case .result:
                        resultView
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .tint(ShaudiTheme.accent)
            .toolbar {
                toolbarContent
            }
            .alert(
                "Import Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var navigationTitle: String {
        switch step {
        case .input, .fetching:
            return "Import YouTube Playlist"
        case .preview:
            return "Review Songs"
        case .destination:
            return "Choose Destination"
        case .saving:
            return "Importing…"
        case .result:
            return "Import Complete"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        switch step {
        case .input:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
        case .fetching:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    fetchTask?.cancel()
                    step = .input
                }
            }
        case .preview:
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    step = .input
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next") {
                    step = .destination
                }
                .fontWeight(.semibold)
                .disabled(pendingItems.isEmpty)
            }
        case .destination:
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    step = .preview
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    executeImport()
                }
                .fontWeight(.semibold)
                .disabled(!canProceedWithImport)
            }
        case .saving:
            ToolbarItem(placement: .cancellationAction) {
                EmptyView()
            }
        case .result:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Input View
    private var inputView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste Playlist URL")
                        .font(ShaudiTheme.bodyFont(size: 20, relativeTo: .title3).weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Import songs from a public or unlisted YouTube playlist. No API quota is consumed.")
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(ShaudiTheme.accent)

                        TextField("https://www.youtube.com/playlist?list=...", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit {
                                if canStartFetch {
                                    startFetch()
                                }
                            }

                        if !urlText.isEmpty {
                            Button {
                                urlText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .background(ShaudiTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 12) {
                        if let clipboardString = UIPasteboard.general.string, !clipboardString.isEmpty {
                            Button {
                                urlText = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                            } label: {
                                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                                    .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                            }
                            .buttonStyle(.bordered)
                            .tint(ShaudiTheme.accent)
                        }

                        Spacer()

                        Button {
                            startFetch()
                        } label: {
                            Label("Fetch Playlist", systemImage: "arrow.down.circle.fill")
                                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .headline).weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ShaudiTheme.accent)
                        .disabled(!canStartFetch)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Supported URLs:")
                        .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).weight(.medium))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        urlExample("youtube.com/playlist?list=...")
                        urlExample("music.youtube.com/playlist?list=...")
                        urlExample("youtube.com/watch?v=...&list=...")
                        urlExample("youtu.be/... ?list=...")
                    }
                }
                .padding(14)
                .background(ShaudiTheme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Spacer()
            }
            .padding(18)
        }
    }

    private func urlExample(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ShaudiTheme.accent)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canStartFetch: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Fetching View
    private var fetchingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .scaleEffect(1.3)

            VStack(spacing: 6) {
                Text("Loading Playlist…")
                    .font(ShaudiTheme.bodyFont(size: 18, relativeTo: .headline).weight(.semibold))

                if fetchedItemsLoadedCount > 0 {
                    Text("\(fetchedItemsLoadedCount) songs found so far")
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connecting to YouTube…")
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                }
            }

            Button("Cancel") {
                fetchTask?.cancel()
                step = .input
            }
            .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
            .tint(.secondary)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Preview View
    private var previewView: some View {
        VStack(spacing: 0) {
            // Header summary
            VStack(alignment: .leading, spacing: 8) {
                if let title = extractedPlaylist?.title, !title.isEmpty {
                    Text(title)
                        .font(ShaudiTheme.scriptFont(size: 26, relativeTo: .title2))
                        .foregroundStyle(ShaudiTheme.accent)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    let totalFound = extractedPlaylist?.items.count ?? 0
                    Text("\(totalFound) found")
                        .fontWeight(.semibold)

                    Text("•")

                    Text("\(pendingItems.count) selected")
                        .foregroundStyle(pendingItems.isEmpty ? .red : ShaudiTheme.accent)
                        .fontWeight(.semibold)

                    if let unavailable = extractedPlaylist?.unavailableSkippedCount, unavailable > 0 {
                        Text("•")
                        Text("\(unavailable) unavailable")
                            .foregroundStyle(.secondary)
                    }

                    if let duplicates = extractedPlaylist?.duplicateSkippedCount, duplicates > 0 {
                        Text("•")
                        Text("\(duplicates) duplicates")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption))
                .lineLimit(1)

                // Bulk controls
                HStack(spacing: 12) {
                    Button {
                        if let all = extractedPlaylist?.items {
                            pendingItems = all
                        }
                    } label: {
                        Label("Keep All", systemImage: "checkmark.circle")
                            .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(ShaudiTheme.accent)

                    Button {
                        pendingItems.removeAll()
                    } label: {
                        Label("Remove All", systemImage: "xmark.circle")
                            .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ShaudiTheme.card)

            Divider()

            if pendingItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    Text("All songs have been removed.")
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))

                    Text("At least one song must remain selected to import.")
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)

                    Button("Restore All Songs") {
                        if let all = extractedPlaylist?.items {
                            pendingItems = all
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaudiTheme.accent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(pendingItems) { item in
                        songPreviewRow(item)
                            .listRowBackground(ShaudiTheme.card)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    removeSong(item)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: deleteSongs(at:))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            // Bottom bar
            VStack(spacing: 8) {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pendingItems.count) of \(extractedPlaylist?.items.count ?? 0) songs selected")
                            .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption))
                            .foregroundStyle(.secondary)

                        if let removedCount = removedSongCount, removedCount > 0 {
                            Text("\(removedCount) removed from import")
                                .font(ShaudiTheme.bodyFont(size: 12, relativeTo: .caption2))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        step = .destination
                    } label: {
                        HStack(spacing: 6) {
                            Text("Next")
                            Image(systemName: "arrow.right")
                        }
                        .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .headline).weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaudiTheme.accent)
                    .disabled(pendingItems.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(ShaudiTheme.card)
        }
    }

    private func songPreviewRow(_ item: PendingYouTubePlaylistItem) -> some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let thumbURL = item.thumbnailURL {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        Color.secondary.opacity(0.2)
                    default:
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ShaudiTheme.accent.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(ShaudiTheme.accent)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .body).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let artist = item.artist, !artist.isEmpty {
                    Text(artist)
                        .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                removeSong(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.title)")
        }
        .padding(.vertical, 2)
    }

    private func removeSong(_ item: PendingYouTubePlaylistItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            pendingItems.removeAll { $0.videoID == item.videoID }
        }
    }

    private func deleteSongs(at offsets: IndexSet) {
        withAnimation(.easeInOut(duration: 0.2)) {
            pendingItems.remove(atOffsets: offsets)
        }
    }

    private var removedSongCount: Int? {
        guard let originalTotal = extractedPlaylist?.items.count else { return nil }
        return max(0, originalTotal - pendingItems.count)
    }

    // MARK: - Destination View
    private var destinationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select Destination")
                        .font(ShaudiTheme.bodyFont(size: 20, relativeTo: .title3).weight(.semibold))

                    Text("\(pendingItems.count) songs will be imported into Shaudi.")
                        .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                VStack(spacing: 12) {
                    // Option 1: Library Only
                    destinationOptionCard(
                        title: "Add to Library",
                        subtitle: "Add songs to your global Library only.",
                        icon: "music.note.house",
                        isSelected: destinationSelection == .libraryOnly
                    ) {
                        destinationSelection = .libraryOnly
                    }

                    // Option 2: Create New Playlist
                    destinationOptionCard(
                        title: "Create New Playlist",
                        subtitle: "Create a playlist and add songs to it.",
                        icon: "plus.circle",
                        isSelected: isNewPlaylistSelected
                    ) {
                        destinationSelection = .newPlaylist
                    }

                    if isNewPlaylistSelected {
                        VStack(alignment: .leading, spacing: 8) {
                            if let ytTitle = extractedPlaylist?.title, !ytTitle.isEmpty {
                                Text("YouTube Title: \(ytTitle)")
                                    .font(ShaudiTheme.bodyFont(size: 12, relativeTo: .caption))
                                    .foregroundStyle(.secondary)
                            }

                            TextField("New Playlist Name", text: $newPlaylistName)
                                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .body))
                                .padding(12)
                                .background(ShaudiTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(ShaudiTheme.accent.opacity(0.5), lineWidth: 1)
                                }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, -4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Option 3: Add to Existing Playlist
                    if !existingPlaylists.isEmpty {
                        destinationOptionCard(
                            title: "Add to Existing Playlist",
                            subtitle: "Add songs to an existing Shaudi playlist.",
                            icon: "music.note.list",
                            isSelected: isExistingPlaylistSelected
                        ) {
                            if case .existingPlaylist = destinationSelection {
                                // already selected
                            } else if let first = existingPlaylists.first {
                                destinationSelection = .existingPlaylist(first.persistentModelID)
                            }
                        }

                        if isExistingPlaylistSelected {
                            VStack(spacing: 6) {
                                ForEach(existingPlaylists) { playlist in
                                    let isThisPlaylist = isPlaylistActive(playlist)
                                    Button {
                                        destinationSelection = .existingPlaylist(playlist.persistentModelID)
                                    } label: {
                                        HStack {
                                            PlaylistArtworkView(playlist: playlist)
                                                .frame(width: 32, height: 32)
                                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                            Text(playlist.name)
                                                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .body))
                                                .foregroundStyle(.primary)

                                            Spacer()

                                            Image(systemName: isThisPlaylist ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(isThisPlaylist ? ShaudiTheme.accent : .secondary)
                                        }
                                        .padding(10)
                                        .background(
                                            isThisPlaylist ? ShaudiTheme.accent.opacity(0.12) : ShaudiTheme.card,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, -4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                Spacer()

                Button {
                    executeImport()
                } label: {
                    Text("Confirm & Import (\(pendingItems.count))")
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(ShaudiTheme.accent)
                .disabled(!canProceedWithImport)
            }
            .padding(18)
        }
    }

    private func destinationOptionCard(
        title: String,
        subtitle: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? ShaudiTheme.accent : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body).weight(.medium))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? ShaudiTheme.accent : .secondary)
            }
            .padding(14)
            .background(
                isSelected ? ShaudiTheme.accent.opacity(0.12) : ShaudiTheme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? ShaudiTheme.accent.opacity(0.4) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var isNewPlaylistSelected: Bool {
        if case .newPlaylist = destinationSelection { return true }
        return false
    }

    private var isExistingPlaylistSelected: Bool {
        if case .existingPlaylist = destinationSelection { return true }
        return false
    }

    private func isPlaylistActive(_ playlist: Playlist) -> Bool {
        if case .existingPlaylist(let id) = destinationSelection {
            return id == playlist.persistentModelID
        }
        return false
    }

    private var canProceedWithImport: Bool {
        guard !pendingItems.isEmpty else { return false }
        switch destinationSelection {
        case .libraryOnly:
            return true
        case .newPlaylist:
            return !newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .existingPlaylist:
            return true
        }
    }

    // MARK: - Saving View
    private var savingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Saving songs to Shaudi…")
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Result View
    private var resultView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(ShaudiTheme.accent)

                    Text("Import Complete")
                        .font(ShaudiTheme.scriptFont(size: 32, relativeTo: .title))
                        .foregroundStyle(ShaudiTheme.accent)
                }
                .padding(.top, 24)

                if let summary = importSummary {
                    VStack(alignment: .leading, spacing: 14) {
                        resultStatRow(
                            label: "Songs selected",
                            value: "\(summary.selectedSongCount)",
                            icon: "music.note"
                        )
                        resultStatRow(
                            label: "New songs added to Library",
                            value: "\(summary.newSongsAddedCount)",
                            icon: "plus"
                        )
                        resultStatRow(
                            label: "Existing songs reused",
                            value: "\(summary.existingSongsReusedCount)",
                            icon: "arrow.triangle.2.circlepath"
                        )

                        if !summary.isLibraryOnly {
                            resultStatRow(
                                label: "Playlist memberships added",
                                value: "\(summary.playlistMembershipsAddedCount)",
                                icon: "text.badge.plus"
                            )
                            if summary.duplicateMembershipsSkippedCount > 0 {
                                resultStatRow(
                                    label: "Duplicate memberships skipped",
                                    value: "\(summary.duplicateMembershipsSkippedCount)",
                                    icon: "arrow.uturn.backward"
                                )
                            }
                        }

                        if summary.unavailableVideosSkippedCount > 0 {
                            resultStatRow(
                                label: "Unavailable videos skipped",
                                value: "\(summary.unavailableVideosSkippedCount)",
                                icon: "eye.slash"
                            )
                        }

                        if summary.removedBeforeImportCount > 0 {
                            resultStatRow(
                                label: "Songs removed before import",
                                value: "\(summary.removedBeforeImportCount)",
                                icon: "trash"
                            )
                        }

                        Divider()
                            .padding(.vertical, 4)

                        HStack {
                            Text("Destination:")
                                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(summary.destinationTitle)
                                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .subheadline).weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(18)
                    .background(ShaudiTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(ShaudiTheme.accent)
                .padding(.top, 8)

                Spacer()
            }
            .padding(20)
        }
    }

    private func resultStatRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: 20)

            Text(label)
                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .body))
                .foregroundStyle(.primary)

            Spacer()

            Text(value)
                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .body).weight(.semibold))
                .foregroundStyle(ShaudiTheme.accent)
        }
    }

    // MARK: - Actions
    private func startFetch() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        step = .fetching
        fetchedItemsLoadedCount = 0
        errorMessage = nil

        fetchTask = Task { @MainActor in
            do {
                let playlist = try await extractionClient.fetchPlaylist(from: trimmed) { count in
                    Task { @MainActor in
                        self.fetchedItemsLoadedCount = count
                    }
                }
                guard !Task.isCancelled else { return }
                self.extractedPlaylist = playlist
                self.pendingItems = playlist.items
                self.step = .preview
            } catch is CancellationError {
                // Cancelled by user
                self.step = .input
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.step = .input
            }
        }
    }

    private func executeImport() {
        guard !pendingItems.isEmpty else { return }

        let originalTotal = extractedPlaylist?.items.count ?? pendingItems.count
        let unavailable = extractedPlaylist?.unavailableSkippedCount ?? 0

        let destination: YouTubePlaylistDestination
        switch destinationSelection {
        case .libraryOnly:
            destination = .libraryOnly
        case .newPlaylist:
            let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
            destination = .newPlaylist(name: name)
        case .existingPlaylist(let id):
            destination = .existingPlaylist(id)
        }

        step = .saving

        Task { @MainActor in
            do {
                let summary = try YouTubePlaylistImporter.apply(
                    items: pendingItems,
                    originalFetchedCount: originalTotal,
                    unavailableSkippedCount: unavailable,
                    destination: destination,
                    in: modelContext
                )
                self.importSummary = summary
                self.step = .result
            } catch {
                self.errorMessage = error.localizedDescription
                self.step = .destination
            }
        }
    }
}
