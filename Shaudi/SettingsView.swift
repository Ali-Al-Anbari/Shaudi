import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appearanceSettings: AppearanceSettings
    @StateObject private var recommendationFeedback = RecommendationFeedbackStore.shared

    @State private var isShowingResetConfirmation = false
    @State private var isShowingFeedbackResetConfirmation = false
    @State private var isShowingExportBackup = false
    @State private var isShowingImportBackup = false
    @State private var isShowingImportPreview = false
    @State private var backup = ShaudiBackupCoordinator()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Settings")
                        .font(ShaudiTheme.scriptFont(size: 34, relativeTo: .title))
                        .foregroundStyle(ShaudiTheme.accent)
                        .accessibilityAddTraits(.isHeader)

                    settingsSection("Library Banner") {
                        Text("Choose the image shown at the top of your Library.")
                            .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                            .foregroundStyle(ShaudiTheme.dashboardSecondaryText)

                        LibraryBannerEditor()
                    }

                    settingsSection("Typography") {
                        Picker("Primary Font", selection: $appearanceSettings.primaryFont) {
                            ForEach(AppearanceSettings.PrimaryFont.allCases) { font in
                                Text(font.rawValue).tag(font)
                            }
                        }
                        .pickerStyle(.menu)

                        Divider()

                        Picker("Secondary Font", selection: $appearanceSettings.secondaryFont) {
                            ForEach(AppearanceSettings.SecondaryFont.allCases) { font in
                                Text(font.rawValue).tag(font)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    settingsSection("Colors") {
                        ColorPicker(
                            "Primary Color",
                            selection: $appearanceSettings.primaryColor,
                            supportsOpacity: false
                        )

                        Divider()

                        ColorPicker(
                            "Secondary Color",
                            selection: $appearanceSettings.secondaryColor,
                            supportsOpacity: false
                        )
                    }

                    settingsSection("Ambient") {
                        Toggle("Love Letters", isOn: $appearanceSettings.loveLettersEnabled)
                    }

                    settingsSection("Your Library") {
                        NavigationLink {
                            ListeningStatsView()
                        } label: {
                            Label("Listening Stats", systemImage: "chart.bar")
                                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }

                    settingsSection("Backup & Restore") {
                        Text("Save your library and playlists so they can be restored on another device.")
                            .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                            .foregroundStyle(ShaudiTheme.dashboardSecondaryText)

                        Button {
                            isShowingExportBackup = true
                        } label: {
                            Label("Export Backup", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider()

                        Button {
                            isShowingImportBackup = true
                        } label: {
                            Label("Import Backup", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    settingsSection("Recommendation Preferences") {
                        Text("Don't Recommend Artists")
                            .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline))

                        if recommendationFeedback.snapshot.excludedArtistNames.isEmpty {
                            Text("No excluded artists.")
                                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
                        } else {
                            ForEach(
                                recommendationFeedback.snapshot.excludedArtistNames,
                                id: \.self
                            ) { artist in
                                HStack {
                                    Text(artist)
                                        .lineLimit(1)

                                    Spacer(minLength: 12)

                                    Button(role: .destructive) {
                                        recommendationFeedback.removeExcludedArtist(artist)
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(width: 32, height: 32)
                                    }
                                    .accessibilityLabel("Allow recommendations by \(artist)")
                                }
                            }

                            Divider()

                            Button("Clear Don't Recommend Artists", role: .destructive) {
                                recommendationFeedback.clearExcludedArtists()
                            }
                        }

                        Divider()

                        Button("Reset Recommendation Feedback", role: .destructive) {
                            isShowingFeedbackResetConfirmation = true
                        }
                        .disabled(recommendationFeedback.snapshot.isEmpty)
                    }

                    Button("Restore Default Appearance", role: .destructive) {
                        isShowingResetConfirmation = true
                    }
                    .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(ShaudiTheme.dashboardBackground)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Restore Default Appearance?",
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    appearanceSettings.restoreDefaults()
                }
            } message: {
                Text("This resets your primary and secondary fonts and colors to their defaults.")
            }
            .confirmationDialog(
                "Reset Recommendation Feedback?",
                isPresented: $isShowingFeedbackResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Feedback", role: .destructive) {
                    recommendationFeedback.clearAll()
                }
            } message: {
                Text("This clears More Like This, Less Like This, and all excluded artists.")
            }
            .sheet(isPresented: $isShowingExportBackup) {
                ShaudiBackupExportSheet()
            }
            .fileImporter(
                isPresented: $isShowingImportBackup,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    try backup.prepareImport(from: url)
                    isShowingImportPreview = true
                } catch {
                    backup.errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $isShowingImportPreview, onDismiss: {
                backup.cancelImport()
            }) {
                ShaudiBackupImportSheet(backup: backup)
            }
            .alert("Backup & Restore", isPresented: Binding(
                get: { backup.errorMessage != nil && !isShowingImportPreview },
                set: { if !$0 { backup.errorMessage = nil } }
            )) {
                Button("OK") { backup.errorMessage = nil }
            } message: {
                Text(backup.errorMessage ?? "")
            }
        }
        .tint(appearanceSettings.primaryColor)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .headline).weight(.semibold))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)

            VStack(alignment: .leading, spacing: 14, content: content)
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ShaudiTheme.dashboardCard,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }
}

private struct LibraryBannerEditor: View {
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @State private var isShowingPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editingImage: UIImage?
    @State private var isShowingCropEditor = false

    var body: some View {
        Button("Change Banner") {
            isShowingPhotoPicker = true
        }
        .buttonStyle(.borderedProminent)
        .tint(ShaudiTheme.accent)
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, photo in
            prepareSelectedPhoto(photo)
        }
        .sheet(isPresented: $isShowingCropEditor) {
            if let editingImage {
                ImageCropEditor(
                    image: editingImage,
                    title: "Adjust Banner",
                    cropAspectRatio: ArtworkStorage.bannerAspectRatio,
                    outputSize: ArtworkStorage.bannerOutputSize,
                    cornerRadius: 18
                ) { image in
                    saveBannerImage(image)
                }
            }
        }
    }

    private func prepareSelectedPhoto(_ selectedPhoto: PhotosPickerItem?) {
        guard let selectedPhoto else {
            return
        }

        Task { @MainActor in
            defer { self.selectedPhoto = nil }
            guard
                let data = try? await selectedPhoto.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                return
            }

            editingImage = image
            isShowingCropEditor = true
        }
    }

    private func saveBannerImage(_ image: UIImage) {
        do {
            try ArtworkStorage.saveBannerImage(image)
            ArtworkStorage.clearLegacyBannerStorage()
            appearanceSettings.bannerDidChange()
        } catch {
#if DEBUG
            print("[Artwork] Banner save failed: \(error.localizedDescription)")
#endif
        }
    }
}
