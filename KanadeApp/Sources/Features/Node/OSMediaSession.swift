import Foundation

#if canImport(MediaPlayer)
import MediaPlayer
#endif

protocol OSMediaSession: Sendable {
    func updateNowPlaying(title: String?, artist: String?, album: String?, duration: Double?, elapsedTime: Double?)
    func updatePlaybackState(isPlaying: Bool)
    func clearNowPlaying()
    func setCommandHandler(play: @escaping @Sendable () -> Void, pause: @escaping @Sendable () -> Void, stop: @escaping @Sendable () -> Void, seek: @escaping @Sendable (Double) -> Void)
}

#if os(iOS)
final class IOSMediaSession: OSMediaSession, @unchecked Sendable {
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    
    private var playHandler: (@Sendable () -> Void)?
    private var pauseHandler: (@Sendable () -> Void)?
    private var stopHandler: (@Sendable () -> Void)?
    private var seekHandler: (@Sendable (Double) -> Void)?
    
    init() {
        setupCommands()
    }
    
    private func setupCommands() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.playHandler?()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pauseHandler?()
            return .success
        }
        
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.stopHandler?()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seekHandler?(event.positionTime)
                return .success
            }
            return .commandFailed
        }
    }
    
    func updateNowPlaying(title: String?, artist: String?, album: String?, duration: Double?, elapsedTime: Double?) {
        var info: [String: Any] = [:]
        
        if let title {
            info[MPMediaItemPropertyTitle] = title
        }
        if let artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let elapsedTime {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        }
        
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        
        nowPlayingInfoCenter.nowPlayingInfo = info
    }
    
    func updatePlaybackState(isPlaying: Bool) {
        if var info = nowPlayingInfoCenter.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            nowPlayingInfoCenter.nowPlayingInfo = info
        }
    }
    
    func clearNowPlaying() {
        nowPlayingInfoCenter.nowPlayingInfo = nil
    }
    
    func setCommandHandler(play: @escaping @Sendable () -> Void, pause: @escaping @Sendable () -> Void, stop: @escaping @Sendable () -> Void, seek: @escaping @Sendable (Double) -> Void) {
        self.playHandler = play
        self.pauseHandler = pause
        self.stopHandler = stop
        self.seekHandler = seek
    }
}
#endif

#if os(macOS)
final class MacOSMediaSession: OSMediaSession, @unchecked Sendable {
    private let nowPlayingInfoCenter: MPNowPlayingInfoCenter?
    private let commandCenter: MPRemoteCommandCenter?
    
    private var playHandler: (@Sendable () -> Void)?
    private var pauseHandler: (@Sendable () -> Void)?
    private var stopHandler: (@Sendable () -> Void)?
    private var seekHandler: (@Sendable (Double) -> Void)?
    
    init() {
        if #available(macOS 10.12.2, *) {
            self.nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
            self.commandCenter = MPRemoteCommandCenter.shared()
            setupCommands()
        } else {
            self.nowPlayingInfoCenter = nil
            self.commandCenter = nil
        }
    }
    
    private func setupCommands() {
        guard #available(macOS 10.12.2, *), let commandCenter else { return }
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.playHandler?()
            return .success
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pauseHandler?()
            return .success
        }
        
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.stopHandler?()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seekHandler?(event.positionTime)
                return .success
            }
            return .commandFailed
        }
    }
    
    func updateNowPlaying(title: String?, artist: String?, album: String?, duration: Double?, elapsedTime: Double?) {
        guard #available(macOS 10.12.2, *), let nowPlayingInfoCenter else { return }
        
        var info: [String: Any] = [:]
        
        if let title {
            info[MPMediaItemPropertyTitle] = title
        }
        if let artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let elapsedTime {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        }
        
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        
        nowPlayingInfoCenter.nowPlayingInfo = info
    }
    
    func updatePlaybackState(isPlaying: Bool) {
        guard #available(macOS 10.12.2, *), let nowPlayingInfoCenter else { return }
        
        if var info = nowPlayingInfoCenter.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            nowPlayingInfoCenter.nowPlayingInfo = info
        }
    }
    
    func clearNowPlaying() {
        guard #available(macOS 10.12.2, *), let nowPlayingInfoCenter else { return }
        nowPlayingInfoCenter.nowPlayingInfo = nil
    }
    
    func setCommandHandler(play: @escaping @Sendable () -> Void, pause: @escaping @Sendable () -> Void, stop: @escaping @Sendable () -> Void, seek: @escaping @Sendable (Double) -> Void) {
        self.playHandler = play
        self.pauseHandler = pause
        self.stopHandler = stop
        self.seekHandler = seek
    }
}
#endif

enum OSMediaSessionFactory {
    static func create() -> (any OSMediaSession)? {
        #if os(macOS)
        if #available(macOS 10.12.2, *) {
            return MacOSMediaSession()
        }
        return nil
        #else
        return nil
        #endif
    }
}
