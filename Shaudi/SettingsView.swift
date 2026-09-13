import PhotosUI
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appearanceSettings: AppearanceSettings

    @State private var isShowingResetConfirmation = false
    @State private var isShowingFinalResetConfirmation = false

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

                    settingsSection("Coming Soon") {
                        HStack {
                            Label("Listening Stats", systemImage: "chart.bar")
                            Spacer()
                            Text("Coming soon")
                                .foregroundStyle(.secondary)
                        }
                        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                        .opacity(0.65)
                        .accessibilityHint("Listening Stats will be available in a future update")
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
                Button("Continue", role: .destructive) {
                    isShowingFinalResetConfirmation = true
                }
            } message: {
                Text(
                    "This resets your primary font, secondary font, primary color, "
                        + "secondary color, and Library banner."
                )
            }
            .confirmationDialog(
                "Are you sure?",
                isPresented: $isShowingFinalResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    appearanceSettings.restoreDefaults()
                    ArtworkStorage.resetBannerImage()
                    appearanceSettings.bannerDidChange()
                }
            } message: {
                Text("Your appearance choices and Library banner will be restored to Shaudi defaults.")
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
