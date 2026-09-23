//
//  SearchView.swift
//  Shaudi
//

import Combine
import SwiftData
import SwiftUI

@MainActor
private final class SearchViewModel: ObservableObject {
    private struct CachedSearch {
        let results: [YouTubeSearchResult]
        let nextPageToken: String?
        let searchedDeeper: Bool
    }

    @Published var query = ""
    @Published private(set) var results: [YouTubeSearchResult] = []
    @Published private(set) var visibleCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingDeeper = false
    @Published private(set) var errorMessage: String?

    private let metadataClient = YouTubeMetadataClient()
    private let maximumCachedQueries = 20
    private var cache: [String: CachedSearch] = [:]
    private var cacheOrder: [String] = []
    private var metadataCache: [String: YouTubeMetadata] = [:]
    private var normalizedQuery = ""
    private var requestQuery = ""
    private var nextPageToken: String?
    private var searchedDeeper = false
    private var activeRequestID = UUID()
    private var searchTask: Task<Void, Never>?

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isQueryTooShort: Bool {
        !trimmedQuery.isEmpty && trimmedQuery.count < 3
    }

    var canShowMore: Bool {
        visibleCount < results.count
    }

    var canSearchDeeper: Bool {
        !results.isEmpty
            && visibleCount >= results.count
            && nextPageToken != nil
            && !searchedDeeper
            && !isLoadingDeeper
    }

    var visibleResults: ArraySlice<YouTubeSearchResult> {
        results.prefix(visibleCount)
    }

    func queryDidChange() {
        let newNormalizedQuery = Self.normalize(query)
        guard newNormalizedQuery != normalizedQuery else {
            return
        }

        normalizedQuery = newNormalizedQuery
        requestQuery = trimmedQuery
        activeRequestID = UUID()
        searchTask?.cancel()
        searchTask = nil
        results = []
        visibleCount = 0
        nextPageToken = nil
        searchedDeeper = false
        errorMessage = nil
        isLoading = false
        isLoadingDeeper = false

        guard !newNormalizedQuery.isEmpty, trimmedQuery.count >= 3 else {
            return
        }

        if let cachedSearch = cache[newNormalizedQuery] {
            searchLog("Query cache hit: \(newNormalizedQuery)")
            apply(cachedSearch)
            return
        }

        let requestID = activeRequestID
        let requestQuery = self.requestQuery
        isLoading = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else {
                    return
                }

                await self.performSearch(
                    requestQuery: requestQuery,
                    normalizedQuery: newNormalizedQuery,
                    requestID: requestID
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func showMore() {
        visibleCount = min(visibleCount + 5, results.count)
    }

    func searchDeeper() {
        guard let pageToken = nextPageToken, canSearchDeeper else {
            return
        }

        let requestID = activeRequestID
        let normalizedQuery = self.normalizedQuery
        let requestQuery = self.requestQuery
        isLoadingDeeper = true
        errorMessage = nil
        searchLog("Loading next search page")

        searchTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let page = try await metadataClient.search(
                    query: requestQuery,
                    pageToken: pageToken
                )
                guard isCurrent(requestID: requestID, normalizedQuery: normalizedQuery) else {
                    searchLog("Stale query response discarded")
                    return
                }

                let existingVideoIDs = Set(results.map(\.youtubeVideoID))
                let uniqueResults = page.results.filter {
                    !existingVideoIDs.contains($0.youtubeVideoID)
                }
                results.append(contentsOf: uniqueResults)
                searchedDeeper = true
                nextPageToken = nil
                isLoadingDeeper = false
                searchTask = nil
                cacheSearch(for: normalizedQuery)
                searchLog("Query completed with \(results.count) results")
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(requestID: requestID, normalizedQuery: normalizedQuery) else {
                    searchLog("Stale query response discarded")
                    return
                }

                searchedDeeper = true
                nextPageToken = nil
                isLoadingDeeper = false
                searchTask = nil
                errorMessage = error.localizedDescription
                cacheSearch(for: normalizedQuery)
            }
        }
    }

    func detailedMetadata(for result: YouTubeSearchResult) async throws -> YouTubeMetadata {
        if let metadata = metadataCache[result.youtubeVideoID] {
            return metadata
        }

        searchLog("Metadata fetch started for \(result.youtubeVideoID)")
        let metadata = try await metadataClient.metadata(for: result.youtubeVideoID)
        metadataCache[result.youtubeVideoID] = metadata
        return metadata
    }

    private func performSearch(
        requestQuery: String,
        normalizedQuery: String,
        requestID: UUID
    ) async {
        searchLog("Query started: \(normalizedQuery)")

        do {
            let page = try await metadataClient.search(query: requestQuery)
            guard isCurrent(requestID: requestID, normalizedQuery: normalizedQuery) else {
                searchLog("Stale query response discarded")
                return
            }

            results = page.results
            visibleCount = min(5, results.count)
            nextPageToken = page.nextPageToken
            searchedDeeper = false
            isLoading = false
            searchTask = nil
            cacheSearch(for: normalizedQuery)
            searchLog("Query completed with \(results.count) results")
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(requestID: requestID, normalizedQuery: normalizedQuery) else {
                searchLog("Stale query response discarded")
                return
            }

            isLoading = false
            searchTask = nil
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(requestID: UUID, normalizedQuery: String) -> Bool {
        activeRequestID == requestID && self.normalizedQuery == normalizedQuery
    }

    private func apply(_ cachedSearch: CachedSearch) {
        results = cachedSearch.results
        visibleCount = min(5, results.count)
        nextPageToken = cachedSearch.nextPageToken
        searchedDeeper = cachedSearch.searchedDeeper
    }

    private func cacheSearch(for normalizedQuery: String) {
        cache[normalizedQuery] = CachedSearch(
            results: results,
            nextPageToken: nextPageToken,
            searchedDeeper: searchedDeeper
        )
        cacheOrder.removeAll { $0 == normalizedQuery }
        cacheOrder.append(normalizedQuery)

        if cacheOrder.count > maximumCachedQueries {
            let expiredQuery = cacheOrder.removeFirst()
            cache.removeValue(forKey: expiredQuery)
        }
    }

    private static func normalize(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var libraryTracks: [Track]

    @Query(sort: \Playlist.dateCreated, order: .reverse)
    private var playlists: [Playlist]

    @StateObject private var viewModel = SearchViewModel()
    @State private var activeActions: Set<String> = []
    @State private var playRequestID: UUID?
    @State private var noticeMessage: String?
    @State private var errorMessage: String?
    @State private var isShowingManualTrackAdd = false
    @State private var isShowingYouTubePlaylistImport = false
    @State private var playlistResult: YouTubeSearchResult?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    Text("Search")
                        .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
                        .foregroundStyle(ShaudiTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)

                    searchField

                    HStack(spacing: 10) {
                        Button {
                            isShowingManualTrackAdd = true
                        } label: {
                            Label("Add by URL", systemImage: "link")
                                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                                .foregroundStyle(ShaudiTheme.accent)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.bordered)
                        .tint(ShaudiTheme.accent)

                        Button {
                            isShowingYouTubePlaylistImport = true
                        } label: {
                            Label("Import Playlist", systemImage: "square.and.arrow.down")
                                .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                                .foregroundStyle(ShaudiTheme.accent)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.bordered)
                        .tint(ShaudiTheme.accent)
                    }
                    .frame(maxWidth: .infinity)

                    if let noticeMessage {
                        Label(noticeMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    searchContent
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ShaudiTheme.canvas)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(appearanceSettings.primaryColor)
        .sheet(isPresented: $isShowingManualTrackAdd) {
            ManualTrackAdditionView()
        }
        .sheet(isPresented: $isShowingYouTubePlaylistImport) {
            YouTubePlaylistImportView()
        }
        .overlay {
            if let playlistResult {
                ShaudiAddToPlaylistModal(
                    isPresented: Binding(
                        get: { self.playlistResult != nil },
                        set: { if !$0 { self.playlistResult = nil } }
                    ),
                    transientTrack: trackForPlaylist(playlistResult)
                )
            }
        }
        .onChange(of: viewModel.query) {
            noticeMessage = nil
            playbackManager.cancelSearchPreResolution()
            viewModel.queryDidChange()
        }
        .onChange(of: viewModel.results) {
            playbackManager.preResolveSearchResults(viewModel.results)
        }
        .alert(
            "Couldn’t Complete Action",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Songs, artists, or anything", text: $viewModel.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(ShaudiTheme.card, in: RoundedRectangle(cornerRadius: 15))
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.trimmedQuery.isEmpty {
            ContentUnavailableView(
                "Find Your Next Track",
                systemImage: "music.note.list",
                description: Text("Search YouTube by song, artist, or any phrase.")
            )
            .padding(.top, 56)
        } else if viewModel.isQueryTooShort {
            ContentUnavailableView(
                "Keep Typing",
                systemImage: "text.cursor",
                description: Text("Enter at least 3 characters to search.")
            )
            .padding(.top, 56)
        } else if viewModel.isLoading, viewModel.results.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching YouTube…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 72)
        } else if let searchError = viewModel.errorMessage, viewModel.results.isEmpty {
            ContentUnavailableView(
                "Search Unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text(searchError)
            )
            .padding(.top, 48)
        } else if viewModel.results.isEmpty {
            ContentUnavailableView.search(text: viewModel.trimmedQuery)
                .padding(.top, 48)
        } else {
            resultsContent
        }
    }

    private var resultsContent: some View {
        VStack(spacing: 12) {
            ForEach(viewModel.visibleResults) { result in
                searchResultRow(result)
            }

            if viewModel.canShowMore {
                Button("Show More") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.showMore()
                    }
                }
                .buttonStyle(.bordered)
            } else if viewModel.canSearchDeeper {
                Button("Search Deeper") {
                    viewModel.searchDeeper()
                }
                .buttonStyle(.borderedProminent)
            } else if viewModel.isLoadingDeeper {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching deeper…")
                }
                .foregroundStyle(.secondary)
            }

            if let searchError = viewModel.errorMessage {
                Text(searchError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func searchResultRow(_ result: YouTubeSearchResult) -> some View {
        HStack(spacing: 12) {
            Button {
                play(result)
            } label: {
                HStack(spacing: 12) {
                    artwork(for: result)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .headline))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Text(result.channelTitle)
                            .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if isInLibrary(result) {
                            Label("In Library", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(ShaudiTheme.lavender)
                        }
                    }

                    Spacer(minLength: 0)

                    playbackIndicator(for: result)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(activeActions.contains(result.youtubeVideoID))

            resultMenu(result)
        }
        .padding(10)
        .background(ShaudiTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func artwork(for result: YouTubeSearchResult) -> some View {
        AsyncImage(url: result.thumbnailURL) { phase in
            switch phase {
            case .empty:
                ZStack {
                    Color.secondary.opacity(0.12)
                    ProgressView()
                }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                ZStack {
                    ShaudiTheme.lavender.opacity(0.15)
                    Image(systemName: "music.note")
                        .foregroundStyle(ShaudiTheme.lavender)
                }
            @unknown default:
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func playbackIndicator(for result: YouTubeSearchResult) -> some View {
        if activeActions.contains(result.youtubeVideoID) {
            ProgressView()
                .frame(width: 28)
        } else if playbackManager.isCurrentPlayable(result.youtubeVideoID) {
            switch playbackManager.state {
            case .resolving, .loading:
                ProgressView()
                    .frame(width: 28)
            case .playing:
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(ShaudiTheme.accent)
                    .frame(width: 28)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(ShaudiTheme.accent)
                    .frame(width: 28)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 28)
            case .idle:
                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }
        } else {
            Image(systemName: "play.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28)
        }
    }

    private func resultMenu(_ result: YouTubeSearchResult) -> some View {
        Menu {
            Button {
                addToLibrary(result)
            } label: {
                Label(
                    isInLibrary(result) ? "Already in Library" : "Add to Library",
                    systemImage: isInLibrary(result) ? "checkmark" : "plus"
                )
            }
            .disabled(isInLibrary(result))

            Button {
                playlistResult = result
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }

            if playbackManager.currentPlayableTrack != nil {
                Button {
                    let track = existingTrack(for: result.youtubeVideoID)
                        ?? trackForPlaylist(result)
                    playbackManager.playNext(track)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    let track = existingTrack(for: result.youtubeVideoID)
                        ?? trackForPlaylist(result)
                    playbackManager.addToQueue(track)
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 36, height: 44)
        }
        .disabled(activeActions.contains(result.youtubeVideoID))
        .accessibilityLabel("Actions for \(result.title)")
    }

    private func play(_ result: YouTubeSearchResult) {
        let searchQuery = viewModel.trimmedQuery
        playbackManager.prepareForManualSearchPlayback()
        playbackManager.promoteSearchPreResolution(for: result.youtubeVideoID)
        let requestID = UUID()
        playRequestID = requestID
        beginAction(for: result)

        Task {
            defer { endAction(for: result) }

            do {
                let metadata = try await viewModel.detailedMetadata(for: result)
                guard playRequestID == requestID else {
                    return
                }

                let playableTrack = PlayableTrack(
                    youtubeVideoID: result.youtubeVideoID,
                    title: metadata.title,
                    channelTitle: metadata.channelTitle,
                    thumbnailURL: metadata.thumbnailURL ?? result.thumbnailURL,
                    duration: metadata.duration
                )
                let learnedIdentity = await PersistentYouTubeResolutionCache.shared
                    .learnedIdentity(forVideoID: result.youtubeVideoID)
                searchLog("Playing transient result \(result.youtubeVideoID)")
                playbackManager.play(
                    playableTrack,
                    canonicalIdentity: learnedIdentity,
                    searchQuery: searchQuery
                )
                teachResolution(
                    result: result,
                    metadata: metadata,
                    source: .manualSearch,
                    searchQuery: searchQuery
                )
            } catch is CancellationError {
                return
            } catch {
                guard playRequestID == requestID else {
                    return
                }

                errorMessage = error.localizedDescription
            }
        }
    }

    private func addToLibrary(_ result: YouTubeSearchResult) {
        guard existingTrack(for: result.youtubeVideoID) == nil else {
            return
        }

        beginAction(for: result)
        Task {
            defer { endAction(for: result) }

            do {
                let metadata = try await viewModel.detailedMetadata(for: result)
                guard existingTrack(for: result.youtubeVideoID) == nil else {
                    noticeMessage = "Already in Library"
                    return
                }

                let track = makeTrack(for: result, metadata: metadata)
                let persistedTrack = try TrackPersistence.promoteOrReuse(
                    track: track,
                    in: modelContext,
                    targetPlaylist: nil,
                    existingLibraryTracks: libraryTracks
                )
                teachResolution(result: result, metadata: metadata, source: .library)
                noticeMessage = "Added “\(persistedTrack.displayTitle)” to Library"
                searchLog("Saved Library track \(result.youtubeVideoID)")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add(_ result: YouTubeSearchResult, to playlist: Playlist) {
        guard !contains(result, in: playlist) else {
            return
        }

        beginAction(for: result)
        Task {
            defer { endAction(for: result) }

            do {
                let metadata = try await viewModel.detailedMetadata(for: result)
                guard !contains(result, in: playlist) else {
                    noticeMessage = "Already in \(playlist.name)"
                    return
                }

                let track = makeTrack(for: result, metadata: metadata)
                let persistedTrack = try TrackPersistence.promoteOrReuse(
                    track: track,
                    in: modelContext,
                    targetPlaylist: playlist,
                    existingLibraryTracks: libraryTracks
                )
                teachResolution(result: result, metadata: metadata, source: .playlist)
                noticeMessage = "Added “\(persistedTrack.displayTitle)” to \(playlist.name)"
                searchLog("Added track \(result.youtubeVideoID) to playlist")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func beginAction(for result: YouTubeSearchResult) {
        noticeMessage = nil
        errorMessage = nil
        activeActions.insert(result.youtubeVideoID)
    }

    private func endAction(for result: YouTubeSearchResult) {
        activeActions.remove(result.youtubeVideoID)
    }

    private func existingTrack(for videoID: String) -> Track? {
        libraryTracks.first { $0.youtubeVideoID == videoID }
    }

    private func isInLibrary(_ result: YouTubeSearchResult) -> Bool {
        existingTrack(for: result.youtubeVideoID) != nil
    }

    private func contains(_ result: YouTubeSearchResult, in playlist: Playlist) -> Bool {
        playlist.tracks.contains { $0.youtubeVideoID == result.youtubeVideoID }
    }

    private func trackForPlaylist(_ result: YouTubeSearchResult) -> Track {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: result.youtubeVideoID)]
        return Track(
            title: result.title,
            youtubeURL: components.url!,
            youtubeVideoID: result.youtubeVideoID,
            channelTitle: result.channelTitle,
            thumbnailURL: result.thumbnailURL,
            duration: result.duration,
            metadataLastRefreshed: .now
        )
    }

    private func makeTrack(
        for result: YouTubeSearchResult,
        metadata: YouTubeMetadata
    ) -> Track {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: result.youtubeVideoID)]

        return Track(
            title: metadata.title,
            youtubeURL: components.url!,
            youtubeVideoID: result.youtubeVideoID,
            channelTitle: metadata.channelTitle,
            thumbnailURL: metadata.thumbnailURL ?? result.thumbnailURL,
            duration: metadata.duration,
            metadataLastRefreshed: .now
        )
    }

    private func teachResolution(
        result: YouTubeSearchResult,
        metadata: YouTubeMetadata,
        source: YouTubeResolutionKnowledgeSource,
        searchQuery: String? = nil
    ) {
        Task {
            await YouTubeResolutionKnowledgeTeacher.learnIfConfident(
                videoID: result.youtubeVideoID,
                rawTitle: metadata.title,
                displayedArtist: metadata.channelTitle,
                sourceChannel: metadata.channelTitle,
                userArtistOverride: nil,
                metadata: YouTubeResolutionMetadata(
                    title: metadata.title,
                    channel: metadata.channelTitle,
                    thumbnailURL: metadata.thumbnailURL ?? result.thumbnailURL,
                    duration: metadata.duration
                ),
                source: source,
                searchQuery: searchQuery
            )
        }
    }
}

private func searchLog(_ message: String) {
#if DEBUG
    print("[Search] \(message)")
#endif
}
