import Foundation
import AVFoundation
import KanadeKit
#if canImport(MediaPlayer)
import MediaPlayer
#endif

#if DEBUG
private let nowPlayingLogDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func nowPlayingDebugLog(_ message: @autoclosure () -> String) {
    print("[NowPlayingManager][\(nowPlayingLogDateFormatter.string(from: Date()))] \(message())")
}
#endif

@MainActor
final class NowPlayingManager {
    private var cachedPlaybackPosition: Double = 0
    private var isAudioSessionActive = false

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
        } catch {
            return
        }
#endif
    }

    func setAudioSessionActive(_ isActive: Bool) {
#if os(iOS)
        guard isAudioSessionActive != isActive else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            if isActive {
                try session.setActive(true)
            } else {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
            isAudioSessionActive = isActive
        } catch {
            return
        }
#endif
    }

    func handlePlaybackStateTransition(status: PlaybackStatus, isPlayingLike: Bool) {
        if isPlayingLike {
            setAudioSessionActive(true)
            return
        }

        if status == .stopped {
            setAudioSessionActive(false)
        }
    }

    func updateNowPlaying(
        track: Track?,
        artworkData: Data? = nil,
        duration: Double,
        position: Double,
        playbackRate: Double,
        status: PlaybackStatus,
        isPlayingLike: Bool
    ) {
        cachedPlaybackPosition = sanitizedPosition(position)
#if canImport(MediaPlayer)
        guard let track else {
            clearNowPlaying()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? "Unknown Title",
            MPMediaItemPropertyArtist: track.artist ?? "Unknown Artist",
            MPMediaItemPropertyAlbumTitle: track.albumTitle ?? "Unknown Album",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: cachedPlaybackPosition,
            MPMediaItemPropertyPlaybackDuration: max(duration, 0),
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        if let artwork = makeArtwork(from: artworkData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        infoCenter.nowPlayingInfo = info

        #if DEBUG
        nowPlayingDebugLog(
            "updateNowPlaying status=\(status.rawValue) isPlayingLike=\(isPlayingLike) playbackRate=\(playbackRate) position=\(cachedPlaybackPosition) duration=\(duration) audioSessionActive=\(isAudioSessionActive) track=\(track.id)"
        )
        #endif
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
            #if DEBUG
            nowPlayingDebugLog("remoteCommand=play cachedPlaybackPosition=\(self.cachedPlaybackPosition)")
            #endif
            onPlay()
            return .success
        }

        register(commandCenter.pauseCommand) { _ in
            #if DEBUG
            nowPlayingDebugLog("remoteCommand=pause cachedPlaybackPosition=\(self.cachedPlaybackPosition)")
            #endif
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
            let target = self.cachedPlaybackPosition + 15
            self.cachedPlaybackPosition = target
            onSeek(target)
            return .success
        }

        register(commandCenter.seekBackwardCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            let target = max(self.cachedPlaybackPosition - 15, 0)
            self.cachedPlaybackPosition = target
            onSeek(target)
            return .success
        }

        register(commandCenter.changePlaybackPositionCommand) { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            self.cachedPlaybackPosition = self.sanitizedPosition(event.positionTime)
            #if DEBUG
            nowPlayingDebugLog("remoteCommand=changePlaybackPosition target=\(self.cachedPlaybackPosition)")
            #endif
            onSeek(self.cachedPlaybackPosition)
            return .success
        }
#endif
    }

    func clearNowPlaying() {
        cachedPlaybackPosition = 0
        setAudioSessionActive(false)

#if canImport(MediaPlayer)
        infoCenter.nowPlayingInfo = nil
#endif
    }

    private func sanitizedPosition(_ position: Double) -> Double {
        max(position, 0)
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
