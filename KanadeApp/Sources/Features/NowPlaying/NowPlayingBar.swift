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
    @State private var pendingSeekTarget: Double?
    @State private var volumeValue: Double = 0
    @State private var isAdjustingVolume = false

    private var playbackState: AppState.EffectivePlaybackState {
        appState.effectivePlaybackState
    }

    private var transportState: AppState.EffectiveTransportState? {
        playbackState.transport
    }

    private var currentTrack: Track? {
        playbackState.currentTrack
    }

    private var isPlaying: Bool {
        transportState?.isPlayingLike ?? false
    }

    private var currentPosition: Double {
        transportState?.positionSecs ?? 0
    }

    private var currentVolume: Double {
        Double(transportState?.volume ?? 0)
    }

    private var sliderDuration: Double {
        max(appState.effectiveDurationSecs, playbackState.currentTrack?.durationSecs ?? 0, 1)
    }

    private var repeatMode: RepeatMode {
        playbackState.repeatMode
    }

    private var shuffleEnabled: Bool {
        playbackState.shuffleEnabled
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
        .onChange(of: currentPosition, handleCurrentPositionChange)
        .onChange(of: currentVolume, handleCurrentVolumeChange)
    }

    private func barContent(currentTrack: Track) -> some View {
        ViewThatFits(in: .horizontal) {
            fullContent(currentTrack: currentTrack)
            compactContent(currentTrack: currentTrack)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private func compactContent(currentTrack: Track) -> some View {
        HStack(spacing: 12) {
            compactInfoCluster(currentTrack: currentTrack)

            Spacer()

            compactOutputButton

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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .frame(height: placement == .iosAccessory ? 60 : 64)
        .modifier(PlacementBackgroundModifier(placement: placement))
    }

    @ViewBuilder
    private var compactOutputButton: some View {
        @Bindable var appState = appState
        Menu {
            OutputPickerMenuContent()
        } label: {
            Image(systemName: appState.isControllingLocalNode ? "headphones" : "airplayaudio")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
    }

    private func fullContent(currentTrack: Track) -> some View {
        HStack(spacing: 12) {
            leftColumn(currentTrack: currentTrack)
                .frame(minWidth: 80, maxWidth: 280, alignment: .leading)

            centerColumn
                .frame(minWidth: 320)
                .frame(maxWidth: .infinity)

            rightColumn
                .frame(minWidth: 80, maxWidth: 280)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .frame(height: placement == .iosAccessory ? 60 : 64)
        .modifier(PlacementBackgroundModifier(placement: placement))
    }

    private func leftColumn(currentTrack: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(mediaClient: appState.mediaClient, albumId: currentTrack.albumId)
                .frame(width: fullArtworkSize, height: fullArtworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrack.title ?? "Untitled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(currentTrack.artist ?? "Unknown Artist")
                    .font(.system(size: 10))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)

                if let album = currentTrack.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryTextColor.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
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
        VStack(spacing: 2) {
            HStack(spacing: 16) {
                Button {
                    appState.performSetShuffle(!shuffleEnabled)
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12))
                        .foregroundStyle(shuffleEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())

                Button {
                    appState.performPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())

                Button {
                    appState.performNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())

                Button {
                    appState.performSetRepeat(nextRepeatMode)
                } label: {
                    Image(systemName: repeatSymbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(repeatMode != .off ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
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
                                .animation(isSeeking ? nil : .linear(duration: 0.5), value: seekPosition)
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
                                    pendingSeekTarget = seekPosition
                                    appState.performSeek(to: seekPosition)
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

            outputPickerButton

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
                        if editing {
                            appState.performSetVolume(Int(volumeValue.rounded()))
                        }
                        if !editing {
                            appState.performSetVolume(Int(volumeValue.rounded()))
                            syncVolumeValue()
                        }
                    }
                )
                .frame(width: 90)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var outputPickerButton: some View {
        @Bindable var appState = appState
        Menu {
            OutputPickerMenuContent()
        } label: {
            Image(systemName: appState.isControllingLocalNode ? "headphones" : "airplayaudio")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.quaternary.opacity(0.6)))
        }
        .menuStyle(.borderlessButton)
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
            return 44
        }
    }

    private var fullArtworkSize: CGFloat {
        switch placement {
        case .iosAccessory:
            return 52
        case .macFloating:
            return 44
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
            appState.performPause()
        } else {
            appState.performPlay()
        }
    }

    private func handleCurrentPositionChange() {
        if let target = pendingSeekTarget {
            if abs(currentPosition - target) < 2.0 {
                pendingSeekTarget = nil
                seekPosition = min(currentPosition, sliderDuration)
            }
        } else if !isSeeking {
            syncSeekPosition()
        }
    }

    private func handleCurrentVolumeChange() {
        if !isAdjustingVolume {
            syncVolumeValue()
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

#Preview {
    NowPlayingBar(placement: .iosAccessory)
        .environment(AppState())
        .padding()
        .background(Color.gray.opacity(0.2))
}
