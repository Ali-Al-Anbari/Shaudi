import XCTest
@testable import Shaudi

@MainActor
final class AmbientLoveLetterTests: XCTestCase {
    func testMessageSelectionDoesNotRepeatThePreviousMessage() {
        XCTAssertEqual(
            LoveLetterScheduler.nextMessageIndex(count: 3, lastIndex: 1, randomIndex: 1),
            2
        )
    }

    func testDisabledSettingPreventsPresentationAndEnablingSchedulesAgain() {
        let coordinator = coordinator()
        coordinator.update(isEnabled: false, isAppActive: true)
        XCTAssertFalse(coordinator.isPresentationScheduled)
        coordinator.presentScheduledLetter()
        XCTAssertNil(coordinator.visibleLetter)

        coordinator.update(isEnabled: true, isAppActive: true)
        XCTAssertTrue(coordinator.isPresentationScheduled)
    }

    func testOnlyOnePendingPresentationIsScheduled() {
        let coordinator = coordinator()
        coordinator.update(isEnabled: true, isAppActive: true)
        coordinator.update(isEnabled: true, isAppActive: true)

        XCTAssertTrue(coordinator.isPresentationScheduled)
    }

    func testInactiveAppCancelsPendingPresentation() {
        let coordinator = coordinator()
        coordinator.update(isEnabled: true, isAppActive: true)
        XCTAssertTrue(coordinator.isPresentationScheduled)
        coordinator.update(isEnabled: true, isAppActive: false)

        XCTAssertFalse(coordinator.isPresentationScheduled)
    }

    func testDisablingWhileVisibleRemovesTheLetter() {
        let coordinator = coordinator()
        coordinator.update(isEnabled: true, isAppActive: true)
        coordinator.presentScheduledLetter()
        XCTAssertNotNil(coordinator.visibleLetter)

        coordinator.update(isEnabled: false, isAppActive: true)
        XCTAssertNil(coordinator.visibleLetter)
        XCTAssertFalse(coordinator.isPresentationScheduled)
    }

    func testAppearanceCompletionReschedulesWithoutOverlappingPendingWork() async {
        let coordinator = coordinator(visibleDuration: 0, fadeDuration: 0)
        coordinator.update(isEnabled: true, isAppActive: true)
        coordinator.presentScheduledLetter()
        XCTAssertFalse(coordinator.isPresentationScheduled)

        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertNil(coordinator.visibleLetter)
        XCTAssertTrue(coordinator.isPresentationScheduled)
    }

    func testMessageListIsNotEmpty() {
        XCTAssertFalse(LoveLetterScheduler.messages.isEmpty)
    }

    func testLoveLettersDefaultToEnabledForFreshSettings() {
        let suiteName = "AmbientLoveLetterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AppearanceSettings(defaults: defaults)

        XCTAssertTrue(settings.loveLettersEnabled)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func coordinator(
        visibleDuration: TimeInterval = LoveLetterPolicy.visibleDuration,
        fadeDuration: TimeInterval = LoveLetterPolicy.fadeDuration
    ) -> AmbientLoveLetterCoordinator {
        AmbientLoveLetterCoordinator(
            delayProvider: { 60 * 60 },
            messageIndexProvider: { _ in 0 },
            fadeDuration: fadeDuration,
            visibleDuration: visibleDuration
        )
    }
}
