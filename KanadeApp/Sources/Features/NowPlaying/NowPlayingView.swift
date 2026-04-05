import SwiftUI
import KanadeKit
import Foundation

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var seekPosition: Double = 0
    @State private var volumeValue: Double = 0
    @State private var isSeeking = false
    @State private var isAdjustingVolume = false

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

    private var currentPosition: Double {
        currentNode?.positionSecs ?? 0
    }

    private var currentVolume: Double {
        Double(currentNode?.volume ?? 0)
    }

    private var playbackStatus: PlaybackStatus {
        currentNode?.status ?? .stopped
    }

    private var repeatMode: RepeatMode {
        playbackState?.repeatMode ?? .off
    }

    private var shuffleEnabled: Bool {
        playbackState?.shuffle ?? false
    }

    var body: some View {
        HStack(spacing: 24) {
            artworkColumn
            infoAndControls
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundView)
        .navigationBarBackButtonHidden()
        .onAppear {
            syncSeekPosition()
            syncVolumeValue()
        }
        .onChange(of: currentTrack?.id) {
            syncSeekPosition()
        }
        .onChange(of: currentPosition) {
            if !isSeeking {
                syncSeekPosition()
            }
        }
        .onChange(of: currentVolume) {
            if !isAdjustingVolume {
                syncVolumeValue()
            }
        }
        .onChange(of: volumeValue) {
            if isAdjustingVolume {
                client?.setVolume(Int(volumeValue.rounded()))
            }
        }
    }

    private var artworkColumn: some View {
        VStack {
            Spacer()
            if let currentTrack {
                ArtworkView(mediaClient: appState.mediaClient, albumId: currentTrack.albumId)
                    .frame(width: 280, height: 280)
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.quaternary)
                    .frame(width: 280, height: 280)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(.secondary)
                    }
            }
            Spacer()
        }
        .frame(width: 320)
    }

    private var infoAndControls: some View {
        VStack(spacing: 20) {
            Spacer()

            trackInfo

            progressSection

            controlsSection

            transportOptionsSection

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var trackInfo: some View {
        VStack(spacing: 6) {
            Text(currentTrack?.title ?? "Nothing Playing")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text(currentTrack?.artist ?? "Unknown Artist")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(currentTrack?.albumTitle ?? "Unknown Album")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progressSection: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { seekPosition },
                    set: { seekPosition = $0 }
                ),
                in: 0...sliderDuration,
                onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing {
                        client?.seek(to: seekPosition)
                    }
                }
            )
            .disabled(currentTrack == nil)

            HStack {
                Text(formatTime(seekPosition))
                Spacer()
                Text(formatTime(sliderDuration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controlsSection: some View {
        HStack(spacing: 26) {
            Button {
                client?.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(currentTrack == nil)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: playbackStatus == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)
            .disabled(currentTrack == nil)

            Button {
                client?.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(currentTrack == nil)
        }
        .foregroundStyle(.primary)
    }

    private var transportOptionsSection: some View {
        HStack(spacing: 16) {
            Button {
                client?.setShuffle(!shuffleEnabled)
            } label: {
                Image(systemName: "shuffle")
                    .font(.headline)
                    .foregroundStyle(shuffleEnabled ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(shuffleEnabled ? .regularMaterial : .thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                client?.setRepeat(nextRepeatMode)
            } label: {
                Image(systemName: repeatSymbolName)
                    .font(.headline)
                    .foregroundStyle(repeatMode == .off ? .secondary : .primary)
                    .frame(width: 36, height: 36)
                    .background(repeatMode == .off ? .thinMaterial : .regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { volumeValue },
                        set: { volumeValue = $0 }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        isAdjustingVolume = editing
                        if !editing {
                            client?.setVolume(Int(volumeValue.rounded()))
                            syncVolumeValue()
                        }
                    }
                )
                .frame(width: 120)

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sliderDuration: Double {
        max(currentTrack?.durationSecs ?? 0, 1)
    }

    private var nextRepeatMode: RepeatMode {
        switch repeatMode {
        case .off:
            return .one
        case .one:
            return .all
        case .all:
            return .off
        }
    }

    private var repeatSymbolName: String {
        switch repeatMode {
        case .off, .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.15),
                Color.secondary.opacity(0.06),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func togglePlayback() {
        switch playbackStatus {
        case .playing:
            client?.pause()
        default:
            client?.play()
        }
    }

    private func syncSeekPosition() {
        seekPosition = min(currentPosition, sliderDuration)
    }

    private func syncVolumeValue() {
        volumeValue = min(max(currentVolume, 0), 100)
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
