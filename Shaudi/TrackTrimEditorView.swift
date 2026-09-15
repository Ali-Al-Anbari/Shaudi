import SwiftUI

struct TrackTrimEditorView: View {
    private enum TimelineControl: Equatable {
        case start
        case playhead
        case end
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playbackManager: PlaybackManager

    let track: Track

    @State private var proposedStartTime: TimeInterval
    @State private var proposedEndTime: TimeInterval
    @State private var currentPreviewTime: TimeInterval
    @State private var activeControl: TimelineControl?
    @State private var dragStartTime: TimeInterval?

    private let minimumTrimDuration: TimeInterval = 1

    init(track: Track) {
        self.track = track

        let duration = track.duration?.isFinite == true ? max(0, track.duration ?? 0) : 0
        let startTime = track.playbackStartTime ?? 0
        let endTime = track.playbackEndTime ?? duration
        let isValidRange = startTime >= 0
            && startTime < endTime
            && endTime <= duration
        let initialStart = isValidRange ? startTime : 0
        let initialEnd = isValidRange ? endTime : duration

        _proposedStartTime = State(initialValue: initialStart)
        _proposedEndTime = State(initialValue: initialEnd)
        _currentPreviewTime = State(initialValue: initialStart)
    }

    private var authoritativeDuration: TimeInterval? {
        guard let duration = track.duration, duration.isFinite, duration > minimumTrimDuration else {
            return nil
        }

        return duration
    }

    private var isPreviewPlaying: Bool {
        guard playbackManager.isTrimPreviewing(track) else {
            return false
        }

        if case .playing = playbackManager.state {
            return true
        }

        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                if let authoritativeDuration {
                    editor(for: authoritativeDuration)
                } else {
                    ContentUnavailableView(
                        "Duration Unavailable",
                        systemImage: "clock.badge.exclamationmark",
                        description: Text("Refresh this track's metadata before trimming it.")
                    )
                }
            }
            .background(ShaudiTheme.dashboardBackground)
            .tint(ShaudiTheme.accent)
            .navigationTitle("Trim Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        playbackManager.endTrimPreview(for: track)
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTrim()
                    }
                    .disabled(authoritativeDuration == nil)
                }
            }
        }
        .onDisappear {
            playbackManager.endTrimPreview(for: track)
        }
        .onReceive(playbackManager.$trimPreviewTime) { playbackTime in
            guard
                activeControl != .playhead,
                playbackManager.isTrimPreviewing(track),
                let playbackTime
            else {
                return
            }

            currentPreviewTime = clamped(
                playbackTime,
                lowerBound: proposedStartTime,
                upperBound: proposedEndTime
            )
        }
    }

    private func editor(for duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(track.displayTitle)
                .font(ShaudiTheme.scriptFont(size: 30, relativeTo: .title))
                .foregroundStyle(ShaudiTheme.accent)
                .lineLimit(2)

            Text("Choose the part of the song that Shaudi should play.")
                .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)

            timestampLabels

            timeline(for: duration)

            HStack(spacing: 12) {
                Button {
                    resetTrim(for: duration)
                } label: {
                    Label("Reset Trim", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    togglePreview()
                } label: {
                    Label(
                        isPreviewPlaying ? "Pause Preview" : "Play Preview",
                        systemImage: isPreviewPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(ShaudiTheme.accent)
            }

            Text("Drag the purple handles to choose the start and end. Drag the circle to preview a point in the selected range.")
                .font(ShaudiTheme.bodyFont(size: 14, relativeTo: .footnote))
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)

            Spacer()
        }
        .padding(20)
    }

    private var timestampLabels: some View {
        HStack {
            timestampLabel("Start", time: proposedStartTime, alignment: .leading)
            Spacer()
            timestampLabel("Playhead", time: currentPreviewTime, alignment: .center)
            Spacer()
            timestampLabel("End", time: proposedEndTime, alignment: .trailing)
        }
    }

    private func timestampLabel(
        _ title: String,
        time: TimeInterval,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title.uppercased())
                .font(ShaudiTheme.bodyFont(size: 12, relativeTo: .caption).weight(.semibold))
                .foregroundStyle(ShaudiTheme.dashboardSecondaryText)
            Text(YouTubeDuration.formatted(time))
                .font(ShaudiTheme.bodyFont(size: 17, relativeTo: .headline).monospacedDigit())
                .foregroundStyle(ShaudiTheme.dashboardPrimaryText)
        }
    }

    private func timeline(for duration: TimeInterval) -> some View {
        GeometryReader { geometry in
            let horizontalInset: CGFloat = 22
            let timelineWidth = max(1, geometry.size.width - (horizontalInset * 2))
            let trackY: CGFloat = 64
            let playheadY: CGFloat = 22
            let trimHandleY: CGFloat = 72
            let startX = horizontalInset + position(
                for: proposedStartTime,
                width: timelineWidth,
                duration: duration
            )
            let endX = horizontalInset + position(
                for: proposedEndTime,
                width: timelineWidth,
                duration: duration
            )
            let playheadX = horizontalInset + position(
                for: currentPreviewTime,
                width: timelineWidth,
                duration: duration
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ShaudiTheme.dashboardPlaceholder)
                    .frame(width: timelineWidth, height: 12)
                    .position(x: horizontalInset + (timelineWidth / 2), y: trackY)
                    .allowsHitTesting(false)

                Capsule()
                    .fill(ShaudiTheme.accent.opacity(0.78))
                    .frame(width: max(0, endX - startX), height: 12)
                    .position(x: (startX + endX) / 2, y: trackY)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(.black.opacity(0.33))
                    .frame(width: max(0, startX - horizontalInset), height: 12)
                    .position(x: (horizontalInset + startX) / 2, y: trackY)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(.black.opacity(0.33))
                    .frame(
                        width: max(0, (horizontalInset + timelineWidth) - endX),
                        height: 12
                    )
                    .position(x: (endX + horizontalInset + timelineWidth) / 2, y: trackY)
                    .allowsHitTesting(false)

                trimHandle(color: ShaudiTheme.lavender)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
                    .position(x: startX, y: trimHandleY)
                    .gesture(handleDrag(.start, width: timelineWidth, duration: duration))
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(YouTubeDuration.formatted(proposedStartTime))
                    .zIndex(1)

                playheadHandle(trackY: trackY, playheadY: playheadY)
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
                    .position(x: playheadX, y: playheadY)
                    .gesture(handleDrag(.playhead, width: timelineWidth, duration: duration))
                    .accessibilityLabel("Preview playhead")
                    .accessibilityValue(YouTubeDuration.formatted(currentPreviewTime))
                    .zIndex(2)

                trimHandle(color: ShaudiTheme.lavender)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
                    .position(x: endX, y: trimHandleY)
                    .gesture(handleDrag(.end, width: timelineWidth, duration: duration))
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(YouTubeDuration.formatted(proposedEndTime))
                    .zIndex(1)
            }
        }
        .frame(height: 96)
        .background(
            ShaudiTheme.dashboardCard,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func trimHandle(color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 12, height: 42)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.65), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.45), radius: 4)
    }

    private func playheadHandle(trackY: CGFloat, playheadY: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(ShaudiTheme.accent)
                .frame(width: 2, height: max(0, trackY - playheadY))
                .offset(y: (trackY - playheadY) / 2)

            Circle()
                .fill(ShaudiTheme.accent)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.85), lineWidth: 2)
                }
                .shadow(color: ShaudiTheme.accent.opacity(0.5), radius: 4)
                .offset(y: -10)
        }
    }

    private func handleDrag(
        _ control: TimelineControl,
        width: CGFloat,
        duration: TimeInterval
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                activeControl = control
                if dragStartTime == nil {
                    dragStartTime = time(for: control)
                }

                let time = (dragStartTime ?? 0)
                    + (duration * TimeInterval(value.translation.width / width))

                switch control {
                case .start:
                    proposedStartTime = max(
                        0,
                        min(time, proposedEndTime - minimumTrimDuration)
                    )
                    currentPreviewTime = max(currentPreviewTime, proposedStartTime)
                case .playhead:
                    currentPreviewTime = clamped(
                        time,
                        lowerBound: proposedStartTime,
                        upperBound: proposedEndTime
                    )
                case .end:
                    proposedEndTime = min(
                        duration,
                        max(time, proposedStartTime + minimumTrimDuration)
                    )
                    currentPreviewTime = min(currentPreviewTime, proposedEndTime)
                }
            }
            .onEnded { _ in
                activeControl = nil
                dragStartTime = nil

                switch control {
                case .playhead:
                    playbackManager.seekTrimPreview(
                        for: track,
                        to: currentPreviewTime
                    )
                case .start, .end:
                    playbackManager.updateTrimPreviewRange(
                        for: track,
                        startTime: proposedStartTime,
                        endTime: proposedEndTime
                    )
                }
            }
    }

    private func togglePreview() {
        if isPreviewPlaying {
            playbackManager.pauseTrimPreview(for: track)
        } else if playbackManager.isTrimPreviewing(track) {
            playbackManager.resumeTrimPreview(for: track)
        } else {
            playbackManager.beginTrimPreview(
                track,
                startTime: proposedStartTime,
                endTime: proposedEndTime,
                previewTime: currentPreviewTime
            )
        }
    }

    private func resetTrim(for duration: TimeInterval) {
        proposedStartTime = 0
        proposedEndTime = duration
        currentPreviewTime = 0
        playbackManager.updateTrimPreviewRange(
            for: track,
            startTime: proposedStartTime,
            endTime: proposedEndTime
        )
    }

    private func saveTrim() {
        guard let duration = authoritativeDuration else {
            return
        }

        track.playbackStartTime = proposedStartTime <= 0.001 ? nil : proposedStartTime
        track.playbackEndTime = abs(proposedEndTime - duration) <= 0.001 ? nil : proposedEndTime
        playbackManager.endTrimPreview(for: track)
        dismiss()
    }

    private func position(for time: TimeInterval, width: CGFloat, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else {
            return 0
        }

        return width * CGFloat(time / duration)
    }

    private func time(for control: TimelineControl) -> TimeInterval {
        switch control {
        case .start:
            proposedStartTime
        case .playhead:
            currentPreviewTime
        case .end:
            proposedEndTime
        }
    }

    private func clamped(
        _ value: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        min(max(value, lowerBound), upperBound)
    }
}
