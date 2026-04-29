import SwiftUI
import KanadeKit

enum SidebarItem: Hashable {
    case libraryAlbums, libraryArtists, libraryGenres
    case nodes, settings
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var sidebarSelection: SidebarItem? = .libraryAlbums
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
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environment(appState)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
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
                    Label("Albums", systemImage: "square.stack")
                        .tag(SidebarItem.libraryAlbums)
                    Label("Artists", systemImage: "music.mic")
                        .tag(SidebarItem.libraryArtists)
                    Label("Genres", systemImage: "music.note.list")
                        .tag(SidebarItem.libraryGenres)
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
                    Label("Nodes", systemImage: "speaker.wave.2")
                        .tag(SidebarItem.nodes)
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            NavigationStack {
                detailView
                    .safeAreaInset(edge: .top, spacing: 0) {
                        connectionBanner
                    }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.shouldShowMiniPlayer {
                    NowPlayingBar(placement: .iosAccessory)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    var detailView: some View {
        switch sidebarSelection {
        case .libraryAlbums:
            LibraryView(category: .albums)
        case .libraryArtists:
            LibraryView(category: .artists)
        case .libraryGenres:
            LibraryView(category: .genres)
        case .nodes:
            NodesView()
        case .settings:
            SettingsView()
        case nil:
            ContentUnavailableView("Select a section", systemImage: "sidebar.left")
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
            Tab("Albums", systemImage: "square.stack") {
                iphoneLibrarySection(category: .albums)
            }
            Tab("Artists", systemImage: "music.mic") {
                iphoneLibrarySection(category: .artists)
            }
            Tab("Genres", systemImage: "guitars") {
                iphoneLibrarySection(category: .genres)
            }
            Tab("Playlists", systemImage: "music.note.list") {
                iphonePlaceholderSection(title: "Playlists") {
                    PlaylistsPlaceholderView()
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

    func iphoneLibrarySection(category: LibraryCategory) -> some View {
        NavigationStack {
            LibraryView(category: category)
                .toolbar {
                    iphoneGlobalToolbarItems
                }
        }
    }

    func iphonePlaceholderSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    iphoneGlobalToolbarItems
                }
        }
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

struct PlaylistsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Playlists Coming Soon",
            systemImage: "music.note.list",
            description: Text("Playlist support isn’t implemented yet.")
        )
    }
}
