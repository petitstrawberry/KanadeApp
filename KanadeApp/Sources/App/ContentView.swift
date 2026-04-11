import SwiftUI
import KanadeKit

enum SidebarItem: Hashable {
    case library, search, queue, nodes, settings
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var sidebarSelection: SidebarItem? = .library
    @State private var showNowPlaying = false

    private var shouldShowPlayerShell: Bool {
        appState.isConnected || appState.playbackMode == .local || appState.shouldShowMiniPlayer
    }

    var body: some View {
        Group {
            if shouldShowPlayerShell {
                connectedContent
            } else {
                ConnectionPrompt()
            }
        }
    }

    @ViewBuilder
    var connectedContent: some View {
        #if os(iOS)
        iosContent
        #else
        macContent
        #endif
    }

    #if os(iOS)
    var iosContent: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") {
                NavigationStack {
                    LibraryView()
                }
            }
            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack {
                    SearchView()
                }
            }
            Tab("Queue", systemImage: "list.bullet") {
                NavigationStack {
                    QueueView()
                }
            }
            Tab("Nodes", systemImage: "speaker.wave.2") {
                NavigationStack {
                    NodesView()
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewBottomAccessory {
            if appState.shouldShowMiniPlayer {
                NowPlayingBar(placement: .iosAccessory)
                    .onTapGesture {
                        showNowPlaying = true
                    }
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
    #endif

    #if os(macOS)
    var macContent: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("Library", systemImage: "square.stack")
                    .tag(SidebarItem.library)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("Queue", systemImage: "list.bullet")
                    .tag(SidebarItem.queue)
                Label("Nodes", systemImage: "speaker.wave.2")
                    .tag(SidebarItem.nodes)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            NavigationStack {
                detailView
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.shouldShowMiniPlayer {
                    HStack {
                        Spacer(minLength: 0)
                        NowPlayingBar(placement: .macFloating)
                            .frame(maxWidth: 900)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    @ViewBuilder
    var detailView: some View {
        switch sidebarSelection {
        case .library:
            LibraryView()
        case .search:
            SearchView()
        case .queue:
            QueueView()
        case .nodes:
            NodesView()
        case .settings:
            SettingsView()
        case nil:
            ContentUnavailableView("Select a section", systemImage: "sidebar.left")
        }
    }
    #endif
}

struct ConnectionPrompt: View {
    @Environment(AppState.self) private var appState
    @State private var showSettings = false

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
                showSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
    }
}
