import Foundation

/// A single row of Music's queue, which is the playlist Music is playing from.
/// Rows are read-only: Music's scripting cannot start a track inside a playlist
/// without dropping the playlist context, so `isCurrent` only marks where
/// playback has reached.
public struct QueueEntry: Equatable {
  public var name: String
  public var artist: String
  public var album: String
  /// True for the track Music is playing right now.
  public var isCurrent: Bool

  public init(name: String = "", artist: String = "", album: String = "", isCurrent: Bool = false) {
    self.name = name
    self.artist = artist
    self.album = album
    self.isCurrent = isCurrent
  }

  public var display: String {
    artist.isEmpty ? name : "\(name) — \(artist)"
  }
}

/// The queue is a plain list so it can be paged and rendered with the rest of
/// the model: the worker rebuilds it from Music after every change, so the rows
/// on screen always describe what Music will play next instead of a mirror of a
/// half-applied edit.
public struct Queue: Equatable {
  /// Name of the playlist Music is playing from, empty when nothing is playing.
  public var playlist: String = ""
  public private(set) var entries: [QueueEntry] = []
  public private(set) var cursor = 0

  public init(playlist: String = "", entries: [QueueEntry] = []) {
    self.playlist = playlist
    self.entries = entries
    self.cursor = clamp(cursor, min: 0, max: entries.count - 1)
  }

  public var count: Int { entries.count }

  public var isEmpty: Bool { entries.isEmpty }

  public mutating func setCursor(_ index: Int) {
    cursor = clamp(index, min: 0, max: count - 1)
  }
}

public struct NowPlaying: Equatable {
  public var state: String
  public var volume: Int
  public var shuffle: Bool
  public var name: String
  public var artist: String
  public var album: String
  public var position: Int
  public var duration: Int
  public var positionAvailable: Bool
  public var durationAvailable: Bool
  public var timingSource: String
  public var timingDiagnostic: String

  public init(
    state: String = "stopped", volume: Int = 0, shuffle: Bool = false,
    name: String = "", artist: String = "", album: String = "",
    position: Int = 0, duration: Int = 0,
    positionAvailable: Bool = false, durationAvailable: Bool = false,
    timingSource: String = "", timingDiagnostic: String = ""
  ) {
    self.state = state
    self.volume = volume
    self.shuffle = shuffle
    self.name = name
    self.artist = artist
    self.album = album
    self.position = position
    self.duration = duration
    self.positionAvailable = positionAvailable
    self.durationAvailable = durationAvailable
    self.timingSource = timingSource
    self.timingDiagnostic = timingDiagnostic
  }
}

public struct Song: Equatable {
  public var name: String
  public var artist: String
  public var album: String
  public var url: String
  public var duration: Int
  /// Persistent ID of the matching track in the user's library, when one is known.
  public var libraryID: String

  public init(
    name: String, artist: String, album: String, url: String, duration: Int = 0,
    libraryID: String = ""
  ) {
    self.name = name
    self.artist = artist
    self.album = album
    self.url = url
    self.duration = duration
    self.libraryID = libraryID
  }
}

public enum MusicTUIError: Error, LocalizedError {
  case commandNotFound(String)
  case commandFailed(String)
  case invalidCatalogURL
  case musicNotReady
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .commandNotFound(let name): return "Required command was not found: \(name)"
    case .commandFailed(let message): return message
    case .invalidCatalogURL: return "Unsupported Apple Music catalog URL."
    case .musicNotReady: return "Music did not become ready before the timeout."
    case .invalidResponse(let message): return message
    }
  }
}

public protocol MusicControlling: AnyObject {
  func initialize() throws -> NowPlaying
  func nowPlaying() throws -> NowPlaying
  func playlists() throws -> [String]
  func playPause() throws
  func next() throws
  func previous() throws
  func setVolume(_ volume: Int) throws
  func seek(_ seconds: Int) throws
  func toggleShuffle() throws
  func playPlaylist(_ name: String) throws
  /// Plays a song, preferring the user's library copy when one exists.
  func play(_ song: Song) throws
  /// Searches the user's library by track, artist, or album name.
  func searchLibrary(_ query: String) throws -> [Song]
  /// Applies one queue intent and returns Music's queue as it stands after the
  /// change, so the model never renders a half-applied edit.
  func queue(command: QueueCommand) throws -> Queue

  func quitMusic() throws
}

public protocol CatalogSearching {
  func search(_ query: String) throws -> [Song]
}

public enum ViewMode: Equatable {
  case player
  case library
  case catalog
  case queue
}

public enum InputKey: Equatable {
  case character(String)
  case space
  case enter
  case escape
  case backspace
  case tab
  case up
  case down
  case left
  case right

  public init(raw: String) {
    switch raw {
    case " ", "SPACE": self = .space
    case "\r", "\n", "ENTER": self = .enter
    case "ESC", "\u{1B}": self = .escape
    case "BACKSPACE", "\u{7F}", "\u{08}": self = .backspace
    case "\t", "TAB": self = .tab
    case "UP": self = .up
    case "DOWN": self = .down
    case "LEFT": self = .left
    case "RIGHT": self = .right
    default: self = .character(raw)
    }
  }
}

public enum KeyAction {
  case continueRunning
  case quitApplication
}

/// Work requested by a keypress. The terminal loop executes these away from
/// the input/render thread so slow AppleScript or network calls cannot freeze UI.
public enum AppCommand: Equatable {
  case playPause
  case next
  case previous
  case setVolume(Int)
  case seek(Int)
  case toggleShuffle
  case playPlaylist(String)
  case playSong(Song)
  case quitMusic
  case loadPlaylists
  case searchCatalog(String)
  case searchLibrary(String)
  case loadQueue
  case queuePlayNext
  case queuePlayPrevious

  /// The queue intent this app command carries, so the worker thread can ask
  /// the Music controller to mutate the queue without the model knowing Music.
  public var queueCommand: QueueCommand {
    switch self {
    case .loadQueue: return .load
    case .queuePlayNext: return .playNext
    case .queuePlayPrevious: return .playPrevious
    // Only the queue commands above ever reach this property; the empty queue
    // read is the harmless answer for anything else.
    default: return .load
    }
  }
}

/// Work requested by the queue UI, dispatched through the same worker
/// machinery as everything else so slow AppleScript calls can never freeze the
/// input loop. Commands that target a row carry that row's persistent ID, so
/// they act on the selection instead of on whatever track happens to be
/// playing.
public enum QueueCommand: Equatable {
  /// Skips to the next track in the playlist Music is playing from.
  case playNext
  /// Returns to the previous track in the playlist Music is playing from.
  case playPrevious
  /// Reads Music's queue: when the queue view opens, and after a track change,
  /// so the rows always describe what Music will play.
  case load
  // ponytail: there is deliberately no jump-to-row and no remove-from-queue
  // command. Music has no scripting access to Up Next, so the only list we can
  // reach is the playlist being played: `play <track>` there leaves Music with
  // no current playlist at all, and `delete <track>` also deletes Apple Music
  // tracks from the user's library. Both stay in Music's own UI, where
  // "Play Next", "Remove from Playlist" and "Delete from Library" are separate.
}

public struct PendingAppCommand: Equatable {
  public let command: AppCommand
  public let message: String
  public let quitAfterSuccess: Bool

  public init(command: AppCommand, message: String, quitAfterSuccess: Bool = false) {
    self.command = command
    self.message = message
    self.quitAfterSuccess = quitAfterSuccess
  }
}

public func trackKey(name: String, artist: String) -> String {
  "\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())\u{0}\(artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
}

public func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
  guard maximum >= minimum else { return minimum }
  return min(max(value, minimum), maximum)
}

public func formatTime(_ seconds: Int) -> String {
  let normalized = max(0, seconds)
  return "\(normalized / 60):\(String(format: "%02d", normalized % 60))"
}

public func availableTime(_ seconds: Int, available: Bool) -> String {
  available ? formatTime(seconds) : "--:--"
}

public func normalizeTitle(_ value: String) -> String {
  value.lowercased().filter { $0.isLetter || $0.isNumber }
}

public func sameTrackTitle(_ left: String, _ right: String) -> Bool {
  let lhs = normalizeTitle(left)
  return !lhs.isEmpty && lhs == normalizeTitle(right)
}
