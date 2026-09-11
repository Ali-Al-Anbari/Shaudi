import SwiftUI
#if os(iOS)
import UIKit
#endif

enum ShaudiTheme {
    static let accent = Color(red: 0.62, green: 0.34, blue: 0.48)
    static let lavender = Color(red: 0.58, green: 0.51, blue: 0.72)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)

    static func scriptFont(size: CGFloat, relativeTo textStyle: Font.TextStyle = .title) -> Font {
#if os(iOS)
        if UIFont(name: "SnellRoundhand", size: size) != nil {
            return .custom("SnellRoundhand", size: size, relativeTo: textStyle)
        }
#endif
        return .system(size: size, weight: .semibold, design: .rounded)
    }

}
