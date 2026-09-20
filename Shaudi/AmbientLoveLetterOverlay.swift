import Combine
import SwiftUI

enum LoveLetterPolicy {
    nonisolated static let minimumDelay: TimeInterval = 2.5 * 60
    nonisolated static let maximumDelay: TimeInterval = 6 * 60
    nonisolated static let fadeDuration: TimeInterval = 1
    nonisolated static let visibleDuration: TimeInterval = 5
}

enum LoveLetterScheduler {
    static let messages = [
        "you are my favorite person",
        "life without you would be ass lowkey",
        "if you see this screenshot it and ill send you $10",
        "huge ass on you ngl",
        "you're cool ig",
        "betray me, AND DIE!!!!!",
        "send toe pic please",
        "hey guess what? chicken butt",
        "don't forget to love me",
        "if I ever mess up, just know that no I didn't",
        "you fell for it pussyfart",
        "ok ok i love ya"
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
        isAppActive: Bool
    ) -> Bool {
        isEnabled && isAppActive && !messages.isEmpty
    }
}

@MainActor
final class AmbientLoveLetterCoordinator: ObservableObject {
    struct Letter: Identifiable {
        let id = UUID()
        let message: String
    }

    @Published private(set) var visibleLetter: Letter?
    private(set) var isPresentationScheduled = false

    private var lastMessageIndex: Int?
    private var pendingTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var isEnabled = true
    private var isAppActive = true
    private let delayProvider: () -> TimeInterval
    private let messageIndexProvider: (Int) -> Int
    private let fadeDuration: TimeInterval
    private let visibleDuration: TimeInterval

    init(
        delayProvider: @escaping () -> TimeInterval = {
            Double.random(in: LoveLetterPolicy.minimumDelay...LoveLetterPolicy.maximumDelay)
        },
        messageIndexProvider: @escaping (Int) -> Int = { Int.random(in: 0..<$0) },
        fadeDuration: TimeInterval = LoveLetterPolicy.fadeDuration,
        visibleDuration: TimeInterval = LoveLetterPolicy.visibleDuration
    ) {
        self.delayProvider = delayProvider
        self.messageIndexProvider = messageIndexProvider
        self.fadeDuration = fadeDuration
        self.visibleDuration = visibleDuration
    }

    func update(isEnabled: Bool, isAppActive: Bool) {
        self.isEnabled = isEnabled
        self.isAppActive = isAppActive

        guard LoveLetterScheduler.canSchedule(
            isEnabled: isEnabled,
            isAppActive: isAppActive
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
                isAppActive: isAppActive
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

        withAnimation(.easeInOut(duration: fadeDuration)) {
            visibleLetter = Letter(
                message: LoveLetterScheduler.messages[messageIndex]
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
    @ObservedObject var coordinator: AmbientLoveLetterCoordinator
    let isEnabled: Bool
    let isAppActive: Bool
    let accentColor: Color

    var body: some View {
        GeometryReader { proxy in
            if let letter = coordinator.visibleLetter {
                VStack {
                    loveLetterBanner(
                        letter,
                        maxWidth: min(340, proxy.size.width - 32)
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, proxy.safeAreaInsets.top + 10)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: refresh)
        .onChange(of: isEnabled) { _, _ in refresh() }
        .onChange(of: isAppActive) { _, _ in refresh() }
    }

    private func refresh() {
        coordinator.update(
            isEnabled: isEnabled,
            isAppActive: isAppActive
        )
    }

    private func loveLetterBanner(
        _ letter: AmbientLoveLetterCoordinator.Letter,
        maxWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Love Letter", systemImage: "heart.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.82))

            Text(letter.message)
                .font(.custom("SnellRoundhand", size: 23, relativeTo: .title3))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        .background(accentColor.opacity(0.22), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(accentColor.opacity(0.42), lineWidth: 1)
        }
        .shadow(color: accentColor.opacity(0.30), radius: 14, y: 5)
        .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
        .padding(.horizontal, 16)
    }
}
