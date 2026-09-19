import SwiftUI

struct ShaudiWrappedView: View {
    private enum Page: Hashable {
        case intro
        case listeningTime
        case plays
        case songs
        case artists
        case genres
        case replay
        case personality
        case final
        case noData
    }

    @Environment(\.dismiss) private var dismiss

    private let entries: [ListeningHistoryEntry]
    private let tracks: [Track]
    private let now: Date
    private let calendar: Calendar

    @State private var period: WrappedPeriod
    @State private var summary: WrappedSummary
    @State private var selectedPage: Page = .intro

    init(
        entries: [ListeningHistoryEntry],
        tracks: [Track],
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.entries = entries
        self.tracks = tracks
        self.now = now
        self.calendar = calendar
        let initialPeriod = WrappedPeriod.thisYear
        _period = State(initialValue: initialPeriod)
        _summary = State(initialValue: WrappedStatsBuilder.build(
            entries: entries,
            tracks: tracks,
            period: initialPeriod,
            now: now,
            calendar: calendar
        ))
    }

    private var pages: [Page] {
        guard summary.hasData else {
            return [.intro, .noData]
        }
        var result: [Page] = [.intro, .listeningTime, .plays]
        if summary.topSong != nil {
            result.append(.songs)
        }
        if !summary.topArtists.isEmpty {
            result.append(.artists)
        }
        if !summary.favoriteGenres.isEmpty {
            result.append(.genres)
        }
        if summary.mostReplayedSong != nil {
            result.append(.replay)
        }
        if summary.personality != nil {
            result.append(.personality)
        }
        result.append(.final)
        return result
    }

    var body: some View {
        ZStack {
            pageBackground

            VStack(spacing: 0) {
                controls

                TabView(selection: $selectedPage) {
                    ForEach(pages, id: \.self) { page in
                        pageView(page)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                progressIndicator
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: period) { _, newPeriod in
            summary = WrappedStatsBuilder.build(
                entries: entries,
                tracks: tracks,
                period: newPeriod,
                now: now,
                calendar: calendar
            )
            selectedPage = .intro
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Wrapped period", selection: $period) {
                ForEach(WrappedPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 250)

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Shaudi Wrapped")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var progressIndicator: some View {
        HStack(spacing: 5) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                Capsule()
                    .fill(page == selectedPage ? .white : .white.opacity(0.24))
                    .frame(maxWidth: page == selectedPage ? 26 : 12)
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.2), value: selectedPage)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Page \((pages.firstIndex(of: selectedPage) ?? 0) + 1) of \(pages.count)"
        )
    }

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)

                switch page {
                case .intro:
                    introPage
                case .listeningTime:
                    listeningTimePage
                case .plays:
                    playsPage
                case .songs:
                    songsPage
                case .artists:
                    artistsPage
                case .genres:
                    genresPage
                case .replay:
                    replayPage
                case .personality:
                    personalityPage
                case .final:
                    finalPage
                case .noData:
                    noDataPage
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var introPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.88))
                .symbolEffect(.pulse, options: .repeating.speed(0.35))

            Text("Your Shaudi Wrapped")
                .font(ShaudiTheme.scriptFont(size: 48, relativeTo: .largeTitle))
                .multilineTextAlignment(.center)

            Text(summary.periodTitle)
                .font(ShaudiTheme.bodyFont(size: 21, relativeTo: .title3).weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))

            Text("A little portrait of the music you made time for.")
                .wrappedSupportingText()
                .padding(.top, 4)
        }
    }

    private var listeningTimePage: some View {
        VStack(spacing: 18) {
            pageKicker("TIME WELL SPENT")
            Text(durationHeadline(summary.totalListenedDuration))
                .wrappedHeroText()
            Text("of actual listening")
                .font(ShaudiTheme.scriptFont(size: 31, relativeTo: .title))
            Text("Only the seconds Shaudi recorded while your music was playing are counted.")
                .wrappedSupportingText()
        }
    }

    private var playsPage: some View {
        VStack(spacing: 18) {
            pageKicker("PRESS PLAY")
            Text(summary.playCount.formatted())
                .wrappedHeroText()
            Text(summary.playCount == 1 ? "listening session" : "listening sessions")
                .font(ShaudiTheme.scriptFont(size: 31, relativeTo: .title))
                .multilineTextAlignment(.center)
            Text("Every count began with confirmed playback in Shaudi.")
                .wrappedSupportingText()
        }
    }

    private var songsPage: some View {
        VStack(spacing: 20) {
            pageKicker("YOUR #1 SONG")

            if let topSong = summary.topSong {
                WrappedArtwork(url: topSong.artworkURL, size: 184)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 14)

                VStack(spacing: 6) {
                    Text(topSong.title)
                        .font(ShaudiTheme.bodyFont(size: 29, relativeTo: .title).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(topSong.artist)
                        .font(ShaudiTheme.bodyFont(size: 18, relativeTo: .headline))
                        .foregroundStyle(.white.opacity(0.72))
                    Text("\(formattedDuration(topSong.listenedDuration)) • \(playText(topSong.playCount))")
                        .font(ShaudiTheme.bodyFont(size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            if summary.topSongs.count > 1 {
                rankedList(summary.topSongs) { song in
                    (song.title, song.artist, formattedDuration(song.listenedDuration))
                }
            }
        }
    }

    private var artistsPage: some View {
        VStack(spacing: 20) {
            pageKicker("TOP ARTIST")
            if let artist = summary.topArtist {
                Text(artist.displayArtist)
                    .wrappedHeroText(maximumSize: 48)
                Text("\(formattedDuration(artist.listenedDuration)) • \(listenText(artist.eventCount))")
                    .wrappedSupportingText()
            }

            rankedList(summary.topArtists) { artist in
                (
                    artist.displayArtist,
                    listenText(artist.eventCount),
                    formattedDuration(artist.listenedDuration)
                )
            }
        }
    }

    private var genresPage: some View {
        VStack(spacing: 20) {
            pageKicker("FAVORITE GENRE")
            if let genre = summary.favoriteGenre {
                Text(genre.name)
                    .wrappedHeroText(maximumSize: 52)
                Text("\(genre.percentage)% of your genre-tagged listening")
                    .wrappedSupportingText()
            }

            VStack(spacing: 14) {
                ForEach(summary.favoriteGenres) { genre in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(genre.name).fontWeight(.semibold)
                            Spacer()
                            Text("\(genre.percentage)%")
                        }
                        Capsule()
                            .fill(.white.opacity(0.18))
                            .frame(height: 7)
                            .overlay(alignment: .leading) {
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(.white)
                                        .frame(
                                            width: proxy.size.width
                                                * CGFloat(genre.percentage) / 100
                                        )
                                }
                            }
                    }
                }
            }
            .wrappedPanel()
        }
    }

    private var replayPage: some View {
        VStack(spacing: 20) {
            pageKicker("ONE MORE TIME")
            if let song = summary.mostReplayedSong {
                WrappedArtwork(url: song.artworkURL, size: 160)
                Text(song.title)
                    .wrappedHeroText(maximumSize: 42)
                Text(song.artist)
                    .font(ShaudiTheme.bodyFont(size: 18, relativeTo: .headline))
                    .foregroundStyle(.white.opacity(0.74))
                Text("You came back \(song.playCount) times.")
                    .wrappedSupportingText()
            }
        }
    }

    private var personalityPage: some View {
        VStack(spacing: 20) {
            pageKicker("YOUR LISTENING PERSONALITY")
            if let personality = summary.personality {
                Image(systemName: personalitySymbol(personality))
                    .font(.system(size: 54, weight: .light))
                    .padding(.bottom, 4)
                Text(personality.title)
                    .font(ShaudiTheme.scriptFont(size: 46, relativeTo: .largeTitle))
                    .multilineTextAlignment(.center)
                Text(personality.detail)
                    .wrappedSupportingText()
            }
        }
    }

    private var finalPage: some View {
        VStack(spacing: 18) {
            pageKicker("THAT WAS YOUR \(summary.periodTitle.uppercased())")
            Text("Shaudi Wrapped")
                .font(ShaudiTheme.scriptFont(size: 42, relativeTo: .largeTitle))

            VStack(spacing: 14) {
                summaryLine("Listening", durationHeadline(summary.totalListenedDuration))
                summaryLine("Plays", summary.playCount.formatted())
                if let song = summary.topSong {
                    summaryLine("Top song", song.title)
                }
                if let artist = summary.topArtist {
                    summaryLine("Top artist", artist.displayArtist)
                }
                if let genre = summary.favoriteGenre {
                    summaryLine("Favorite genre", genre.name)
                }
            }
            .wrappedPanel()

            Text("made with all my love, for you.")
                .font(ShaudiTheme.scriptFont(size: 25, relativeTo: .title3))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
    }

    private var noDataPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48, weight: .light))
            Text("Your story is just getting started.")
                .font(ShaudiTheme.scriptFont(size: 40, relativeTo: .largeTitle))
                .multilineTextAlignment(.center)
            Text("Keep listening in Shaudi and your real recap will take shape here.")
                .wrappedSupportingText()
        }
    }

    private var pageBackground: some View {
        let index = pages.firstIndex(of: selectedPage) ?? 0
        return ZStack {
            LinearGradient(
                colors: backgroundColors(index: index),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(.white.opacity(0.07))
                .frame(width: 320, height: 320)
                .blur(radius: 2)
                .offset(x: 150, y: -280)

            Circle()
                .fill(Color.pink.opacity(0.10))
                .frame(width: 260, height: 260)
                .offset(x: -160, y: 330)
        }
        .animation(.easeInOut(duration: 0.35), value: selectedPage)
    }

    private func backgroundColors(index: Int) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.12, green: 0.05, blue: 0.18), Color(red: 0.43, green: 0.12, blue: 0.34)],
            [Color(red: 0.08, green: 0.05, blue: 0.16), Color(red: 0.25, green: 0.15, blue: 0.48)],
            [Color(red: 0.20, green: 0.06, blue: 0.19), Color(red: 0.53, green: 0.15, blue: 0.31)],
            [Color(red: 0.08, green: 0.08, blue: 0.16), Color(red: 0.33, green: 0.12, blue: 0.40)]
        ]
        return palettes[index % palettes.count]
    }

    private func pageKicker(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(2.1)
            .foregroundStyle(.white.opacity(0.68))
            .multilineTextAlignment(.center)
    }

    private func rankedList<Item: Identifiable>(
        _ items: [Item],
        content: @escaping (Item) -> (title: String, subtitle: String, detail: String)
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let values = content(item)
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(values.title)
                            .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .headline).weight(.semibold))
                            .lineLimit(1)
                        Text(values.subtitle)
                            .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption))
                            .foregroundStyle(.white.opacity(0.64))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(values.detail)
                        .font(ShaudiTheme.bodyFont(size: 13, relativeTo: .caption).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.76))
                }
                .padding(.vertical, 10)

                if index < items.count - 1 {
                    Divider().overlay(.white.opacity(0.10))
                }
            }
        }
        .wrappedPanel()
    }

    private func summaryLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.white.opacity(0.64))
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(ShaudiTheme.bodyFont(size: 16, relativeTo: .body))
    }

    private func durationHeadline(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func playText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "play" : "plays")"
    }

    private func listenText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "listen" : "listens")"
    }

    private func personalitySymbol(_ personality: WrappedPersonality) -> String {
        switch personality {
        case .explorer: "safari"
        case .loyalist: "heart.circle"
        case .repeatOffender: "repeat.circle"
        case .deepListener: "waveform.circle"
        }
    }
}

private struct WrappedArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [.white.opacity(0.16), .white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.24, weight: .light))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

private extension View {
    func wrappedHeroText(maximumSize: CGFloat = 62) -> some View {
        font(.system(size: maximumSize, weight: .black, design: .rounded))
            .minimumScaleFactor(0.55)
            .lineLimit(3)
            .multilineTextAlignment(.center)
    }

    func wrappedSupportingText() -> some View {
        font(ShaudiTheme.bodyFont(size: 17, relativeTo: .body))
            .foregroundStyle(.white.opacity(0.74))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
    }

    func wrappedPanel() -> some View {
        padding(16)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}
