import XCTest
import UIKit
@testable import Shaudi

@MainActor
final class AppIconSettingsTests: XCTestCase {
    private let names: Set<String> = ["AppIcon-Blue", "AppIcon-Green"]

    func testDefaultMapsToNilAndConfiguredAlternateMapsToExactName() {
        let options = AppIconOption.options(configuredNames: names)
        XCTAssertNil(options.first?.iconName)
        XCTAssertEqual(options.map(\.iconName), [nil, "AppIcon-Blue", "AppIcon-Green"])
    }

    func testUnknownActiveIconFallsBackToDefaultSelection() {
        XCTAssertNil(AppIconOption.selectedName(activeIconName: "AppIcon-Removed", configuredNames: names))
        XCTAssertNil(AppIconOption.selectedName(activeIconName: nil, configuredNames: names))
    }

    func testSelectedStateReflectsSystemIconName() {
        XCTAssertEqual(
            AppIconOption.selectedName(activeIconName: "AppIcon-Green", configuredNames: names),
            "AppIcon-Green"
        )
    }

    func testPreviewAssetNamesFollowIconNames() {
        XCTAssertEqual(AppIconOption(iconName: nil).previewAssetName, "AppIcon-Preview")
        XCTAssertEqual(AppIconOption(iconName: "AppIcon-Pink").previewAssetName, "AppIcon-Pink-Preview")
        XCTAssertEqual(AppIconOption(iconName: "AppIcon2").previewAssetName, "AppIcon2-Preview")
    }

    func testMissingPreviewReturnsNilForPlaceholder() {
        var requestedName: String?
        let image = AppIconOption(iconName: "AppIcon-Blue").previewImage { name in
            requestedName = name
            return nil
        }
        XCTAssertNil(image)
        XCTAssertEqual(requestedName, "AppIcon-Blue-Preview")
    }

    func testSelectionUsesLatestSystemReportedNameWithoutPersistence() {
        XCTAssertEqual(AppIconOption.selectedName(activeIconName: "AppIcon-Blue", configuredNames: names), "AppIcon-Blue")
        XCTAssertEqual(AppIconOption.selectedName(activeIconName: "AppIcon-Green", configuredNames: names), "AppIcon-Green")
        XCTAssertNil(AppIconOption.selectedName(activeIconName: nil, configuredNames: names))
    }

    func testUnsupportedAndInvalidOptionsCannotRequestChange() {
        XCTAssertFalse(AppIconOption.canRequest(.init(iconName: nil), configuredNames: names, supported: false))
        XCTAssertFalse(AppIconOption.canRequest(.init(iconName: "AppIcon-Unknown"), configuredNames: names, supported: true))
        XCTAssertTrue(AppIconOption.canRequest(.init(iconName: nil), configuredNames: names, supported: true))
        XCTAssertTrue(AppIconOption.canRequest(.init(iconName: "AppIcon-Blue"), configuredNames: names, supported: true))
    }

    func testOnlyBuiltInPlistAlternatesAreOffered() {
        let plist: [String: Any] = [
            "CFBundleIcons": ["CFBundleAlternateIcons": ["AppIcon-Blue": [:]]]
        ]
        XCTAssertEqual(AppIconOption.configuredNames(in: plist), ["AppIcon-Blue"])
        XCTAssertTrue(AppIconOption.configuredNames(in: [:]).isEmpty)
    }
}
