import SwiftUI
import KanadeKit

enum SidebarItem: Hashable {
    case library, search, queue, nodes, settings
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var sidebarSelection: SidebarItem? = .library
    @State private var showNowPlaying = false
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
    }

    @ViewBuilder
    var connectedContent: some View {
        #if os(iOS)
        iosContent
            .overlay(alignment: .top) {
                remoteUnavailableBanner
            }
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
                    .safeAreaInset(edge: .top, spacing: 0) {
                        remoteUnavailableBanner
                    }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.shouldShowMiniPlayer {
                    NowPlayingBar(placement: .macFloating)
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

    @ViewBuilder
    var remoteUnavailableBanner: some View {
        if appState.showRemoteUnavailablePrompt {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("No remote nodes available.")
                    .font(.subheadline)
                Spacer()
                Button("Play on This Device") {
                    appState.switchToLocal(
                        tracks: appState.effectiveQueue,
                        index: appState.effectiveCurrentIndex ?? 0,
                        positionSecs: appState.effectiveTransportState?.positionSecs
                    )
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
