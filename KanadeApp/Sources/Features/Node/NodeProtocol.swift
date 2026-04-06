import Foundation

enum NodePlaybackStatus: String, Codable, Sendable {
    case stopped
    case playing
    case paused
    case loading
}

struct NodeRegistration: Codable, Sendable {
    let nodeID: String?
    let displayName: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case displayName = "display_name"
        case name
    }
}

struct NodeRegistrationAck: Codable, Sendable {
    let nodeID: String
    let mediaBaseURL: String

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case mediaBaseURL = "media_base_url"
    }
}

enum NodeCommand: Codable, Sendable, Equatable {
    case play
    case pause
    case stop
    case seek(positionSecs: Double)
    case setVolume(volume: Int)
    case setQueue(filePaths: [String], projectionGeneration: Int)
    case add(filePaths: [String])
    case remove(index: Int)
    case moveTrack(from: Int, to: Int)

    private enum CodingKeys: String, CodingKey {
        case type
        case positionSecs = "position_secs"
        case volume
        case filePaths = "file_paths"
        case projectionGeneration = "projection_generation"
        case index
        case from
        case to
    }

    private enum CommandType: String, Codable {
        case play
        case pause
        case stop
        case seek
        case setVolume = "set_volume"
        case setQueue = "set_queue"
        case add
        case remove
        case moveTrack = "move_track"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(CommandType.self, forKey: .type) {
        case .play:
            self = .play
        case .pause:
            self = .pause
        case .stop:
            self = .stop
        case .seek:
            self = .seek(positionSecs: try container.decode(Double.self, forKey: .positionSecs))
        case .setVolume:
            self = .setVolume(volume: try container.decode(Int.self, forKey: .volume))
        case .setQueue:
            self = .setQueue(
                filePaths: try container.decode([String].self, forKey: .filePaths),
                projectionGeneration: try container.decode(Int.self, forKey: .projectionGeneration)
            )
        case .add:
            self = .add(filePaths: try container.decode([String].self, forKey: .filePaths))
        case .remove:
            self = .remove(index: try container.decode(Int.self, forKey: .index))
        case .moveTrack:
            self = .moveTrack(
                from: try container.decode(Int.self, forKey: .from),
                to: try container.decode(Int.self, forKey: .to)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .play:
            try container.encode(CommandType.play, forKey: .type)
        case .pause:
            try container.encode(CommandType.pause, forKey: .type)
        case .stop:
            try container.encode(CommandType.stop, forKey: .type)
        case .seek(let positionSecs):
            try container.encode(CommandType.seek, forKey: .type)
            try container.encode(positionSecs, forKey: .positionSecs)
        case .setVolume(let volume):
            try container.encode(CommandType.setVolume, forKey: .type)
            try container.encode(volume, forKey: .volume)
        case .setQueue(let filePaths, let projectionGeneration):
            try container.encode(CommandType.setQueue, forKey: .type)
            try container.encode(filePaths, forKey: .filePaths)
            try container.encode(projectionGeneration, forKey: .projectionGeneration)
        case .add(let filePaths):
            try container.encode(CommandType.add, forKey: .type)
            try container.encode(filePaths, forKey: .filePaths)
        case .remove(let index):
            try container.encode(CommandType.remove, forKey: .type)
            try container.encode(index, forKey: .index)
        case .moveTrack(let from, let to):
            try container.encode(CommandType.moveTrack, forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        }
    }
}

struct NodeStateUpdate: Codable, Sendable {
    let status: NodePlaybackStatus
    let positionSecs: Double
    let volume: Int
    let mpdSongIndex: Int?
    let projectionGeneration: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case positionSecs = "position_secs"
        case volume
        case mpdSongIndex = "mpd_song_index"
        case projectionGeneration = "projection_generation"
    }
}
