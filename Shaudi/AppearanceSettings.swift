import Combine
import SwiftUI
import UIKit

@MainActor
final class AppearanceSettings: ObservableObject {
    enum PrimaryFont: String, CaseIterable, Identifiable {
        case snellRoundhand = "Snell Roundhand"
        case baskerville = "Baskerville"
        case georgia = "Georgia"

        var id: String { rawValue }

        var fontName: String {
            switch self {
            case .snellRoundhand:
                return "SnellRoundhand"
            case .baskerville:
                return "Baskerville"
            case .georgia:
                return "Georgia"
            }
        }
    }

    enum SecondaryFont: String, CaseIterable, Identifiable {
        case timesNewRoman = "Times New Roman"
        case avenirNext = "Avenir Next"
        case georgia = "Georgia"

        var id: String { rawValue }

        var fontName: String {
            switch self {
            case .timesNewRoman:
                return "Times New Roman"
            case .avenirNext:
                return "Avenir Next"
            case .georgia:
                return "Georgia"
            }
        }
    }

    static let shared = AppearanceSettings()

    static let defaultPrimaryColor = Color(red: 0.62, green: 0.34, blue: 0.48)
    static let defaultSecondaryColor = Color(red: 0.58, green: 0.51, blue: 0.72)

    @Published var primaryFont: PrimaryFont {
        didSet {
            defaults.set(primaryFont.rawValue, forKey: Keys.primaryFont)
        }
    }

    @Published var secondaryFont: SecondaryFont {
        didSet {
            defaults.set(secondaryFont.rawValue, forKey: Keys.secondaryFont)
        }
    }

    @Published var primaryColor: Color {
        didSet {
            save(primaryColor, forKey: Keys.primaryColor)
        }
    }

    @Published var secondaryColor: Color {
        didSet {
            save(secondaryColor, forKey: Keys.secondaryColor)
        }
    }

    @Published var loveLettersEnabled: Bool {
        didSet {
            defaults.set(loveLettersEnabled, forKey: Keys.loveLettersEnabled)
        }
    }

    @Published private(set) var bannerRevision = UUID()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        primaryFont = PrimaryFont(
            rawValue: defaults.string(forKey: Keys.primaryFont) ?? ""
        ) ?? .snellRoundhand
        secondaryFont = SecondaryFont(
            rawValue: defaults.string(forKey: Keys.secondaryFont) ?? ""
        ) ?? .timesNewRoman
        primaryColor = Self.loadColor(
            forKey: Keys.primaryColor,
            defaultValue: Self.defaultPrimaryColor,
            defaults: defaults
        )
        secondaryColor = Self.loadColor(
            forKey: Keys.secondaryColor,
            defaultValue: Self.defaultSecondaryColor,
            defaults: defaults
        )
        loveLettersEnabled = defaults.object(forKey: Keys.loveLettersEnabled) as? Bool ?? true
    }

    func restoreDefaults() {
        primaryFont = .snellRoundhand
        secondaryFont = .timesNewRoman
        primaryColor = Self.defaultPrimaryColor
        secondaryColor = Self.defaultSecondaryColor
    }

    func bannerDidChange() {
        bannerRevision = UUID()
    }

    private enum Keys {
        static let primaryFont = "shaudi.appearance.primaryFont"
        static let secondaryFont = "shaudi.appearance.secondaryFont"
        static let primaryColor = "shaudi.appearance.primaryColor"
        static let secondaryColor = "shaudi.appearance.secondaryColor"
        static let loveLettersEnabled = "shaudi.appearance.loveLettersEnabled"
    }

    private struct ColorComponents: Codable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private func save(_ color: Color, forKey key: String) {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              let data = try? JSONEncoder().encode(
                ColorComponents(
                    red: Double(red),
                    green: Double(green),
                    blue: Double(blue),
                    alpha: Double(alpha)
                )
              )
        else {
            return
        }

        defaults.set(data, forKey: key)
    }

    private static func loadColor(
        forKey key: String,
        defaultValue: Color,
        defaults: UserDefaults
    ) -> Color {
        guard
            let data = defaults.data(forKey: key),
            let components = try? JSONDecoder().decode(ColorComponents.self, from: data)
        else {
            return defaultValue
        }

        return Color(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: components.alpha
        )
    }
}
