import SwiftUI
import StoreKit
import Domain

/// Where a route points inside the library. Session and sheet both address a song by id
/// (not by value) so a pushed screen always reads the freshest stored copy rather than a
/// snapshot captured at push time.
enum SongRoute: Hashable {
    case session(UUID)
    case sheet(UUID)
}

/// The app's home (docs/ARCHITECTURE.md §6): the list of saved songs, plus the entry points
/// to start a new one, reopen one to keep writing, or read the finished sheet. Owns the
/// `NavigationStack` and routing for the whole library flow.
struct SongListView: View {
    let services: AppServices
    /// `nil` = unmetered (previews, Mac validation builds without a store).
    let proStore: ProStore?

    @State private var viewModel: SongListViewModel
    @State private var path: [SongRoute] = []
    @State private var showsNewSongAlert = false
    @State private var newTitle = ""
    @State private var showsDiagnostics = false
    @State private var showsPaywall = false
    @Environment(\.requestReview) private var requestReview
    /// How many `QuickActions` session requests this view has already acted on — the
    /// counter comparison (not a Bool) means a request that arrives before `.task` runs
    /// on cold launch is still consumed, and rapid double-invocations both fire.
    @State private var consumedSessionRequests = 0

    init(services: AppServices, proStore: ProStore? = nil) {
        self.services = services
        self.proStore = proStore
        _viewModel = State(initialValue: SongListViewModel(store: services.store))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Songs")
                .toolbar { toolbarContent }
                .navigationDestination(for: SongRoute.self) { route in
                    destination(for: route)
                }
        }
        .task {
            await viewModel.load()
            consumeQuickActionRequests()
        }
        .onChange(of: QuickActions.shared.pendingSessionRequests) { _, _ in
            consumeQuickActionRequests()
        }
        .onChange(of: path) { _, newPath in
            // Returning to the root means a session may have just persisted new lines —
            // refresh so row line-counts and ordering reflect the latest writes.
            if newPath.isEmpty {
                Task {
                    await viewModel.load()
                    maybeRequestReview()
                }
            }
        }
        .alert("New Song", isPresented: $showsNewSongAlert) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) { newTitle = "" }
            Button("Start Writing") { startNewSong() }
        } message: {
            Text("Name your song, then sing or play a phrase to get lyric ideas.")
        }
        .sheet(isPresented: $showsPaywall) {
            if let proStore {
                PaywallView(store: proStore)
            }
        }
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticCaptureView(services: services)
                // Plain macOS sheets have no built-in close affordance — mirror RootView's
                // manual dismiss overlay so there's always a way out.
                .overlay(alignment: .topTrailing) {
                    Button {
                        showsDiagnostics = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.loadError, viewModel.songs.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Songs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await viewModel.load() } }
            }
        } else if viewModel.songs.isEmpty {
            ContentUnavailableView {
                Label("No Songs Yet", systemImage: "music.mic")
            } description: {
                Text("Start a song, then hum, sing, or play a phrase — you'll get lyric lines that match its rhythm.")
            } actions: {
                Button("New Song") { presentNewSong() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            songList
        }
    }

    private var songList: some View {
        List {
            ForEach(viewModel.songs) { song in
                NavigationLink(value: SongRoute.sheet(song.id)) {
                    SongRow(song: song)
                }
            }
            .onDelete { offsets in
                Task { await viewModel.delete(at: offsets) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                presentNewSong()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New song")
        }
        if let proStore, !proStore.isPro {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showsPaywall = true
                } label: {
                    Label("Song Finisher Pro", systemImage: "sparkles")
                }
                .accessibilityLabel("Song Finisher Pro upgrade")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button {
                showsDiagnostics = true
            } label: {
                Label("DSP Diagnostics", systemImage: "waveform.path.ecg")
            }
            .accessibilityLabel("DSP diagnostic tool")
        }
    }

    @ViewBuilder
    private func destination(for route: SongRoute) -> some View {
        switch route {
        case .session(let id):
            SessionView(
                services: services,
                songID: id,
                songTitle: viewModel.song(id)?.title,
                initialMemory: viewModel.song(id)?.memory ?? SessionMemory(),
                proStore: proStore
            )
        case .sheet(let id):
            SongSheetView(song: viewModel.song(id)) {
                path.append(.session(id))
            }
        }
    }

    private func presentNewSong() {
        newTitle = ""
        showsNewSongAlert = true
    }

    private func startNewSong() {
        let title = newTitle
        newTitle = ""
        Task {
            if let song = await viewModel.createSong(title: title) {
                path.append(.session(song.id))
            }
        }
    }

    /// One-shot rating ask, at the moment of earned goodwill: the writer just came back
    /// from a session and their library holds five-plus kept lines. Never asked again —
    /// the system throttles further; the flag stops even the first re-ask.
    private func maybeRequestReview() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasRequestedReview") else { return }
        let totalLines = viewModel.songs.reduce(0) { $0 + $1.lines.count }
        guard totalLines >= 5 else { return }
        defaults.set(true, forKey: "hasRequestedReview")
        requestReview()
    }

    /// Acts on "Start a Writing Session" App Intent invocations (Siri / Shortcuts /
    /// Spotlight): create a dated song and jump straight into listening.
    private func consumeQuickActionRequests() {
        let pending = QuickActions.shared.pendingSessionRequests
        guard pending > consumedSessionRequests else { return }
        consumedSessionRequests = pending
        let title = "Session — \(Date().formatted(date: .abbreviated, time: .shortened))"
        Task {
            if let song = await viewModel.createSong(title: title) {
                path = [.session(song.id)]
            }
        }
    }
}

/// One row in the library list: title, how much has been written, and when it last changed.
private struct SongRow: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(lineCountLabel)
                Text("·")
                Text(song.updatedAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var lineCountLabel: String {
        let count = song.lines.count
        return count == 1 ? "1 line" : "\(count) lines"
    }
}

#Preview("Populated") {
    SongListView(services: .fakes(store: FakeSongStore(seed: [
        Song(
            title: "Midnight Draft",
            createdAt: Date(),
            updatedAt: Date(),
            lines: [
                LyricLine(phraseID: UUID(), text: "all the miles between us", stressMap: StressMap(pattern: [.strong, .weak]), emotion: .longing, acceptedAt: Date()),
                LyricLine(phraseID: UUID(), text: "fade to something less", stressMap: StressMap(pattern: [.strong, .weak]), emotion: .melancholy, acceptedAt: Date()),
            ]
        ),
        Song(title: "Empty One", createdAt: Date(), updatedAt: Date().addingTimeInterval(-3600)),
    ])))
}

#Preview("Empty") {
    SongListView(services: .fakes())
}
