import SwiftUI
import KanadeKit

enum NowPlayingBarPlacement {
    case iosAccessory
    case macFloating
}

struct NowPlayingBar: View {
    @Environment(AppState.self) private var appState

    let placement: NowPlayingBarPlacement

    @State private var seekPosition: Double = 0
    @State private var isSeeking = false
    @State private var volumeValue: Double = 0
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

    init(placement: NowPlayingBarPlacement = .iosAccessory) {
        self.placement = placement
    }

    var body: some View {
        Group {
            if let currentTrack {
                barContent(currentTrack: currentTrack)
            }
        }
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
    }

    private func barContent(currentTrack: Track) -> some View {
        ViewThatFits(in: .horizontal) {
            fullContent(currentTrack: currentTrack)
                .frame(minWidth: placement == .iosAccessory ? 10_000 : 768)

            compactContent(currentTrack: currentTrack)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private func compactContent(currentTrack: Track) -> some View {
        HStack(spacing: 12) {
            compactInfoCluster(currentTrack: currentTrack)

            Spacer()

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 60)
        .modifier(PlacementBackgroundModifier(placement: placement))
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
        .modifier(PlacementBackgroundModifier(placement: placement))
    }

    private func leftColumn(currentTrack: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(mediaClient: appState.mediaClient, albumId: currentTrack.albumId)
                .frame(width: fullArtworkSize, height: fullArtworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrack.title ?? "Untitled")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(currentTrack.artist ?? "Unknown Artist")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func compactInfoCluster(currentTrack: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(mediaClient: appState.mediaClient, albumId: currentTrack.albumId)
                .frame(width: compactArtworkSize, height: compactArtworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrack.title ?? "Untitled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(currentTrack.artist ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
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

                Slider(
                    value: Binding(
                        get: { volumeValue },
                        set: { volumeValue = $0 }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        isAdjustingVolume = editing
                        client?.setVolume(Int(volumeValue.rounded()))
                        if !editing {
                            syncVolumeValue()
                        }
                    }
                )
                .frame(width: 90)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var barBackground: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            switch placement {
            case .iosAccessory:
                Color.clear
            case .macFloating:
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(placement == .iosAccessory ? 0.03 : 0.06), radius: placement == .iosAccessory ? 6 : 10, y: placement == .iosAccessory ? 1 : 3)
        }
    }

    private var secondaryTextColor: Color {
        switch placement {
        case .iosAccessory:
            return .primary.opacity(0.78)
        case .macFloating:
            return .primary.opacity(0.92)
        }
    }

    private var horizontalPadding: CGFloat {
        switch placement {
        case .iosAccessory:
            return 0
        case .macFloating:
            return 0
        }
    }

    private var verticalPadding: CGFloat {
        switch placement {
        case .iosAccessory:
            return 0
        case .macFloating:
            return 0
        }
    }

    private var compactArtworkSize: CGFloat {
        switch placement {
        case .iosAccessory:
            return 28
        case .macFloating:
            return 40
        }
    }

    private var fullArtworkSize: CGFloat {
        switch placement {
        case .iosAccessory:
            return 52
        case .macFloating:
            return 64
        }
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

private struct PlacementBackgroundModifier: ViewModifier {
    let placement: NowPlayingBarPlacement

    @ViewBuilder
    func body(content: Content) -> some View {
        switch placement {
        case .iosAccessory:
            content
        case .macFloating:
            content.background(MacFloatingBarBackground())
        }
    }
}

private struct MacFloatingBarBackground: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.quaternary.opacity(0.7))
                .frame(height: 0.5)

            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Rectangle()
                    .fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.35), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }
}
