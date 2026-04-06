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

    private var isPlaying: Bool {
        currentNode?.status == .playing
    }

    private var repeatMode: RepeatMode {
        playbackState?.repeatMode ?? .off
    }

    private var shuffleEnabled: Bool {
        playbackState?.shuffle ?? false
    }

    var body: some View {
        #if os(iOS)
        VStack(spacing: 32) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 8)

            if let currentTrack {
                ArtworkView(mediaClient: appState.mediaClient, albumId: currentTrack.albumId)
                    .frame(maxWidth: 380, maxHeight: 380)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                    .padding(.horizontal, 32)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)
                    .frame(maxWidth: 380, maxHeight: 380)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 32)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }

            VStack(spacing: 32) {
                VStack(spacing: 2) {
                    Text(currentTrack?.title ?? "Nothing Playing")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Text(currentTrack?.artist ?? "Unknown Artist")
                            .foregroundStyle(.white.opacity(0.7))
                        Text("·")
                            .foregroundStyle(.white.opacity(0.5))
                        Text(currentTrack?.albumTitle ?? "Unknown Album")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .font(.body)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 32)

                VStack(spacing: 8) {
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
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)

                HStack(spacing: 0) {
                    Button {
                        client?.setShuffle(!shuffleEnabled)
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.title3)
                            .foregroundStyle(shuffleEnabled ? .white : .white.opacity(0.5))
                            .frame(width: 36, height: 36)
                            .background(shuffleEnabled ? .white.opacity(0.15) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity)

                    Button {
                        client?.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(currentTrack == nil)
                    .frame(maxWidth: .infinity)

                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(currentTrack == nil)
                    .frame(maxWidth: .infinity)

                    Button {
                        client?.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(currentTrack == nil)
                    .frame(maxWidth: .infinity)

                    Button {
                        client?.setRepeat(nextRepeatMode)
                    } label: {
                        Image(systemName: repeatSymbolName)
                            .font(.title3)
                            .foregroundStyle(repeatMode == .off ? .white.opacity(0.5) : .white)
                            .frame(width: 36, height: 36)
                            .background(repeatMode == .off ? .clear : .white.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))

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

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 32)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundView)
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
        #else
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
        #endif
    }

    #if os(macOS)
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
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
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
    #endif

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
        #if os(iOS)
        ZStack {
            Color.black.opacity(0.85)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.20),
                    Color.accentColor.opacity(0.05),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        #else
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
        #endif
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
