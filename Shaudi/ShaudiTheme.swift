import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
enum ShaudiTheme {
    static var accent: Color { AppearanceSettings.shared.primaryColor }
    static var lavender: Color { AppearanceSettings.shared.secondaryColor }
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let dashboardBackground = Color(red: 0.035, green: 0.028, blue: 0.045)
    static let dashboardCard = Color(red: 0.105, green: 0.095, blue: 0.12)
    static let dashboardPlaceholder = Color(red: 0.075, green: 0.045, blue: 0.10)
    static let dashboardPrimaryText = Color(white: 0.96)
    static let dashboardSecondaryText = Color(white: 0.68)

    static func scriptFont(size: CGFloat, relativeTo textStyle: Font.TextStyle = .title) -> Font {
#if os(iOS)
        let fontName = AppearanceSettings.shared.primaryFont.fontName
        if UIFont(name: fontName, size: size) != nil {
            return .custom(fontName, size: size, relativeTo: textStyle)
        }
#endif
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    static func bodyFont(size: CGFloat, relativeTo textStyle: Font.TextStyle = .body) -> Font {
#if os(iOS)
        let fontName = AppearanceSettings.shared.secondaryFont.fontName
        if UIFont(name: fontName, size: size) != nil {
            return .custom(fontName, size: size, relativeTo: textStyle)
        }
#endif
        return .system(size: size, design: .serif)
    }

}
