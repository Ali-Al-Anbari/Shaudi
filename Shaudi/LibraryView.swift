//
//  LibraryView.swift
//  Shaudi
//

import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Track.dateAdded, order: .reverse)
    private var tracks: [Track]

    @State private var isShowingNewTrack = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(tracks) { track in
                    NavigationLink {
                        TrackDetailView(track: track)
                    } label: {
                        Text(track.title)
                    }
                }
                .onDelete(perform: deleteTracks)
            }
            .navigationTitle("Library")
            .toolbar {
                Button {
                    isShowingNewTrack = true
                } label: {
                    Label("New Track", systemImage: "plus")
                }
            }
            .sheet(isPresented: $isShowingNewTrack) {
                TrackEditorView(
                    title: "New Track",
                    actionTitle: "Create"
                ) { title, youtubeURL in
                    modelContext.insert(
                        Track(
                            title: title,
                            youtubeURL: youtubeURL,
                            youtubeVideoID: ""
                        )
                    )
                }
            }
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(tracks[index])
        }
    }
}

private struct TrackEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    let onSave: (String, URL) -> Void

    @State private var trackTitle: String
    @State private var youtubeURLText: String

    init(
        title: String,
        actionTitle: String,
        initialTrackTitle: String = "",
        initialYouTubeURL: URL? = nil,
        onSave: @escaping (String, URL) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.onSave = onSave
        _trackTitle = State(initialValue: initialTrackTitle)
        _youtubeURLText = State(initialValue: initialYouTubeURL?.absoluteString ?? "")
    }

    private var trimmedTitle: String {
        trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURLText: String {
        youtubeURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard
            let url = URL(string: trimmedURLText),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            return nil
        }

        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Track Title", text: $trackTitle)

                Section {
                    TextField("YouTube URL", text: $youtubeURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if !trimmedURLText.isEmpty && validatedURL == nil {
                        Text("Enter a valid web URL.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        guard let youtubeURL = validatedURL else {
                            return
                        }

                        onSave(trimmedTitle, youtubeURL)
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty || validatedURL == nil)
                }
            }
        }
    }
}

private struct TrackDetailView: View {
    let track: Track

    @State private var isShowingEdit = false

    var body: some View {
        Form {
            LabeledContent("Title", value: track.title)
            LabeledContent("YouTube URL", value: track.youtubeURL.absoluteString)
            LabeledContent(
                "Date Added",
                value: track.dateAdded.formatted(date: .abbreviated, time: .shortened)
            )
        }
        .navigationTitle(track.title)
        .toolbar {
            Button("Edit") {
                isShowingEdit = true
            }
        }
        .sheet(isPresented: $isShowingEdit) {
            TrackEditorView(
                title: "Edit Track",
                actionTitle: "Save",
                initialTrackTitle: track.title,
                initialYouTubeURL: track.youtubeURL
            ) { title, youtubeURL in
                track.title = title
                track.youtubeURL = youtubeURL
            }
        }
    }
}
