import Foundation

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

public enum MusicTUIError: Error, LocalizedError, Equatable {
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
  func quitMusic() throws
}

public protocol CatalogSearching {
  func search(_ query: String) throws -> [Song]
}

public enum ViewMode: Equatable {
  case player
  case library
  case catalog
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
