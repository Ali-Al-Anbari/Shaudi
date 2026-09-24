import SwiftUI
import UIKit

struct AppIconOption: Identifiable, Equatable {
    let iconName: String?

    var id: String { iconName ?? "primary" }
    var previewAssetName: String { "\(iconName ?? "AppIcon")-Preview" }

    func previewImage(load: (String) -> UIImage?) -> UIImage? {
        load(previewAssetName)
    }

    static func configuredNames(in infoDictionary: [String: Any]?) -> Set<String> {
        let icons = infoDictionary?["CFBundleIcons"] as? [String: Any]
        let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
        return Set(alternates?.keys.map { $0 } ?? [])
    }

    static func options(configuredNames: Set<String>) -> [AppIconOption] {
        [AppIconOption(iconName: nil)] + configuredNames.sorted().map { AppIconOption(iconName: $0) }
    }

    static func selectedName(activeIconName: String?, configuredNames: Set<String>) -> String? {
        guard let activeIconName, configuredNames.contains(activeIconName) else { return nil }
        return activeIconName
    }

    static func canRequest(_ option: AppIconOption, configuredNames: Set<String>, supported: Bool) -> Bool {
        guard supported else { return false }
        guard let iconName = option.iconName else { return true }
        return configuredNames.contains(iconName)
    }
}

struct AppIconSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeIconName: String?
    @State private var isShowingPicker = false
    @State private var isChangingIcon = false
    @State private var errorMessage: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    private var configuredNames: Set<String> {
        AppIconOption.configuredNames(in: Bundle.main.infoDictionary)
    }

    private var options: [AppIconOption] {
        AppIconOption.options(configuredNames: configuredNames)
    }

    private var selectedIconName: String? {
        AppIconOption.selectedName(activeIconName: activeIconName, configuredNames: configuredNames)
    }

    var body: some View {
        HStack(spacing: 14) {
            iconPreview(for: AppIconOption(iconName: selectedIconName), size: 56)

            Spacer()

            Button("Change Icon") {
                refreshSelection()
                isShowingPicker = true
            }
            .buttonStyle(.borderedProminent)
            .tint(ShaudiTheme.accent)
            .disabled(!UIApplication.shared.supportsAlternateIcons || options.count < 2)
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: refreshSelection)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSelection() }
        }
        .sheet(isPresented: $isShowingPicker) {
            pickerSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var pickerSheet: some View {
        VStack(spacing: 24) {
            Text("Change Icon")
                .font(ShaudiTheme.bodyFont(size: 20, relativeTo: .title3).weight(.semibold))
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(options) { option in
                    Button {
                        requestIcon(option)
                    } label: {
                        iconPreview(for: option, size: 76)
                            .padding(5)
                            .overlay {
                                RoundedRectangle(cornerRadius: 21, style: .continuous)
                                    .strokeBorder(
                                        option.iconName == selectedIconName ? ShaudiTheme.accent : .clear,
                                        lineWidth: 2
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isChangingIcon)
                    .accessibilityLabel(option.iconName == nil ? "Original icon" : "Alternate icon")
                    .accessibilityAddTraits(option.iconName == selectedIconName ? [.isSelected] : [])
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShaudiTheme.dashboardBackground)
        .onAppear(perform: refreshSelection)
        .alert("Couldn't Change Icon", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func iconPreview(for option: AppIconOption, size: CGFloat) -> some View {
        if let image = option.previewImage(load: { UIImage(named: $0) }) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4))
                .foregroundStyle(ShaudiTheme.accent)
                .frame(width: size, height: size)
                .background(
                    ShaudiTheme.dashboardCard,
                    in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                )
                .accessibilityHidden(true)
        }
    }

    private func refreshSelection() {
        activeIconName = UIApplication.shared.alternateIconName
    }

    private func requestIcon(_ option: AppIconOption) {
        guard AppIconOption.canRequest(
            option,
            configuredNames: configuredNames,
            supported: UIApplication.shared.supportsAlternateIcons
        ) else {
            errorMessage = UIApplication.shared.supportsAlternateIcons
                ? "This icon is unavailable."
                : "Changing the app icon is unavailable on this device."
            return
        }

        refreshSelection()
        guard option.iconName != activeIconName else {
            isShowingPicker = false
            return
        }

        isChangingIcon = true
        UIApplication.shared.setAlternateIconName(option.iconName) { error in
            Task { @MainActor in
                isChangingIcon = false
                refreshSelection()
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    isShowingPicker = false
                }
            }
        }
    }
}
