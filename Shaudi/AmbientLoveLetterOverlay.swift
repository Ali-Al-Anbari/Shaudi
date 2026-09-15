import Combine
import SwiftUI

enum LoveLetterPolicy {
    nonisolated static let minimumDelay: TimeInterval = 1.5 * 60
    nonisolated static let maximumDelay: TimeInterval = 3 * 60
    nonisolated static let fadeDuration: TimeInterval = 1
    nonisolated static let visibleDuration: TimeInterval = 5
}

enum LoveLetterPosition: CaseIterable, Hashable {
    case upperLeft
    case upperRight
    case middleLeft
    case middleRight
    case lowerLeft
    case lowerRight
}

enum LoveLetterScheduler {
    static let messages = [
        "you make ordinary days feel special",
        "i'd choose you in every version of this life",
        "some songs sound better because they remind me of you",
        "you are my favorite person",
        "you make everything feel a little softer",
        "life without you would be ass lowkey",
        "you are the calm in all my favorite chaos",
        "every day with you feels like a small miracle",
        "you make my world feel more like home",
        "my favorite memories always have you in them",
        "you are my sweetest thought",
        "the best part of my day is always you",
        "you make the little things feel beautiful",
        "i still get excited to tell you things",
        "if you see this screenshot it and ill send you $10",
        "loving you feels wonderfully easy",
        "you make my heart feel understood",
        "huge ass on you ngl",
        "the world is warmer with you in it",
        "you make even quiet moments feel full",
        "i like who i am when i'm with you",
        "you are the thought behind my smile",
        "you make life feel beautifully familiar",
        "my heart is always a little happier near you"
    ]

    static func nextMessageIndex(
        count: Int,
        lastIndex: Int?,
        randomIndex: Int
    ) -> Int? {
        guard count > 0 else {
            return nil
        }
        let selected = min(max(0, randomIndex), count - 1)
        guard count > 1, selected == lastIndex else {
            return selected
        }
        return (selected + 1) % count
    }

    static func canSchedule(
        isEnabled: Bool,
        isAppActive: Bool,
        isSuppressed: Bool
    ) -> Bool {
        isEnabled && isAppActive && !isSuppressed && !messages.isEmpty
    }
}

@MainActor
final class AmbientLoveLetterCoordinator: ObservableObject {
    struct Letter: Identifiable {
        let id = UUID()
        let message: String
        let position: LoveLetterPosition
    }

    @Published private(set) var visibleLetter: Letter?
    private(set) var isPresentationScheduled = false

    private var lastMessageIndex: Int?
    private var lastPosition: LoveLetterPosition?
    private var pendingTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var isEnabled = true
    private var isAppActive = true
    private var isSuppressed = false
    private let delayProvider: () -> TimeInterval
    private let messageIndexProvider: (Int) -> Int
    private let positionIndexProvider: (Int) -> Int
    private let fadeDuration: TimeInterval
    private let visibleDuration: TimeInterval

    init(
        delayProvider: @escaping () -> TimeInterval = {
            Double.random(in: LoveLetterPolicy.minimumDelay...LoveLetterPolicy.maximumDelay)
        },
        messageIndexProvider: @escaping (Int) -> Int = { Int.random(in: 0..<$0) },
        positionIndexProvider: @escaping (Int) -> Int = { Int.random(in: 0..<$0) },
        fadeDuration: TimeInterval = LoveLetterPolicy.fadeDuration,
        visibleDuration: TimeInterval = LoveLetterPolicy.visibleDuration
    ) {
        self.delayProvider = delayProvider
        self.messageIndexProvider = messageIndexProvider
        self.positionIndexProvider = positionIndexProvider
        self.fadeDuration = fadeDuration
        self.visibleDuration = visibleDuration
    }

    func update(isEnabled: Bool, isAppActive: Bool, isSuppressed: Bool) {
        self.isEnabled = isEnabled
        self.isAppActive = isAppActive
        self.isSuppressed = isSuppressed

        guard LoveLetterScheduler.canSchedule(
            isEnabled: isEnabled,
            isAppActive: isAppActive,
            isSuppressed: isSuppressed
        ) else {
            cancelAndHide()
            return
        }

        guard visibleLetter == nil else {
            return
        }
        scheduleNextAppearanceIfNeeded()
    }

    func presentScheduledLetter() {
        guard
            isPresentationScheduled,
            LoveLetterScheduler.canSchedule(
                isEnabled: isEnabled,
                isAppActive: isAppActive,
                isSuppressed: isSuppressed
            ),
            let messageIndex = LoveLetterScheduler.nextMessageIndex(
                count: LoveLetterScheduler.messages.count,
                lastIndex: lastMessageIndex,
                randomIndex: messageIndexProvider(LoveLetterScheduler.messages.count)
            )
        else {
            return
        }

        pendingTask?.cancel()
        pendingTask = nil
        isPresentationScheduled = false
        lastMessageIndex = messageIndex
        let positions = LoveLetterPosition.allCases
        var position = positions[positionIndexProvider(positions.count) % positions.count]
        if positions.count > 1, position == lastPosition {
            position = positions[(positions.firstIndex(of: position)! + 1) % positions.count]
        }
        lastPosition = position

        withAnimation(.easeInOut(duration: fadeDuration)) {
            visibleLetter = Letter(
                message: LoveLetterScheduler.messages[messageIndex],
                position: position
            )
        }

        dismissalTask?.cancel()
        let visibleDuration = self.visibleDuration
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(visibleDuration * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            self?.hideThenScheduleNext()
        }
    }

    private func scheduleNextAppearanceIfNeeded() {
        guard !isPresentationScheduled, pendingTask == nil else {
            return
        }
        isPresentationScheduled = true
        let delay = delayProvider()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            self?.presentScheduledLetter()
        }
    }

    private func hideThenScheduleNext() {
        withAnimation(.easeInOut(duration: fadeDuration)) {
            visibleLetter = nil
        }
        let fadeDuration = self.fadeDuration
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(fadeDuration * 1_000_000_000))
            guard !Task.isCancelled, let self else {
                return
            }
            self.dismissalTask = nil
            self.scheduleNextAppearanceIfNeeded()
        }
    }

    private func cancelAndHide() {
        pendingTask?.cancel()
        pendingTask = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        isPresentationScheduled = false
        withAnimation(.easeInOut(duration: fadeDuration)) {
            visibleLetter = nil
        }
    }
}

struct AmbientLoveLetterOverlay: View {
    let isEnabled: Bool
    let isAppActive: Bool
    let isSuppressed: Bool
    let accentColor: Color

    @StateObject private var coordinator = AmbientLoveLetterCoordinator()

    var body: some View {
        GeometryReader { proxy in
            if let letter = coordinator.visibleLetter {
                Text(letter.message)
                    .font(.custom("SnellRoundhand", size: 26, relativeTo: .title2))
                    .foregroundStyle(accentColor.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: min(230, proxy.size.width * 0.56))
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                    .position(position(for: letter.position, in: proxy))
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: refresh)
        .onChange(of: isEnabled) { _, _ in refresh() }
        .onChange(of: isAppActive) { _, _ in refresh() }
        .onChange(of: isSuppressed) { _, _ in refresh() }
    }

    private func refresh() {
        coordinator.update(
            isEnabled: isEnabled,
            isAppActive: isAppActive,
            isSuppressed: isSuppressed
        )
    }

    private func position(
        for position: LoveLetterPosition,
        in proxy: GeometryProxy
    ) -> CGPoint {
        let xInset = min(125, proxy.size.width * 0.28)
        let top = proxy.safeAreaInsets.top + 105
        let middle = proxy.size.height * 0.43
        let lower = max(top + 80, proxy.size.height - 185)
        let left = xInset
        let right = proxy.size.width - xInset

        switch position {
        case .upperLeft: return CGPoint(x: left, y: top)
        case .upperRight: return CGPoint(x: right, y: top)
        case .middleLeft: return CGPoint(x: left, y: middle)
        case .middleRight: return CGPoint(x: right, y: middle)
        case .lowerLeft: return CGPoint(x: left, y: lower)
        case .lowerRight: return CGPoint(x: right, y: lower)
        }
    }
}
