import Foundation
import AVFoundation
import KanadeKit
#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
final class NowPlayingManager {
    private var currentPlaybackPosition: Double = 0

#if canImport(MediaPlayer)
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
#endif

    func configureAudioSession() {
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            return
        }
#endif
    }

    func updateNowPlaying(
        track: Track?,
        artworkData: Data? = nil,
        duration: Double,
        position: Double,
        playbackRate: Double
    ) {
        currentPlaybackPosition = max(position, 0)

#if canImport(MediaPlayer)
        guard let track else {
            clearNowPlaying()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? "Unknown Title",
            MPMediaItemPropertyArtist: track.artist ?? "Unknown Artist",
            MPMediaItemPropertyAlbumTitle: track.albumTitle ?? "Unknown Album",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentPlaybackPosition,
            MPMediaItemPropertyPlaybackDuration: max(duration, 0),
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        if let artwork = makeArtwork(from: artworkData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        infoCenter.nowPlayingInfo = info
#endif
    }

    func setPlaybackHandlers(
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void,
        onSeek: @escaping (Double) -> Void
    ) {
#if canImport(MediaPlayer)
        removeCommandTargets()

        register(commandCenter.playCommand) { _ in
            onPlay()
            return .success
        }

        register(commandCenter.pauseCommand) { _ in
            onPause()
            return .success
        }

        register(commandCenter.nextTrackCommand) { _ in
            onNext()
            return .success
        }

        register(commandCenter.previousTrackCommand) { _ in
            onPrevious()
            return .success
        }

        register(commandCenter.seekForwardCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            let target = self.currentPlaybackPosition + 15
            self.currentPlaybackPosition = target
            onSeek(target)
            return .success
        }

        register(commandCenter.seekBackwardCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            let target = max(self.currentPlaybackPosition - 15, 0)
            self.currentPlaybackPosition = target
            onSeek(target)
            return .success
        }

        register(commandCenter.changePlaybackPositionCommand) { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            self.currentPlaybackPosition = max(event.positionTime, 0)
            onSeek(self.currentPlaybackPosition)
            return .success
        }
#endif
    }

    func clearNowPlaying() {
        currentPlaybackPosition = 0

#if canImport(MediaPlayer)
        infoCenter.nowPlayingInfo = nil
#endif
    }

    deinit {
#if canImport(MediaPlayer)
        MainActor.assumeIsolated {
            removeCommandTargets()
        }
#endif
    }

#if canImport(MediaPlayer)
    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget(handler: handler)
        command.isEnabled = true
        commandTargets.append((command, target))
    }

    private func removeCommandTargets() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
    }

    private func makeArtwork(from data: Data?) -> MPMediaItemArtwork? {
        guard let data else { return nil }

#if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
#elseif os(macOS)
        return nil
#else
        return nil
#endif
    }
#endif
}
