import SwiftUI
import KanadeKit

struct NowPlayingBar: View {
    @Environment(AppState.self) private var appState

    @State private var isShowingNowPlaying = false
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false

    private var client: KanadeClient? { appState.client }
    private var playbackState: PlaybackState? { client?.state }

    private var currentTrack: Track? {
        guard let playbackState,
              let currentIndex = playbackState.currentIndex,
              playbackState.queue.indices.contains(currentIndex) else {
            return nil
        }

        return playbackState.queue[currentIndex]
    }

    private var currentNode: Node? {
        guard let playbackState else { return nil }

        if let selectedNodeId = playbackState.selectedNodeId,
           let selectedNode = playbackState.nodes.first(where: { $0.id == selectedNodeId }) {
            return selectedNode
        }

        return playbackState.nodes.first(where: \.connected) ?? playbackState.nodes.first
    }

    private var isPlaying: Bool {
        currentNode?.status == .playing
    }

    private var currentPosition: Double {
        currentNode?.positionSecs ?? 0
    }

    private var currentVolume: Double {
        Double(currentNode?.volume ?? 0)
    }

    private var sliderDuration: Double {
        max(currentTrack?.durationSecs ?? 0, 1)
    }

    private var repeatMode: RepeatMode {
        playbackState?.repeatMode ?? .off
    }

    private var shuffleEnabled: Bool {
        playbackState?.shuffle ?? false
    }

    var body: some View {
        Group {
            if let currentTrack {
                barContent(currentTrack: currentTrack)
            }
        }
        #if os(macOS)
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView()
                .frame(minWidth: 520, minHeight: 400)
        }
        #endif
        .onAppear {
            syncSeekPosition()
        }
        .onChange(of: currentTrack?.id) {
            syncSeekPosition()
        }
        .onChange(of: currentPosition) {
            if !isSeeking {
                syncSeekPosition()
            }
        }
    }

    private func barContent(currentTrack: Track) -> some View {
        ViewThatFits(in: .horizontal) {
            fullContent(currentTrack: currentTrack)
                .frame(minWidth: 768)

            compactContent(currentTrack: currentTrack)
        }
        .background(.ultraThinMaterial)
        .background(Color.primary.opacity(0.0001))
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func compactContent(currentTrack: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(mediaClient: appState.mediaClient, albumId: currentTrack.albumId)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrack.title ?? "Untitled")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(currentTrack.artist ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout)
                    .frame(width: 32, height: 32)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 60)
    }

    private func fullContent(currentTrack: Track) -> some View {
        HStack(spacing: 16) {
            leftColumn(currentTrack: currentTrack)
            centerColumn
            rightColumn
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }

    private func leftColumn(currentTrack: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(mediaClient: appState.mediaClient, albumId: currentTrack.albumId)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrack.title ?? "Untitled")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)

                Text(currentTrack.artist ?? "Unknown Artist")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            #if os(macOS)
            isShowingNowPlaying = true
            #endif
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 6) {
            HStack(spacing: 20) {
                Button {
                    client?.setShuffle(!shuffleEnabled)
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 14))
                        .foregroundStyle(shuffleEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

                Button {
                    client?.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())

                Button {
                    client?.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

                Button {
                    client?.setRepeat(nextRepeatMode)
                } label: {
                    Image(systemName: repeatSymbolName)
                        .font(.system(size: 14))
                        .foregroundStyle(repeatMode != .off ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }

            HStack(spacing: 8) {
                Text(formatTime(seekPosition))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * seekProgress)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let progress = value.location.x / geo.size.width
                                    seekPosition = min(max(progress * sliderDuration, 0), sliderDuration)
                                    isSeeking = true
                                }
                                .onEnded { _ in
                                    client?.seek(to: seekPosition)
                                    isSeeking = false
                                }
                        )
                }
                .frame(height: 4)

                Text(formatTime(sliderDuration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var rightColumn: some View {
        HStack(spacing: 12) {
            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * (currentVolume / 100))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let vol = (value.location.x / geo.size.width) * 100
                                    client?.setVolume(Int(min(max(vol, 0), 100).rounded()))
                                }
                        )
                }
                .frame(width: 80, height: 4)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var seekProgress: CGFloat {
        guard sliderDuration > 0 else { return 0 }
        return min(seekPosition / sliderDuration, 1.0)
    }

    private var nextRepeatMode: RepeatMode {
        switch repeatMode {
        case .off: return .one
        case .one: return .all
        case .all: return .off
        }
    }

    private var repeatSymbolName: String {
        switch repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func togglePlayback() {
        if isPlaying {
            client?.pause()
        } else {
            client?.play()
        }
    }

    private func syncSeekPosition() {
        seekPosition = min(currentPosition, sliderDuration)
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
