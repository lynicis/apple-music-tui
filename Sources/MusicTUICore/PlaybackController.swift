import Foundation
import MediaRemoteAdapter

public final class AppleMusicController: MusicControlling {
  public init() {}

  public func initialize() throws -> NowPlaying {
    let running = try runAppleScript(AppleScript.musicRunning)
    if running != "true" {
      _ = try runProcess("/usr/bin/open", arguments: ["-gj", "-a", "Music"])
    }

    let deadline = Date().addingTimeInterval(10)
    var lastError: Error?
    while Date() < deadline {
      do {
        let snapshot = try nowPlaying()
        if snapshot.state != "notrunning" {
          try? hideMusic()
          return snapshot
        }
      } catch { lastError = error }
      Thread.sleep(forTimeInterval: 0.25)
    }
    if let lastError {
      throw MusicTUIError.commandFailed(
        "Music did not become ready: \(lastError.localizedDescription)")
    }
    throw MusicTUIError.musicNotReady
  }

  public func nowPlaying() throws -> NowPlaying {
    var current = try Self.parseNowPlayingResponse(runAppleScript(AppleScript.nowPlaying))
    guard current.state != "notrunning" else { return current }

    let needsRemote =
      current.name.isEmpty || current.artist.isEmpty || current.album.isEmpty
      || !current.positionAvailable || !current.durationAvailable || current.duration == 0
      || (current.state == "playing" && current.position == 0)
    guard needsRemote else { return current }

    do {
      let remote = try readMediaRemote(expectedTitle: current.name)
      if current.name.isEmpty { current.name = remote.name }
      if current.artist.isEmpty { current.artist = remote.artist }
      if current.album.isEmpty { current.album = remote.album }
      if remote.positionAvailable
        && (!current.positionAvailable || (current.position == 0 && remote.position > 0))
      {
        current.position = remote.position
        current.positionAvailable = true
        current.timingSource = "MediaRemote library"
      }
      if remote.durationAvailable && (!current.durationAvailable || current.duration == 0) {
        current.duration = remote.duration
        current.durationAvailable = true
        current.timingSource = "MediaRemote library"
      }
      if !current.positionAvailable || !current.durationAvailable || current.duration == 0 {
        current.timingDiagnostic =
          "MediaRemote library did not provide both elapsed time and duration"
      } else {
        current.timingDiagnostic = ""
      }
    } catch {
      if !current.positionAvailable || !current.durationAvailable || current.duration == 0
        || (current.state == "playing" && current.position == 0)
      {
        current.timingDiagnostic = error.localizedDescription
      }
    }
    current.position = max(0, current.position)
    current.duration = max(0, current.duration)
    return current
  }

  public func playlists() throws -> [String] {
    return try runAppleScript(AppleScript.playlists)
      .components(separatedBy: "\u{1E}")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  public func playPause() throws { try perform(AppleScript.playPause) }
  public func next() throws { try perform(AppleScript.next) }
  public func previous() throws { try perform(AppleScript.previous) }

  public func setVolume(_ volume: Int) throws {
    try perform(AppleScript.setVolume(volume))
  }

  public func seek(_ seconds: Int) throws {
    try perform(AppleScript.seek(by: seconds))
  }

  public func toggleShuffle() throws {
    try perform(AppleScript.toggleShuffle)
  }

  public func playPlaylist(_ name: String) throws {
    try perform(AppleScript.playPlaylist(name))
  }

  /// Searches the user's library by track, artist, or album name. Results come
  /// back with a persistent ID so they can be played without re-resolving names.
  public func searchLibrary(_ query: String) throws -> [Song] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }
    return Self.parseLibrarySearchRows(try runAppleScript(AppleScript.searchLibrary(term)))
  }

  public static func parseLibrarySearchRows(_ output: String) -> [Song] {
    output.components(separatedBy: "\u{1E}").compactMap { row in
      let fields = row.components(separatedBy: "\u{1F}")
      guard fields.count == 4 else { return nil }
      let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let identifier = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, !identifier.isEmpty else { return nil }
      return Song(
        name: name, artist: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
        album: fields[2].trimmingCharacters(in: .whitespacesAndNewlines), url: "",
        libraryID: identifier)
    }
  }

  public func playLibraryTrack(_ identifier: String) throws {
    guard !identifier.isEmpty else {
      throw MusicTUIError.invalidResponse("Missing library track identifier.")
    }
    try perform(AppleScript.playLibraryTrack(identifier))
  }

  /// Plays a song, preferring the user's own copy: a library track by persistent
  /// ID, else a same-titled library match, else the catalog link. When Music
  /// ignores the catalog link we say so instead of reporting a false success.
  public func play(_ song: Song) throws {
    if !song.libraryID.isEmpty {
      try playLibraryTrack(song.libraryID)
      return
    }
    if let local = try? libraryMatch(for: song) {
      try playLibraryTrack(local.libraryID)
      return
    }
    try openCatalogURL(song.url)
    try confirmPlaybackStarted(song)
  }

  private func libraryMatch(for song: Song) throws -> Song? {
    try searchLibrary(song.name).first { sameTrackTitle($0.name, song.name) }
  }

  private func confirmPlaybackStarted(_ song: Song) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if currentPlayerState() == "playing" {
        try? hideMusic()
        return
      }
      Thread.sleep(forTimeInterval: 0.3)
    }
    // AppleScript can report stale state for streamed tracks on recent macOS
    // releases, so ask MediaRemote before declaring failure.
    if let remote = try? readMediaRemote(expectedTitle: song.name), remote.playing {
      try? hideMusic()
      return
    }
    // Worded as "could not confirm" because macOS can report a stale player
    // state for streamed tracks, so this is not proof that nothing is playing.
    throw MusicTUIError.commandFailed(
      "Music did not report playback starting for “\(song.name)”. If nothing plays, the track is unavailable for this Apple Music account or region — press Tab then `t` to search your library for a copy."
    )
  }

  private func currentPlayerState() -> String {
    let output = try? runAppleScript(AppleScript.playerState)
    return output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func openCatalogURL(_ rawURL: String) throws {
    guard var components = URLComponents(string: rawURL),
      components.scheme == "https",
      ["music.apple.com", "itunes.apple.com"].contains(components.host?.lowercased() ?? "")
    else {
      throw MusicTUIError.invalidCatalogURL
    }
    components.scheme = "music"
    components.queryItems = components.queryItems?.filter { $0.name != "uo" }
    guard let musicURL = components.string else { throw MusicTUIError.invalidCatalogURL }
    try perform(AppleScript.openCatalog(musicURL))
  }

  public func quitMusic() throws {
    _ = try runAppleScript(AppleScript.quitMusic)
  }

  private func perform(_ script: String) throws {
    _ = try runAppleScript(script)
    try? hideMusic()
  }

  private func hideMusic() throws {
    do {
      _ = try runAppleScript(AppleScript.hideMusic)
    } catch {
      _ = try runAppleScript(AppleScript.closeMusicWindows)
    }
  }

  private func runAppleScript(_ script: String) throws -> String {
    try runProcess("/usr/bin/osascript", arguments: ["-e", script]).trimmingCharacters(
      in: .newlines)
  }

  private func runProcess(_ executable: String, arguments: [String]) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw MusicTUIError.commandNotFound(executable)
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch { throw MusicTUIError.commandFailed(error.localizedDescription) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
      throw MusicTUIError.commandFailed(message.isEmpty ? "Command failed: \(executable)" : message)
    }
    return text
  }

  struct RemoteSnapshot {
    var name = ""
    var artist = ""
    var album = ""
    var position = 0
    var duration = 0
    var positionAvailable = false
    var durationAvailable = false
    var playing = false
  }

  private let mediaRemote = MediaController()

  /// Reads the system-wide "now playing" session through the
  /// `mediaremote-adapter` package, which builds and ships the MediaRemote
  /// adapter library and its Perl bridge, so no Homebrew install is required.
  private func readMediaRemote(expectedTitle: String) throws -> RemoteSnapshot {
    guard let payload = try fetchRemotePayload() else {
      throw MusicTUIError.invalidResponse("MediaRemote reported no active media session.")
    }
    let snapshot = Self.remoteSnapshot(
      title: payload.title ?? "",
      artist: payload.artist ?? "",
      album: payload.album ?? "",
      elapsedSeconds: payload.currentElapsedTime,
      durationSeconds: payload.durationMicros.map { $0 / 1_000_000 },
      playing: payload.isPlaying ?? false)
    let (valid, reason) = Self.validMusicSnapshot(
      snapshot, bundleIdentifier: payload.bundleIdentifier ?? "", expectedTitle: expectedTitle)
    guard valid else {
      throw MusicTUIError.invalidResponse(
        reason.isEmpty ? "MediaRemote returned a different media session." : reason)
    }
    guard snapshot.positionAvailable || snapshot.durationAvailable else {
      throw MusicTUIError.invalidResponse(
        "MediaRemote returned the matching track without timing fields.")
    }
    return snapshot
  }

  /// Runs the adapter's one-shot query and waits for its reply. The adapter
  /// delivers callbacks on the main queue, so when the caller is already the
  /// main thread we service the run loop instead of blocking it dead.
  private func fetchRemotePayload(timeout: TimeInterval = 8) throws -> TrackInfo.Payload? {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var received = false
    var payload: TrackInfo.Payload?

    mediaRemote.getTrackInfo { info in
      lock.lock()
      payload = info?.payload
      received = true
      lock.unlock()
      semaphore.signal()
    }

    if Thread.isMainThread {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if semaphore.wait(timeout: .now()) == .success { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
    } else {
      _ = semaphore.wait(timeout: .now() + .milliseconds(Int(timeout * 1_000)))
    }

    lock.lock()
    defer { lock.unlock() }
    guard received else {
      throw MusicTUIError.commandFailed(
        "The MediaRemote adapter did not respond within \(Int(timeout)) seconds.")
    }
    return payload
  }

  /// Maps the adapter payload onto the fields the player needs. `elapsedSeconds`
  /// is the adapter's timestamp-adjusted position, so reopening MusicTUI while
  /// Music keeps playing resumes at the real position instead of 0:00.
  static func remoteSnapshot(
    title: String, artist: String, album: String,
    elapsedSeconds: Double?, durationSeconds: Double?, playing: Bool
  ) -> RemoteSnapshot {
    var result = RemoteSnapshot()
    result.name = title
    result.artist = artist
    result.album = album
    if let elapsed = elapsedSeconds, elapsed >= 0 {
      result.position = Int(elapsed.rounded())
      result.positionAvailable = true
    }
    if let duration = durationSeconds, duration >= 0 {
      result.duration = Int(duration.rounded())
      result.durationAvailable = true
    }
    result.playing = playing
    return result
  }

  /// The adapter reports the system-wide session, so anything that is not the
  /// Music app must be rejected before its metadata is used.
  static func validMusicSnapshot(
    _ snapshot: RemoteSnapshot, bundleIdentifier: String, expectedTitle: String
  ) -> (Bool, String) {
    if !expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard sameTrackTitle(snapshot.name, expectedTitle) else {
        return (
          false,
          "MediaRemote track does not match Music: got \(snapshot.name.debugDescription), expected \(expectedTitle.debugDescription)"
        )
      }
      return (true, "")
    }
    guard bundleIdentifier.caseInsensitiveCompare("com.apple.Music") == .orderedSame else {
      return (
        false,
        "MediaRemote could not confirm the media session belongs to Music (bundle identifier \(bundleIdentifier.debugDescription) and AppleScript title is unavailable)"
      )
    }
    guard !snapshot.name.isEmpty else {
      return (false, "MediaRemote returned no track title")
    }
    return (true, "")
  }

  public static func parseNowPlayingResponse(_ output: String) throws -> NowPlaying {
    if output == "notrunning" { return NowPlaying(state: "notrunning") }
    let fields = output.components(separatedBy: "\u{1F}")
    guard fields.count == 11 else {
      throw MusicTUIError.invalidResponse("Unexpected response from Music: \(output)")
    }
    var result = NowPlaying()
    result.state = fields[0]
    result.volume = Int(fields[1]) ?? 0
    result.shuffle = fields[2] == "true"
    result.name = fields[3]
    result.artist = fields[4]
    result.album = fields[5]
    (result.position, result.positionAvailable) = parseSeconds(
      fields[6], reportedAvailable: fields[7] == "true")
    (result.duration, result.durationAvailable) = parseSeconds(
      fields[8], reportedAvailable: fields[9] == "true")
    if !result.durationAvailable, let clock = parseClock(fields[10]) {
      result.duration = clock
      result.durationAvailable = true
      result.timingSource = "AppleScript track time"
    }
    if result.positionAvailable || result.durationAvailable { result.timingSource = "AppleScript" }
    return result
  }

  public static func parseSeconds(_ raw: String, reportedAvailable: Bool) -> (Int, Bool) {
    guard reportedAvailable,
      let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0
    else { return (0, false) }
    return (Int(value.rounded()), true)
  }

  public static func parseClock(_ raw: String) -> Int? {
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
    guard parts.count == 2 || parts.count == 3 else { return nil }
    let values = parts.compactMap { Int($0) }
    guard values.count == parts.count, values.allSatisfy({ $0 >= 0 }) else { return nil }
    return values.count == 2
      ? values[0] * 60 + values[1] : values[0] * 3600 + values[1] * 60 + values[2]
  }

}
