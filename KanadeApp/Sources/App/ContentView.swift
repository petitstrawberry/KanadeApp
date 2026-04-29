import SwiftUI
import KanadeKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var sidebarSelection: SidebarItem? = .library(.albums)
    @State private var showNowPlaying = false
    @State private var showNodes = false
    @State private var showSettings = false

    private var shouldShowPlayerShell: Bool {
        appState.isConnected || appState.localPlayback != nil || appState.shouldShowMiniPlayer
    }

    var body: some View {
        Group {
            if shouldShowPlayerShell {
                connectedContent
            } else {
                ConnectionPrompt(onOpenSettings: { showSettings = true })
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environment(appState)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
        #endif
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
            .environment(appState)
        }
        .sheet(isPresented: $showNodes) {
            NavigationStack {
                NodesView()
            }
            .environment(appState)
        }
    }

    @ViewBuilder
    var connectedContent: some View {
        #if os(iOS)
        iosContent
            .overlay(alignment: .top) {
                connectionBanner
            }
        #else
        macContent
        #endif
    }

    @ViewBuilder
    var sidebarContent: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section("Library") {
                    ForEach(SidebarItem.allCases.filter(\.isLibrary), id: \.self) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
                #if os(iOS)
                Section {
                    NavigationLink {
                        SearchView()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                #endif
                Section {
                    #if os(macOS)
                    Label(SidebarItem.queue.title, systemImage: SidebarItem.queue.systemImage)
                        .tag(SidebarItem.queue)
                    #endif
                    Label(SidebarItem.nodes.title, systemImage: SidebarItem.nodes.systemImage)
                        .tag(SidebarItem.nodes)
                    Label(SidebarItem.settings.title, systemImage: SidebarItem.settings.systemImage)
                        .tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detailColumn
                .safeAreaInset(edge: .top, spacing: 0) {
                    connectionBanner
                }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.shouldShowMiniPlayer {
                    NowPlayingBar(placement: .macFloating, onActivate: {
                        #if os(iOS)
                        showNowPlaying = true
                        #endif
                    })
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    var detailColumn: some View {
        ZStack {
            librarySectionStacks
            nonLibraryDetailView
        }
    }

    private var activeLibrarySection: LibrarySection? {
        guard case .library(let section) = sidebarSelection else { return nil }
        return section
    }

    @ViewBuilder
    private var librarySectionStacks: some View {
        let active = activeLibrarySection

        if active == .albums {
            NavigationStack { AlbumsView() }
        } else if active == .artists {
            NavigationStack { ArtistsView() }
        } else if active == .genres {
            NavigationStack { GenresView() }
        } else if active == .playlists {
            NavigationStack { PlaylistsView() }
        }
    }

    @ViewBuilder
    private var nonLibraryDetailView: some View {
        switch sidebarSelection {
        case .queue:
            NavigationStack {
                QueueView()
            }
        case .nodes:
            NavigationStack {
                NodesView()
            }
        case .settings:
            NavigationStack {
                SettingsView()
            }
        case nil:
            NavigationStack {
                ContentUnavailableView("Select a section", systemImage: "sidebar.left")
            }
        case .library:
            EmptyView()
        }
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var iosContent: some View {
        Group {
            if horizontalSizeClass == .compact {
                iphoneContent
            } else {
                sidebarContent
            }
        }
    }

    var iphoneContent: some View {
        TabView {
            Tab(LibrarySection.albums.title, systemImage: LibrarySection.albums.systemImage) {
                NavigationStack {
                    AlbumsView()
                        .toolbar { iphoneGlobalToolbarItems }
                }
            }
            Tab(LibrarySection.artists.title, systemImage: LibrarySection.artists.systemImage) {
                NavigationStack {
                    ArtistsView()
                        .toolbar { iphoneGlobalToolbarItems }
                }
            }
            Tab(LibrarySection.genres.title, systemImage: LibrarySection.genres.systemImage) {
                NavigationStack {
                    GenresView()
                        .toolbar { iphoneGlobalToolbarItems }
                }
            }
            Tab(LibrarySection.playlists.title, systemImage: LibrarySection.playlists.systemImage) {
                NavigationStack {
                    PlaylistsView()
                        .toolbar { iphoneGlobalToolbarItems }
                }
            }
            Tab(role: .search) {
                NavigationStack {
                    SearchView()
                        .toolbar {
                            iphoneGlobalToolbarItems
                        }
                }
            }
        }
        .tabViewBottomAccessory {
            if appState.shouldShowMiniPlayer {
                Button {
                    showNowPlaying = true
                } label: {
                    NowPlayingBar(placement: .iosAccessory)
                }
                .buttonStyle(.plain)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    @ToolbarContentBuilder
    var iphoneGlobalToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showNodes = true
            } label: {
                Image(systemName: "speaker.wave.2")
            }
        }

        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }
    #endif

    #if os(macOS)
    var macContent: some View {
        sidebarContent
    }
    #endif

    @ViewBuilder
    var connectionBanner: some View {
        VStack(spacing: 0) {
            if appState.connectionRequiresManualRetry {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                    Text("Connection lost")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        appState.retryConnection()
                    } label: {
                        Text("Retry")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        appState.disconnect()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            } else if appState.isRetryingConnection {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reconnecting...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
            if appState.showRemoteUnavailablePrompt {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("No remote nodes available.")
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        appState.switchToLocal(
                            tracks: appState.effectiveQueue,
                            index: appState.effectiveCurrentIndex ?? 0,
                            positionSecs: appState.effectiveTransportState?.positionSecs
                        )
                    } label: {
                        Text("Play Locally")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        appState.showRemoteUnavailablePrompt = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}

struct ConnectionPrompt: View {
    @Environment(AppState.self) private var appState
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Connect to Kanade Server")
                .font(.title2.bold())
            Text(appState.hasSavedConnectionSettings ? "Reconnect to your saved Kanade server or update the connection settings." : "Enter your server address in Settings to get started")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if appState.hasSavedConnectionSettings {
                Button("Retry Connection") {
                    appState.retryConnection()
                }
                .buttonStyle(.bordered)
            }
            Button("Open Settings") {
                onOpenSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct AllSongsPlaceholderView: View, Identifiable {
    let id = UUID()

    var body: some View {
        ContentUnavailableView(
            "All Songs Coming Soon",
            systemImage: "music.note",
            description: Text("All Songs view isn't implemented yet.")
        )
    }
}
