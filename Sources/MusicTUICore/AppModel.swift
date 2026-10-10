import Foundation

public struct AppModel {
  public var nowPlaying = NowPlaying()
  public var musicError: String?
  public var status = ""
  public var statusShownAt = Date.distantPast
  public var mode: ViewMode = .player
  public var width = 100
  public var height = 30
  public var helpVisible = false

  public var playlists: [String] = []
  public var playlistsLoaded = false
  public var playlistsLoading = false
  public var playlistCursor = 0
  public var playlistFilter = ""
  public var playlistDraft = ""
  public var playlistTyping = false

  public var catalogQuery = ""
  public var catalogDraft = ""
  public var catalogTyping = false
  public var catalogSearching = false
  public var results: [Song] = []
  public var resultCursor = 0
  public var durationHints: [String: Int] = [:]
  public var theme: Theme
  public private(set) var pendingCommands: [PendingAppCommand] = []

  public var trackQuery = ""
  public var trackDraft = ""
  public var trackTyping = false
  public var trackSearching = false
  public var showingTracks = false
  public var tracks: [Song] = []
  public var trackCursor = 0

  /// Volume we have asked Music for but that a poll has not confirmed yet, so a
  /// burst of keypresses steps from the last requested value instead of from a
  /// reading that is up to a second old. A volume change made in Music itself
  /// while a target is pending is ignored until the target is reached.
  private var volumeTarget: Int?
  private let themeStore: ThemeStore
  private var remoteTrackKey = ""
  private var remoteState = ""
  private var remotePosition = 0
  private var remoteRawPosition = 0
  private var remoteAt = Date.distantPast

  public init(themeStore: ThemeStore = .shared) {
    self.themeStore = themeStore
    theme = themeStore.load()
  }

  public var filteredPlaylists: [String] {
    guard !playlistFilter.isEmpty else { return playlists }
    return playlists.filter { $0.localizedCaseInsensitiveContains(playlistFilter) }
  }

  public mutating func applyNowPlayingResult(_ snapshot: NowPlaying?, error: String?) {
    if let snapshot {
      nowPlaying = normalizeNowPlaying(snapshot)
      musicError = nil
      if let target = volumeTarget {
        // A poll that still reports the old value was taken before our request
        // landed; keep showing the requested volume until Music agrees.
        if nowPlaying.volume == target {
          volumeTarget = nil
        } else {
          nowPlaying.volume = target
        }
      }
    } else if let error {
      musicError = error
    }
  }

  public mutating func cycleTheme() {
    let index = Theme.all.firstIndex(of: theme).map { ($0 + 1) % Theme.all.count } ?? 0
    theme = Theme.all[index]
    themeStore.save(theme)
    status = "Theme: \(theme.name)"
    statusShownAt = Date()
  }

  public mutating func applyLibrarySearchResult(query: String, songs: [Song]?, error: String?) {
    guard query == trackQuery else { return }
    trackSearching = false
    if let songs {
      tracks = songs
      trackCursor = 0
      status = songs.isEmpty ? "No library tracks match \"\(query)\"." : "Found \(songs.count) library track(s)."
    } else {
      tracks = []
      status = "Library search failed: \(error ?? "Unknown error")"
    }
    // Playing a new track is only started once the user presses ENTER, so the
    // status must not be overwritten by a stale operation result.
    status = ""
  }

  public mutating func applyPlaylistResult(_ value: [String]?, error: String?) {
    playlistsLoading = false
    if let value {
      playlists = value
      playlistsLoaded = true
      playlistCursor = clamp(playlistCursor, min: 0, max: filteredPlaylists.count - 1)
      status = "Loaded \(value.count) playlist(s)."
    } else {
      playlistsLoaded = false
      status = "Could not load playlists: \(error ?? "Unknown error")"
    }
  }

  public mutating func applyCatalogSearchResult(
    query: String, songs: [Song]?, error: String?
  ) {
    // Ignore results for an older query if a newer search is already active.
    guard query == catalogQuery else { return }
    catalogSearching = false
    if let songs {
      results = songs
      resultCursor = 0
      status = songs.isEmpty ? "No results found." : "Found \(songs.count) catalog results."
      for song in songs where song.duration > 0 {
        durationHints[trackKey(name: song.name, artist: song.artist)] = song.duration
      }
      // Hints are only a fallback for the track that is playing right now, so cap
      // the map rather than letting a long session of searches grow it forever.
      if durationHints.count > 512 { durationHints.removeAll(keepingCapacity: true) }
    } else {
      results = []
      status = "Catalog search failed: \(error ?? "Unknown error")"
    }
  }

  public mutating func applyCommandResult(message: String, error: String?) {
    status = error.map { "Error: \($0)" } ?? message
    statusShownAt = Date()
  }

  public mutating func takePendingCommands() -> [PendingAppCommand] {
    let commands = pendingCommands
    pendingCommands.removeAll(keepingCapacity: true)
    return commands
  }

  @discardableResult
  public mutating func handle(_ input: InputKey) -> KeyAction {
    let key: String
    switch input {
    case .character(let value): key = value
    case .space: key = " "
    case .enter: key = "ENTER"
    case .escape: key = "ESC"
    case .backspace: key = "BACKSPACE"
    case .tab: key = "TAB"
    case .up: key = "UP"
    case .down: key = "DOWN"
    case .left: key = "LEFT"
    case .right: key = "RIGHT"
    }

    let typing = playlistTyping || trackTyping || catalogTyping
    if helpVisible {
      if key == "?" || key == "ESC" { helpVisible = false }
      return .continueRunning
    }
    if !typing && key == "?" {
      helpVisible = true
      return .continueRunning
    }

    // q and Q mean the same in every mode, so they are handled once here rather
    // than repeated in each mode switch.
    if !typing {
      if key == "q" { return .quitApplication }
      if key == "Q" {
        enqueue(.quitMusic, message: "Quitting Music…", quitAfterSuccess: true)
        return .continueRunning
      }
    }

    switch mode {
    case .player: return handlePlayer(key)
    case .library: return handleLibrary(key)
    case .catalog: return handleCatalog(key)
    }
  }

  public mutating func normalizeNowPlaying(_ original: NowPlaying, now: Date = Date()) -> NowPlaying
  {
    var current = original
    guard !current.name.isEmpty else { return current }
    let key = trackKey(name: current.name, artist: current.artist)
    if !current.durationAvailable || current.duration == 0, let hint = durationHints[key], hint > 0
    {
      current.duration = hint
      current.durationAvailable = true
      if current.timingSource.isEmpty { current.timingSource = "Apple catalog metadata" }
    }
    guard current.timingSource == "MediaRemote library", current.positionAvailable else {
      return current
    }

    let trackChanged = key != remoteTrackKey
    let stateChanged = current.state != remoteState
    if trackChanged || stateChanged || remoteAt == .distantPast {
      remoteTrackKey = key
      remoteState = current.state
      remotePosition = current.position
      remoteRawPosition = current.position
      remoteAt = now
      return current
    }

    if current.state == "playing" {
      let raw = current.position
      let estimated = remotePosition + max(0, Int(now.timeIntervalSince(remoteAt)))
      let sourceChanged = raw != remoteRawPosition
      let sampleMatchesClock = abs(raw - estimated) <= 2
      let jumpedForward = raw > estimated + 3
      let jumpedBackward = raw < remoteRawPosition - 2

      // Do not re-anchor on an unchanged stale sample. In particular, a
      // repeated zero at the beginning of a track must not reset the clock
      // every polling cycle, or elapsed time never gets past 0:00.
      if sourceChanged && (sampleMatchesClock || jumpedForward || jumpedBackward) {
        remotePosition = raw
        remoteAt = now
        current.position = raw
      } else {
        current.position = estimated
      }
      remoteRawPosition = raw
    } else {
      remotePosition = current.position
      remoteRawPosition = current.position
      remoteAt = now
    }
    remoteState = current.state
    return current
  }

  private mutating func handlePlayer(_ key: String) -> KeyAction {
    switch key {
    case "TAB", "l":
      mode = .library
      if !playlistsLoaded && !playlistsLoading {
        playlistsLoading = true
        status = "Loading playlists…"
        pendingCommands.append(PendingAppCommand(command: .loadPlaylists, message: status))
      }
    case "/":
      mode = .catalog
      catalogDraft = catalogQuery
      catalogTyping = true
      status = "Type a song, artist, or album name."
    case " ": enqueue(.playPause, message: "Toggling playback…")
    case "n", "RIGHT": enqueue(.next, message: "Skipping to the next track…")
    case "p", "LEFT": enqueue(.previous, message: "Moving to the previous track…")
    case "+", "=", "UP": adjustVolume(5)
    case "-", "_", "DOWN": adjustVolume(-5)
    case "f": enqueue(.seek(10), message: "Seeking forward 10 seconds…")
    case "b": enqueue(.seek(-10), message: "Seeking back 10 seconds…")
    case "s": enqueue(.toggleShuffle, message: "Toggling shuffle…")
    case "t": cycleTheme()
    default: break
    }
    return .continueRunning
  }

  /// Steps the volume from the last value we asked for, so pressing `+` several
  /// times in a row is not collapsed into one step by a stale poll reading.
  private mutating func adjustVolume(_ delta: Int) {
    let volume = clamp((volumeTarget ?? nowPlaying.volume) + delta, min: 0, max: 100)
    volumeTarget = volume
    nowPlaying.volume = volume
    enqueue(.setVolume(volume), message: "Setting volume to \(volume)%…")
  }

  /// Applies one keystroke to a search draft: backspace deletes, space and
  /// printable characters append. Returns nil for keys the caller handles
  /// itself, so the three typing modes share a single edit rule.
  private static func editedDraft(_ key: String, from draft: String) -> String? {
    switch key {
    case "BACKSPACE": return String(draft.dropLast())
    case " ": return draft + " "
    default: return key.count == 1 ? draft + key : nil
    }
  }

  private mutating func handleLibrary(_ key: String) -> KeyAction {
    if trackTyping {
      switch key {
      case "ESC":
        trackTyping = false
        trackDraft = ""
      case "ENTER":
        let query = trackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        trackTyping = false
        guard !query.isEmpty else {
          status = "Enter a track, artist, or album name first."
          return .continueRunning
        }
        trackQuery = query
        showingTracks = true
        trackSearching = true
        status = "Searching your library…"
        pendingCommands.append(
          PendingAppCommand(command: .searchLibrary(query), message: status))
      default: if let edited = Self.editedDraft(key, from: trackDraft) { trackDraft = edited }
      }
      return .continueRunning
    }
    if playlistTyping {
      switch key {
      case "ESC":
        playlistTyping = false
        playlistDraft = ""
      case "ENTER":
        playlistFilter = playlistDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        playlistTyping = false
        playlistCursor = 0
        status = "\(filteredPlaylists.count) playlist(s) match."
      default: if let edited = Self.editedDraft(key, from: playlistDraft) { playlistDraft = edited }
      }
      return .continueRunning
    }
    switch key {
    case "ESC":
      if showingTracks {
        showingTracks = false
        status = ""
      } else if !playlistFilter.isEmpty {
        playlistFilter = ""
        playlistDraft = ""
        playlistCursor = 0
        status = "Playlist filter cleared."
      } else {
        mode = .player
      }
    case "TAB", "l": mode = .player
    case "t":
      showingTracks = true
      trackTyping = true
      trackDraft = ""
      status = "Search your library by track, artist, or album."
    case "/":
      if showingTracks {
        trackTyping = true
        trackDraft = trackQuery
        status = "Search your library by track, artist, or album."
      } else {
        playlistTyping = true
        playlistDraft = ""
        status = "Search playlists by name."
      }
    case "UP", "k":
      if showingTracks {
        trackCursor = max(0, trackCursor - 1)
      } else {
        playlistCursor = max(0, playlistCursor - 1)
      }
    case "DOWN", "j":
      if showingTracks {
        trackCursor = min(max(0, tracks.count - 1), trackCursor + 1)
      } else {
        playlistCursor = min(max(0, filteredPlaylists.count - 1), playlistCursor + 1)
      }
    case "ENTER":
      if showingTracks {
        guard !tracks.isEmpty else {
          status = "No library tracks match this search."
          return .continueRunning
        }
        let song = tracks[clamp(trackCursor, min: 0, max: tracks.count - 1)]
        mode = .player
        enqueue(.playSong(song), message: "Playing: \(song.name) — \(song.artist)…")
        return .continueRunning
      }
      let items = filteredPlaylists
      guard !items.isEmpty else {
        status = "No matching playlists."
        return .continueRunning
      }
      let name = items[clamp(playlistCursor, min: 0, max: items.count - 1)]
      mode = .player
      enqueue(.playPlaylist(name), message: "Playing playlist: \(name)…")
    default: break
    }
    return .continueRunning
  }

  private mutating func handleCatalog(_ key: String) -> KeyAction {
    if catalogTyping {
      switch key {
      case "ESC":
        catalogTyping = false
        mode = .player
      case "ENTER":
        let query = catalogDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
          status = "Enter a search query first."
          return .continueRunning
        }
        catalogQuery = query
        catalogTyping = false
        catalogSearching = true
        status = "Searching the Apple Music catalog…"
        pendingCommands.append(
          PendingAppCommand(command: .searchCatalog(query), message: status))
      case "DOWN": if !results.isEmpty { catalogTyping = false }
      default: if let edited = Self.editedDraft(key, from: catalogDraft) { catalogDraft = edited }
      }
      return .continueRunning
    }
    switch key {
    case "ESC": mode = .player
    case "/", "TAB":
      catalogTyping = true
      catalogDraft = catalogQuery
    case "UP", "k": resultCursor = max(0, resultCursor - 1)
    case "DOWN", "j": resultCursor = min(max(0, results.count - 1), resultCursor + 1)
    case "ENTER":
      guard !results.isEmpty else { return .continueRunning }
      let song = results[clamp(resultCursor, min: 0, max: results.count - 1)]
      mode = .player
      enqueue(.playSong(song), message: "Playing: \(song.name) — \(song.artist)…")
    default: break
    }
    return .continueRunning
  }

  private mutating func enqueue(
    _ command: AppCommand, message: String, quitAfterSuccess: Bool = false
  ) {
    status = message
    pendingCommands.append(
      PendingAppCommand(command: command, message: message, quitAfterSuccess: quitAfterSuccess))
  }
}
