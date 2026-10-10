import Darwin
import XCTest

@testable import MusicTUICore

final class MusicTUICoreTests: XCTestCase {
  func testTerminalOutputWritesWholeFrameThroughPOSIXFileDescriptor() throws {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&descriptors), 0)
    defer {
      _ = close(descriptors[0])
      _ = close(descriptors[1])
    }

    let expected = Data("\u{001B}[HMusicTUI frame\n\u{001B}[J".utf8)
    try TerminalOutput.writeAll(expected, to: descriptors[1])

    var bytes = [UInt8](repeating: 0, count: expected.count)
    let count = bytes.withUnsafeMutableBytes { buffer -> Int in
      return Darwin.read(descriptors[0], buffer.baseAddress, buffer.count)
    }
    XCTAssertEqual(count, expected.count)
    XCTAssertEqual(Data(bytes), expected)
  }

  func testTerminalOutputRetriesWhenNonblockingPipeReturnsWouldBlock() throws {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&descriptors), 0)
    defer {
      _ = close(descriptors[0])
      _ = close(descriptors[1])
    }

    let writeFlags = fcntl(descriptors[1], F_GETFL)
    XCTAssertGreaterThanOrEqual(writeFlags, 0)
    XCTAssertEqual(fcntl(descriptors[1], F_SETFL, writeFlags | O_NONBLOCK), 0)
    let readFlags = fcntl(descriptors[0], F_GETFL)
    XCTAssertGreaterThanOrEqual(readFlags, 0)
    XCTAssertEqual(fcntl(descriptors[0], F_SETFL, readFlags | O_NONBLOCK), 0)

    // Fill the pipe completely, backing the chunk size down to one byte so
    // the initial EAGAIN isn't merely caused by a chunk larger than free space.
    var chunkSize = 4_096
    while true {
      let chunk = [UInt8](repeating: 0, count: chunkSize)
      let count = chunk.withUnsafeBytes { buffer -> Int in
        return Darwin.write(descriptors[1], buffer.baseAddress, buffer.count)
      }
      if count > 0 { continue }
      if errno == EINTR { continue }
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && chunkSize > 1 {
        chunkSize = max(1, chunkSize / 2)
        continue
      }
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
      XCTFail("Unexpected pipe write result while filling pipe: \(count), errno \(errno)")
      return
    }

    let drained = expectation(description: "pipe becomes writable after reader drains it")
    let readDescriptor = descriptors[0]
    DispatchQueue.global().async {
      var bytes = [UInt8](repeating: 0, count: 4_096)
      _ = bytes.withUnsafeMutableBytes { buffer in
        return Darwin.read(readDescriptor, buffer.baseAddress, buffer.count)
      }
      drained.fulfill()
    }

    let expected = Data("retry-after-EAGAIN".utf8)
    try TerminalOutput.writeAll(expected, to: descriptors[1])
    wait(for: [drained], timeout: 2)

    var remainder = Data()
    while true {
      var bytes = [UInt8](repeating: 0, count: 8_192)
      let count = bytes.withUnsafeMutableBytes { buffer -> Int in
        return Darwin.read(descriptors[0], buffer.baseAddress, buffer.count)
      }
      if count > 0 {
        remainder.append(contentsOf: bytes.prefix(count))
      } else if count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        break
      } else if errno != EINTR {
        XCTFail("Unexpected pipe read result while draining: \(count), errno \(errno)")
        break
      }
    }
    XCTAssertTrue(remainder.suffix(expected.count).elementsEqual(expected))
  }

  func testTimeFormattingAndUnavailableValues() {
    XCTAssertEqual(formatTime(187), "3:07")
    XCTAssertEqual(formatTime(-3), "0:00")
    XCTAssertEqual(availableTime(0, available: false), "--:--")
    XCTAssertEqual(availableTime(0, available: true), "0:00")
  }

  func testMusicRunningAppleScriptUsesMultilineConditional() {
    let lines = AppleMusicController.musicRunningScript
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    XCTAssertTrue(lines.contains("if application \"Music\" is running then"))
    XCTAssertTrue(lines.contains("else"))
    XCTAssertTrue(lines.contains("end if"))
    XCTAssertFalse(lines.contains(where: { $0.contains("else return") }))
  }

  func testParseAppleScriptResponseDistinguishesMissingTimingFromZero() throws {
    let fields = [
      "playing", "80", "false", "Track", "Artist", "Album", "", "false", "", "false", "",
    ]
    let result = try AppleMusicController.parseNowPlayingResponse(
      fields.joined(separator: "\u{1F}"))
    XCTAssertEqual(result.name, "Track")
    XCTAssertFalse(result.positionAvailable)
    XCTAssertFalse(result.durationAvailable)
  }

  func testParseAppleScriptFractionalSecondsAndClockFallback() throws {
    let fields = [
      "playing", "80", "true", "Track", "Artist", "Album", "42.4", "true", "", "false", "3:26",
    ]
    let result = try AppleMusicController.parseNowPlayingResponse(
      fields.joined(separator: "\u{1F}"))
    XCTAssertEqual(result.position, 42)
    XCTAssertTrue(result.positionAvailable)
    XCTAssertEqual(result.duration, 206)
    XCTAssertTrue(result.durationAvailable)
  }

  func testRemoteSnapshotMapsAdapterTiming() {
    let snapshot = AppleMusicController.remoteSnapshot(
      title: "Nocturne", artist: "Artist", album: "Piano Works",
      elapsedSeconds: 137.6, durationSeconds: 245, playing: true)
    XCTAssertEqual(snapshot.name, "Nocturne")
    XCTAssertEqual(snapshot.position, 138)
    XCTAssertTrue(snapshot.positionAvailable)
    XCTAssertEqual(snapshot.duration, 245)
    XCTAssertTrue(snapshot.durationAvailable)
    XCTAssertTrue(snapshot.playing)
  }

  func testRemoteSnapshotMarksMissingTimingUnavailable() {
    let snapshot = AppleMusicController.remoteSnapshot(
      title: "Nocturne", artist: "Artist", album: "Piano Works",
      elapsedSeconds: nil, durationSeconds: nil, playing: false)
    XCTAssertFalse(snapshot.positionAvailable)
    XCTAssertFalse(snapshot.durationAvailable)
    XCTAssertFalse(snapshot.playing)
  }

  func testNormalizeTitleIgnoresPunctuationAndCase() {
    XCTAssertTrue(sameTrackTitle("Funeral March: Lento", "FUNERAL-MARCH lento"))
    XCTAssertFalse(sameTrackTitle("Different Song", "Funeral March"))
  }

  func testCatalogDurationHintFillsMissingDuration() {
    var model = AppModel()
    model.durationHints[trackKey(name: "Nocturne", artist: "Artist")] = 245
    let current = NowPlaying(name: "Nocturne", artist: "Artist")
    let normalized = model.normalizeNowPlaying(current)
    XCTAssertEqual(normalized.duration, 245)
    XCTAssertTrue(normalized.durationAvailable)
    XCTAssertEqual(normalized.timingSource, "Apple catalog metadata")
  }

  func testRemoteSnapshotAcceptsMusicTitleMatch() {
    let snapshot = AppleMusicController.remoteSnapshot(
      title: "Piano Sonata No. 2, Funeral March", artist: "Istvan Szekely",
      album: "Chopin Sonatas", elapsedSeconds: 44.2, durationSeconds: 564.7, playing: true)
    let validation = AppleMusicController.validMusicSnapshot(
      snapshot, bundleIdentifier: "com.apple.Music",
      expectedTitle: "Piano Sonata No. 2 Funeral March")
    XCTAssertTrue(validation.0, validation.1)
  }

  func testRemoteSnapshotRejectsAnotherAppsSession() {
    // The adapter reports the system-wide session, so a Safari video must not be
    // mistaken for Music when AppleScript returned no title to match against.
    let snapshot = AppleMusicController.remoteSnapshot(
      title: "Some Video", artist: "Some Channel", album: "",
      elapsedSeconds: 12, durationSeconds: 290, playing: true)
    let validation = AppleMusicController.validMusicSnapshot(
      snapshot, bundleIdentifier: "com.apple.WebKit.GPU", expectedTitle: "")
    XCTAssertFalse(validation.0)
  }

  func testStaleMediaRemotePositionIsInterpolated() {
    var model = AppModel()
    let start = Date(timeIntervalSince1970: 10_000)
    let original = NowPlaying(
      state: "playing", name: "Nocturne", artist: "Artist", position: 80,
      duration: 245, positionAvailable: true, durationAvailable: true,
      timingSource: "MediaRemote library"
    )
    _ = model.normalizeNowPlaying(original, now: start)
    let later = model.normalizeNowPlaying(original, now: start.addingTimeInterval(4))
    XCTAssertGreaterThanOrEqual(later.position, 83)
  }

  func testRepeatedZeroMediaRemoteSamplesStillAdvanceElapsedTime() {
    var model = AppModel()
    let start = Date(timeIntervalSince1970: 20_000)
    let stale = NowPlaying(
      state: "playing", name: "Piano Sonata", artist: "Artist", position: 0,
      duration: 564, positionAvailable: true, durationAvailable: true,
      timingSource: "MediaRemote library"
    )
    _ = model.normalizeNowPlaying(stale, now: start)
    _ = model.normalizeNowPlaying(stale, now: start.addingTimeInterval(1))
    let later = model.normalizeNowPlaying(stale, now: start.addingTimeInterval(10))
    XCTAssertEqual(
      later.position, 10, "unchanged zero samples must not reset the interpolation anchor")
  }

  func testHelpOverlayOpensAndClosesWithQuestionMarkOrEscape() {
    let music = FakeMusicController()
    let catalog = FakeCatalogSearch()
    var model = AppModel()
    XCTAssertFalse(model.helpVisible)
    _ = model.handle(.character("?"), music: music, catalog: catalog)
    XCTAssertTrue(model.helpVisible)
    _ = model.handle(.escape, music: music, catalog: catalog)
    XCTAssertFalse(model.helpVisible)
    _ = model.handle(.character("?"), music: music, catalog: catalog)
    XCTAssertTrue(model.helpVisible)
    _ = model.handle(.character("?"), music: music, catalog: catalog)
    XCTAssertFalse(model.helpVisible)
  }

  func testPlaybackKeyQueuesCommandWithoutBlockingOnMusicController() {
    let music = FakeMusicController()
    var model = AppModel()

    _ = model.handle(.space, music: music, catalog: FakeCatalogSearch())

    XCTAssertEqual(music.playPauseCount, 0, "key handling must not synchronously call Music")
    XCTAssertEqual(model.status, "Toggling playback…")
    XCTAssertEqual(
      model.takePendingCommands(),
      [
        PendingAppCommand(command: .playPause, message: "Toggling playback…")
      ])
    XCTAssertEqual(music.playPauseCount, 0)
  }

  func testOpeningLibraryQueuesPlaylistLoadWithoutBlocking() {
    let music = FakeMusicController()
    var model = AppModel()

    _ = model.handle(.tab, music: music, catalog: FakeCatalogSearch())

    XCTAssertEqual(model.mode, .library)
    XCTAssertTrue(model.playlistsLoading)
    XCTAssertEqual(music.playlistsReadCount, 0)
    XCTAssertEqual(
      model.takePendingCommands(),
      [
        PendingAppCommand(command: .loadPlaylists, message: "Loading playlists…")
      ])
  }

  func testCatalogSearchIsQueuedOffTheInputLoop() {
    let catalog = FakeCatalogSearch()
    let music = FakeMusicController()
    var model = AppModel()
    model.mode = .catalog
    model.catalogTyping = true
    model.catalogDraft = "Chopin"

    _ = model.handle(.enter, music: music, catalog: catalog)

    XCTAssertTrue(model.catalogSearching)
    XCTAssertEqual(catalog.searchCount, 0)
    XCTAssertEqual(
      model.takePendingCommands(),
      [
        PendingAppCommand(
          command: .searchCatalog("Chopin"), message: "Searching the Apple Music catalog…")
      ])
  }

  func testRenderedHelpPanelContainsDismissShortcut() {
    var model = AppModel()
    model.helpVisible = true
    let rendered = TerminalView.render(model)
    XCTAssertTrue(rendered.contains("KEYBOARD CONTROLS"))
    XCTAssertTrue(rendered.contains("Press ? or Esc to close this panel."))
  }

  func testQuestionMarkRemainsValidTextWhileSearchIsActive() {
    let music = FakeMusicController()
    let catalog = FakeCatalogSearch()
    var model = AppModel()
    model.mode = .catalog
    model.catalogTyping = true
    _ = model.handle(.character("?"), music: music, catalog: catalog)
    XCTAssertFalse(model.helpVisible)
    XCTAssertEqual(model.catalogDraft, "?")
  }

  func testPlaylistFilteringIsCaseInsensitive() {
    var model = AppModel()
    model.playlists = ["Ambient Study", "Road Trip", "Jazz Night"]
    model.playlistFilter = "jAzZ"
    XCTAssertEqual(model.filteredPlaylists, ["Jazz Night"])
  }

  func testCatalogResponseMapsMillisToSeconds() throws {
    let data = Data(
      #"{"results":[{"trackName":"Track","artistName":"Artist","collectionName":"Album","trackViewUrl":"https://music.apple.com/us/song/123","trackTimeMillis":125500}]}"#
        .utf8)
    let results = try CatalogSearchClient.parseResponse(data)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results[0].name, "Track")
    XCTAssertEqual(results[0].artist, "Artist")
    XCTAssertEqual(results[0].album, "Album")
    XCTAssertEqual(results[0].duration, 126)
  }

  func testRapidVolumePressesAccumulateInsteadOfRepeatingOneStep() {
    let music = FakeMusicController()
    var model = AppModel()
    model.nowPlaying.volume = 60

    for _ in 0..<8 { _ = model.handle(.character("+"), music: music, catalog: FakeCatalogSearch()) }

    XCTAssertEqual(model.nowPlaying.volume, 100, "the display should follow the last request")
    let requested = model.takePendingCommands().compactMap { pending -> Int? in
      guard case .setVolume(let volume) = pending.command else { return nil }
      return volume
    }
    XCTAssertEqual(requested, [65, 70, 75, 80, 85, 90, 95, 100])
  }

  func testPendingVolumeSurvivesAStalePollAndStillStepsFromTheRequest() {
    let music = FakeMusicController()
    var model = AppModel()
    model.nowPlaying.volume = 60

    _ = model.handle(.character("+"), music: music, catalog: FakeCatalogSearch())
    model.applyNowPlayingResult(NowPlaying(state: "playing", volume: 60), error: nil)
    _ = model.handle(.character("+"), music: music, catalog: FakeCatalogSearch())

    XCTAssertEqual(model.nowPlaying.volume, 70)
  }

  func testVolumeStopsAtZeroAndFullScale() {
    let music = FakeMusicController()
    var model = AppModel()
    model.nowPlaying.volume = 2
    for _ in 0..<3 { _ = model.handle(.character("-"), music: music, catalog: FakeCatalogSearch()) }
    XCTAssertEqual(model.nowPlaying.volume, 0)
  }

  func testThemeCyclingRemembersTheChoice() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("apple-music-tui-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let music = FakeMusicController()
    var model = AppModel(themeStore: ThemeStore(directory: directory))
    XCTAssertEqual(model.theme, .classic)

    _ = model.handle(.character("t"), music: music, catalog: FakeCatalogSearch())
    XCTAssertEqual(model.theme.name, "mono")
    XCTAssertEqual(ThemeStore(directory: directory).load().name, "mono")

    for _ in 0..<3 { _ = model.handle(.character("t"), music: music, catalog: FakeCatalogSearch()) }
    XCTAssertEqual(model.theme, .classic, "cycling past the last theme must wrap around")
  }

  func testRenderedFrameHasNoBoxDrawing() {
    var model = AppModel()
    model.nowPlaying = NowPlaying(
      state: "playing", volume: 40, name: "Nocturne", artist: "Artist", album: "Piano Works")
    let rendered = TerminalView.render(model)
    for glyph in ["╭", "╮", "╰", "╯", "│"] {
      XCTAssertFalse(rendered.contains(glyph), "grid glyph \(glyph) should be gone")
    }
    XCTAssertTrue(rendered.contains("APPLE MUSIC"))
  }

  func testRenderingUsesTheSelectedTheme() {
    var model = AppModel(
      themeStore: ThemeStore(
        directory: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent(UUID().uuidString)))
    model.theme = .mono
    let rendered = TerminalView.render(model)
    XCTAssertTrue(rendered.contains("\u{001B}[4;97m"), "mono highlight should be used")
    XCTAssertFalse(rendered.contains("\u{001B}[36;1m"), "classic accent should be gone")
  }

  func testLibrarySearchRowsCarryPersistentIDs() {
    let output =
      "Nocturne\u{1F}Artist\u{1F}Piano Works\u{1F}04607E71D32E8D75\u{1E}Bad Row\u{1E}Untitled\u{1F}A\u{1F}B\u{1F}"
    let songs = AppleMusicController.parseLibrarySearchRows(output)
    XCTAssertEqual(songs.count, 1)
    XCTAssertEqual(songs[0].name, "Nocturne")
    XCTAssertEqual(songs[0].libraryID, "04607E71D32E8D75")
    XCTAssertEqual(songs[0].url, "")
  }

  func testTrackSearchIsQueuedOffTheInputLoop() {
    let music = FakeMusicController()
    var model = AppModel()
    model.mode = .library
    model.trackTyping = true
    model.trackDraft = "Nocturne"

    _ = model.handle(.enter, music: music, catalog: FakeCatalogSearch())

    XCTAssertTrue(model.showingTracks)
    XCTAssertTrue(model.trackSearching)
    XCTAssertEqual(
      model.takePendingCommands(),
      [PendingAppCommand(command: .searchLibrary("Nocturne"), message: "Searching your library…")])
  }

  func testEnterOnALibraryTrackQueuesThatTrack() {
    let music = FakeMusicController()
    var model = AppModel()
    model.mode = .library
    model.showingTracks = true
    model.trackQuery = "Nocturne"
    model.applyLibrarySearchResult(
      query: "Nocturne",
      songs: [
        Song(name: "Nocturne", artist: "Artist", album: "Piano Works", url: "", libraryID: "ID1"),
        Song(name: "Ballade", artist: "Artist", album: "Piano Works", url: "", libraryID: "ID2"),
      ], error: nil)

    _ = model.handle(.down, music: music, catalog: FakeCatalogSearch())
    _ = model.handle(.enter, music: music, catalog: FakeCatalogSearch())

    XCTAssertEqual(model.mode, .player)
    XCTAssertEqual(
      model.takePendingCommands(),
      [
        PendingAppCommand(
          command: .playSong(
            Song(name: "Ballade", artist: "Artist", album: "Piano Works", url: "", libraryID: "ID2")),
          message: "Playing: Ballade — Artist…")
      ])
  }

  func testRenderedTrackListShowsLibraryMatches() {
    var model = AppModel()
    model.mode = .library
    model.showingTracks = true
    model.trackQuery = "Nocturne"
    model.applyLibrarySearchResult(
      query: "Nocturne",
      songs: [
        Song(name: "Nocturne", artist: "Artist", album: "Piano Works", url: "", libraryID: "ID1")
      ], error: nil)

    let rendered = TerminalView.render(model)
    XCTAssertTrue(rendered.contains("YOUR LIBRARY TRACKS"))
    XCTAssertTrue(rendered.contains("Nocturne — Artist"))
    XCTAssertTrue(rendered.contains("Found 1 library track(s)."))
  }

  func testEscapeLeavesTheTrackListBeforeTheLibrary() {
    let music = FakeMusicController()
    var model = AppModel()
    model.mode = .library
    model.showingTracks = true

    _ = model.handle(.escape, music: music, catalog: FakeCatalogSearch())
    XCTAssertFalse(model.showingTracks)
    XCTAssertEqual(model.mode, .library)

    _ = model.handle(.escape, music: music, catalog: FakeCatalogSearch())
    XCTAssertEqual(model.mode, .player)
  }

  func testCatalogResponseDropsIncompleteRows() throws {
    let data = Data(
      #"{"results":[{"trackName":"","artistName":"Artist","trackViewUrl":"https://music.apple.com/us/song/123"},{"trackName":"Keep","trackViewUrl":"https://music.apple.com/us/song/456"}]}"#
        .utf8)
    let results = try CatalogSearchClient.parseResponse(data)
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results[0].name, "Keep")
  }
}

private final class FakeMusicController: MusicControlling {
  var playPauseCount = 0
  var playlistsReadCount = 0
  var playedSongs: [Song] = []
  var libraryQueries: [String] = []
  var libraryResults: [Song] = []
  func initialize() throws -> NowPlaying { NowPlaying(state: "paused") }
  func nowPlaying() throws -> NowPlaying { NowPlaying(state: "paused") }
  func playlists() throws -> [String] {
    playlistsReadCount += 1
    return ["Favorites", "Jazz Night"]
  }
  func playPause() throws { playPauseCount += 1 }
  func next() throws {}
  func previous() throws {}
  func setVolume(_ volume: Int) throws {}
  func seek(_ seconds: Int) throws {}
  func toggleShuffle() throws {}
  func playPlaylist(_ name: String) throws {}
  func play(_ song: Song) throws { playedSongs.append(song) }
  func searchLibrary(_ query: String) throws -> [Song] {
    libraryQueries.append(query)
    return libraryResults
  }
  func quitMusic() throws {}
}

private final class FakeCatalogSearch: CatalogSearching {
  var searchCount = 0
  func search(_ query: String) throws -> [Song] {
    searchCount += 1
    return []
  }
}
