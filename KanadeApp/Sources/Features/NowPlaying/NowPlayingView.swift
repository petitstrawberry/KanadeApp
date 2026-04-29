import SwiftUI
import KanadeKit
import Foundation

struct NowPlayingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var seekPosition: Double = 0
    @State private var volumeValue: Double = 0
    @State private var isSeeking = false
    @State private var pendingSeekTarget: Double?
    @State private var isAdjustingVolume = false
    @State private var showQueue = false
    @State private var dominantColor: Color = .clear

    private var playbackState: AppState.EffectivePlaybackState {
        appState.effectivePlaybackState
    }

    private var transportState: AppState.EffectiveTransportState? {
        playbackState.transport
    }

    private var currentTrack: Track? {
        playbackState.currentTrack
    }

    private var currentPosition: Double {
        transportState?.positionSecs ?? 0
    }

    private var currentVolume: Double {
        Double(transportState?.volume ?? 0)
    }

    private var isPlaying: Bool {
        transportState?.isPlayingLike ?? false
    }

    private var repeatMode: RepeatMode {
        playbackState.repeatMode
    }

    private var shuffleEnabled: Bool {
        playbackState.shuffleEnabled
    }

    private var hasCurrentTrack: Bool {
        currentTrack != nil
    }

    var body: some View {
        #if os(iOS)
        VStack(spacing: 32) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
            .padding(.top, 4)
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
                        .font(.title3.weight(.bold))
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
                    onEditingChanged: handleSeekEditingChanged
                )
                .tint(dominantColor)
                .disabled(!hasCurrentTrack)

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
                        appState.performSetShuffle(!shuffleEnabled)
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
                        appState.performPrevious()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(!hasCurrentTrack)
                    .frame(maxWidth: .infinity)

                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(!hasCurrentTrack)
                    .frame(maxWidth: .infinity)

                    Button {
                        appState.performNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(!hasCurrentTrack)
                    .frame(maxWidth: .infinity)

                    Button {
                        appState.performSetRepeat(nextRepeatMode)
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
                        onEditingChanged: handleVolumeEditingChanged
                    )
                    .tint(dominantColor)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 32)
            }

            outputPickerRow
                .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showQueue) {
            NavigationStack {
                QueueView()
            }
            .environment(appState)
        }
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundView)
        .onAppear {
            syncSeekPosition()
            syncVolumeValue()
            updateDominantColor()
        }
        .onChange(of: currentTrack?.id) {
            syncSeekPosition()
        }
        .onChange(of: currentTrack?.albumId) {
            updateDominantColor()
        }
        .onChange(of: currentPosition, handleCurrentPositionChange)
        .onChange(of: currentVolume, handleCurrentVolumeChange)
        .onChange(of: volumeValue) {
            if isAdjustingVolume {
                appState.performSetVolume(Int(volumeValue.rounded()))
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
        .sheet(isPresented: $showQueue) {
            NavigationStack {
                QueueView()
            }
            .environment(appState)
        }
        .navigationBarBackButtonHidden()
        .onAppear {
            syncSeekPosition()
            syncVolumeValue()
        }
        .onChange(of: currentTrack?.id) {
            syncSeekPosition()
        }
        .onChange(of: currentPosition, handleCurrentPositionChange)
        .onChange(of: currentVolume, handleCurrentVolumeChange)
        .onChange(of: volumeValue) {
            if isAdjustingVolume {
                appState.performSetVolume(Int(volumeValue.rounded()))
            }
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var outputPickerRow: some View {
        let isLocal = appState.isControllingLocalNode
        HStack(spacing: 12) {
            Image(systemName: isLocal ? "headphones" : "airplayaudio")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))

            Menu {
                OutputPickerMenuContent()
            } label: {
                Text(outputName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            Circle()
                .fill(.white.opacity(0.3))
                .frame(width: 6, height: 6)
        }
    }

    private var outputName: String {
        if appState.isControllingLocalNode {
            return UIDevice.current.name
        }
        if let nodeId = appState.controlledNodeId,
           let node = appState.client?.state?.nodes.first(where: { $0.id == nodeId }) {
            return node.name
        }
        if let node = appState.client?.state?.nodes.first(where: \.connected) {
            return node.name
        }
        return "No Output"
    }
    #endif

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
                onEditingChanged: handleSeekEditingChanged
            )
            .disabled(!hasCurrentTrack)

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
                appState.performPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!hasCurrentTrack)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 52))
            }
            .buttonStyle(.plain)
            .disabled(!hasCurrentTrack)

            Button {
                appState.performNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!hasCurrentTrack)
        }
        .foregroundStyle(.primary)
    }

    private var transportOptionsSection: some View {
        HStack(spacing: 16) {
            Button {
                appState.performSetShuffle(!shuffleEnabled)
            } label: {
                Image(systemName: "shuffle")
                    .font(.headline)
                    .foregroundStyle(shuffleEnabled ? .primary : .secondary)
                    .frame(width: 36, height: 36)
                    .background(shuffleEnabled ? .regularMaterial : .thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button {
                appState.performSetRepeat(nextRepeatMode)
            } label: {
                Image(systemName: repeatSymbolName)
                    .font(.headline)
                    .foregroundStyle(repeatMode == .off ? .secondary : .primary)
                    .frame(width: 36, height: 36)
                    .background(repeatMode == .off ? .thinMaterial : .regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Menu {
                OutputPickerMenuContent()
            } label: {
                Image(systemName: appState.isControllingLocalNode ? "headphones" : "airplayaudio")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { volumeValue },
                        set: { volumeValue = $0 }
                    ),
                    in: 0...100,
                    onEditingChanged: handleVolumeEditingChanged
                )
                .frame(width: 120)

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif

    private var sliderDuration: Double {
        max(appState.effectiveDurationSecs, playbackState.currentTrack?.durationSecs ?? 0, 1)
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

    #if os(iOS)
    private func updateDominantColor() {
        guard let albumId = currentTrack?.albumId else {
            return
        }
        guard let cached = ArtworkCache.image(for: albumId) else { return }
        extractColor(from: cached)
    }

    private func extractColor(from image: UIImage) {
        Task.detached(priority: .userInitiated) {
            guard let cgImage = image.cgImage else { return }
            let width = 1
            let height = 1
            let bytesPerRow = 4
            var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
            guard let context = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.draw(cgImage, in: rect)

            let r = Double(pixelData[0]) / 255.0
            let g = Double(pixelData[1]) / 255.0
            let b = Double(pixelData[2]) / 255.0

            let factor: Double = 0.55
            let gray = 0.299 * r + 0.587 * g + 0.114 * b
            let dr = r * factor + gray * (1 - factor)
            let dg = g * factor + gray * (1 - factor)
            let db = b * factor + gray * (1 - factor)

            Task { @MainActor in
                dominantColor = Color(red: dr, green: dg, blue: db)
            }
        }
    }
    #endif

    private var backgroundView: some View {
        #if os(iOS)
        ZStack {
            Color.black
            LinearGradient(
                colors: [
                    dominantColor.opacity(0.9),
                    dominantColor.opacity(0.65),
                    dominantColor.opacity(0.45),
                    dominantColor.opacity(0.3),
                    dominantColor.opacity(0.2)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: dominantColor)
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
            appState.performPause()
        } else {
            appState.performPlay()
        }
    }

    private func handleSeekEditingChanged(_ isEditing: Bool) {
        isSeeking = isEditing
        if !isEditing {
            pendingSeekTarget = seekPosition
            appState.performSeek(to: seekPosition)
        }
    }

    private func handleVolumeEditingChanged(_ isEditing: Bool) {
        isAdjustingVolume = isEditing
        if !isEditing {
            appState.performSetVolume(Int(volumeValue.rounded()))
            syncVolumeValue()
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
