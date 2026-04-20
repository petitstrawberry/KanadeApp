import Foundation
import Observation
import KanadeKit

@MainActor
@Observable
final class LocalQueue {
    var tracks: [Track] = []
    var currentIndex: Int?
    var repeatMode: RepeatMode = .off
    var shuffleEnabled = false
    var playbackOrder: [Int] = []
    var positionSecs: Double?

    var currentTrack: Track? {
        guard let currentIndex, tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }

    var nextTrack: Track? {
        guard !tracks.isEmpty else { return nil }
        guard let currentOrderPosition else {
            return playbackOrder.first.flatMap(track(at:))
        }

        if repeatMode == .one {
            return currentTrack
        }

        let nextOrderPosition = currentOrderPosition + 1
        if playbackOrder.indices.contains(nextOrderPosition) {
            return track(at: playbackOrder[nextOrderPosition])
        }

        guard repeatMode == .all, let firstIndex = playbackOrder.first else {
            return nil
        }

        return track(at: firstIndex)
    }

    var previousTrack: Track? {
        guard !tracks.isEmpty else { return nil }
        guard let currentOrderPosition else { return nil }

        if repeatMode == .one {
            return currentTrack
        }

        let previousOrderPosition = currentOrderPosition - 1
        if playbackOrder.indices.contains(previousOrderPosition) {
            return track(at: playbackOrder[previousOrderPosition])
        }

        guard repeatMode == .all, let lastIndex = playbackOrder.last else {
            return nil
        }

        return track(at: lastIndex)
    }

    func setTracks(_ tracks: [Track], startIndex: Int) {
        self.tracks = tracks
        positionSecs = nil

        guard !tracks.isEmpty else {
            currentIndex = nil
            playbackOrder = []
            return
        }

        let normalizedStartIndex = tracks.indices.contains(startIndex) ? startIndex : 0
        currentIndex = normalizedStartIndex
        playbackOrder = shuffleEnabled
            ? makeShuffledPlaybackOrder(currentIndex: normalizedStartIndex)
            : Array(tracks.indices)
    }

    @discardableResult
    func advance() -> Bool {
        guard !tracks.isEmpty else { return false }

        if repeatMode == .one {
            positionSecs = 0
            return currentTrack != nil
        }

        guard let currentOrderPosition else {
            guard let firstIndex = playbackOrder.first else { return false }
            currentIndex = firstIndex
            positionSecs = 0
            return true
        }

        let nextOrderPosition = currentOrderPosition + 1
        if playbackOrder.indices.contains(nextOrderPosition) {
            currentIndex = playbackOrder[nextOrderPosition]
            positionSecs = 0
            return true
        }

        guard repeatMode == .all, let firstIndex = playbackOrder.first else {
            return false
        }

        currentIndex = firstIndex
        positionSecs = 0
        return true
    }

    @discardableResult
    func goBack() -> Bool {
        guard !tracks.isEmpty else { return false }

        if repeatMode == .one {
            positionSecs = 0
            return currentTrack != nil
        }

        guard let currentOrderPosition else { return false }

        let previousOrderPosition = currentOrderPosition - 1
        if playbackOrder.indices.contains(previousOrderPosition) {
            currentIndex = playbackOrder[previousOrderPosition]
            positionSecs = 0
            return true
        }

        guard repeatMode == .all, let lastIndex = playbackOrder.last else {
            return false
        }

        currentIndex = lastIndex
        positionSecs = 0
        return true
    }

    func jumpToIndex(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
        positionSecs = 0
    }

    func shuffle() {
        shuffleEnabled = true
        playbackOrder = makeShuffledPlaybackOrder(currentIndex: currentIndex)
    }

    func unshuffle() {
        shuffleEnabled = false
        playbackOrder = Array(tracks.indices)
    }

    @discardableResult
    func toggleRepeat() -> RepeatMode {
        repeatMode = switch repeatMode {
        case .off: .one
        case .one: .all
        case .all: .off
        }
        return repeatMode
    }

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
    }

    func setShuffle(_ enabled: Bool) {
        enabled ? shuffle() : unshuffle()
    }

    func append(_ track: Track) {
        append(contentsOf: [track])
    }

    func append(contentsOf newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }

        let preservedCurrentIndex = currentIndex
        tracks.append(contentsOf: newTracks)

        if currentIndex == nil {
            currentIndex = tracks.indices.first
        }

        playbackOrder = shuffleEnabled
            ? makeShuffledPlaybackOrder(currentIndex: preservedCurrentIndex ?? currentIndex)
            : Array(tracks.indices)
    }

    func remove(at index: Int) {
        guard tracks.indices.contains(index) else { return }

        let removedWasCurrent = currentIndex == index
        tracks.remove(at: index)

        guard !tracks.isEmpty else {
            clear()
            return
        }

        if let currentIndex {
            if removedWasCurrent {
                self.currentIndex = min(index, tracks.count - 1)
            } else if currentIndex > index {
                self.currentIndex = currentIndex - 1
            }
        }

        playbackOrder = shuffleEnabled
            ? makeShuffledPlaybackOrder(currentIndex: currentIndex)
            : Array(tracks.indices)
    }

    func move(from sourceIndex: Int, to destinationIndex: Int) {
        guard tracks.indices.contains(sourceIndex) else { return }
        guard sourceIndex != destinationIndex else { return }

        let movingTrack = tracks[sourceIndex]
        tracks.moveElement(from: sourceIndex, to: destinationIndex)
        currentIndex = tracks.firstIndex(of: movingTrack)
        playbackOrder = shuffleEnabled
            ? makeShuffledPlaybackOrder(currentIndex: currentIndex)
            : Array(tracks.indices)
    }

    func clear() {
        tracks = []
        currentIndex = nil
        playbackOrder = []
        positionSecs = nil
    }

    func exportQueue() -> (tracks: [Track], index: Int?, positionSecs: Double?) {
        (tracks: tracks, index: currentIndex, positionSecs: positionSecs)
    }

    func importQueue(tracks: [Track], index: Int?, positionSecs: Double?) {
        self.tracks = tracks
        self.positionSecs = positionSecs

        guard !tracks.isEmpty else {
            currentIndex = nil
            playbackOrder = []
            return
        }

        if let index, tracks.indices.contains(index) {
            currentIndex = index
        } else {
            currentIndex = nil
        }

        playbackOrder = shuffleEnabled
            ? makeShuffledPlaybackOrder(currentIndex: currentIndex)
            : Array(tracks.indices)
    }

    private var currentOrderPosition: Int? {
        guard let currentIndex else { return nil }
        return playbackOrder.firstIndex(of: currentIndex)
    }

    private func track(at index: Int) -> Track? {
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    private func makeShuffledPlaybackOrder(currentIndex: Int?) -> [Int] {
        var remainingIndices = Array(tracks.indices)

        if let currentIndex,
           let currentPosition = remainingIndices.firstIndex(of: currentIndex) {
            remainingIndices.remove(at: currentPosition)
            return [currentIndex] + remainingIndices.shuffled()
        }

        return remainingIndices.shuffled()
    }
}

private extension Array {
    mutating func moveElement(from sourceIndex: Int, to destinationIndex: Int) {
        guard indices.contains(sourceIndex) else { return }

        let element = remove(at: sourceIndex)
        let adjustedDestination: Int
        if destinationIndex > sourceIndex {
            adjustedDestination = Swift.min(Swift.max(destinationIndex - 1, 0), count)
        } else {
            adjustedDestination = Swift.min(Swift.max(destinationIndex, 0), count)
        }
        insert(element, at: adjustedDestination)
    }
}
