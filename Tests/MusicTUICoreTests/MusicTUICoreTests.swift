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

  func testOpenCatalogAppleScriptStartsPlaybackAfterOpeningTheItem() {
    let script = AppleScript.openCatalog("music://music.apple.com/us/album/x/1?i=2")
    XCTAssertTrue(script.contains("open location"), "the catalog link must still be opened")
    XCTAssertTrue(
      script.contains("play"),
      "opening a catalog link alone only shows its page on recent macOS, so playback must be started")
  }

  func testMusicRunningAppleScriptUsesMultilineConditional() {
    let lines = AppleScript.musicRunning
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
    var model = AppModel()
    XCTAssertFalse(model.helpVisible)
    _ = model.handle(.character("?"))
    XCTAssertTrue(model.helpVisible)
    _ = model.handle(.escape)
    XCTAssertFalse(model.helpVisible)
    _ = model.handle(.character("?"))
    XCTAssertTrue(model.helpVisible)
    _ = model.handle(.character("?"))
    XCTAssertFalse(model.helpVisible)
  }

  func testPlaybackKeyQueuesCommandWithoutBlockingOnMusicController() {
    let music = FakeMusicController()
    var model = AppModel()

    _ = model.handle(.space)

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

    _ = model.handle(.tab)

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
    var model = AppModel()
    model.mode = .catalog
    model.catalogTyping = true
    model.catalogDraft = "Chopin"

    _ = model.handle(.enter)

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
    let rendered = TerminalView.render(model).joined(separator: "\n")
    XCTAssertTrue(rendered.contains("KEYBOARD CONTROLS"))
    XCTAssertTrue(rendered.contains("Press ? or Esc to close this panel."))
  }

  func testQuestionMarkRemainsValidTextWhileSearchIsActive() {
    var model = AppModel()
    model.mode = .catalog
    model.catalogTyping = true
    _ = model.handle(.character("?"))
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
    var model = AppModel()
    model.nowPlaying.volume = 60

    for _ in 0..<8 { _ = model.handle(.character("+")) }

    XCTAssertEqual(model.nowPlaying.volume, 100, "the display should follow the last request")
    let requested = model.takePendingCommands().compactMap { pending -> Int? in
      guard case .setVolume(let volume) = pending.command else { return nil }
      return volume
    }
    XCTAssertEqual(requested, [65, 70, 75, 80, 85, 90, 95, 100])
  }

  func testPendingVolumeSurvivesAStalePollAndStillStepsFromTheRequest() {
    var model = AppModel()
    model.nowPlaying.volume = 60

    _ = model.handle(.character("+"))
    model.applyNowPlayingResult(NowPlaying(state: "playing", volume: 60), error: nil)
    _ = model.handle(.character("+"))

    XCTAssertEqual(model.nowPlaying.volume, 70)
  }

  func testVolumeStopsAtZeroAndFullScale() {
    var model = AppModel()
    model.nowPlaying.volume = 2
    for _ in 0..<3 { _ = model.handle(.character("-")) }
    XCTAssertEqual(model.nowPlaying.volume, 0)
  }

  func testThemeCyclingRemembersTheChoice() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("apple-music-tui-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var model = AppModel(themeStore: ThemeStore(directory: directory))
    XCTAssertEqual(model.theme, .classic)

    _ = model.handle(.character("t"))
    XCTAssertEqual(model.theme.name, "mono")
    XCTAssertEqual(ThemeStore(directory: directory).load().name, "mono")

    for _ in 0..<3 { _ = model.handle(.character("t")) }
    XCTAssertEqual(model.theme, .classic, "cycling past the last theme must wrap around")
  }

  func testRenderedFrameHasNoBoxDrawing() {
    var model = AppModel()
    model.nowPlaying = NowPlaying(
      state: "playing", volume: 40, name: "Nocturne", artist: "Artist", album: "Piano Works")
    let rendered = TerminalView.render(model).joined(separator: "\n")
    for glyph in ["╭", "╮", "╰", "╯", "│"] {
      XCTAssertFalse(rendered.contains(glyph), "grid glyph \(glyph) should be gone")
    }
    XCTAssertTrue(rendered.contains("\u{F8FF}  APPLE MUSIC"))
  }

  func testFrameRendererWritesEveryRowOnItsFirstFrame() {
    var renderer = FrameRenderer()
    let output = String(decoding: renderer.encode(rows: ["first", "second"]), as: UTF8.self)
    XCTAssertEqual(output, "\u{001B}[2J\u{001B}[1;1Hfirst\u{001B}[K\u{001B}[2;1Hsecond\u{001B}[K")
  }

  func testFrameRendererRetypesOnlyChangedRowsAndErasesTheRest() {
    var renderer = FrameRenderer()
    _ = renderer.encode(rows: ["first", "second"])

    // An identical frame must reach the terminal as nothing at all.
    XCTAssertTrue(renderer.encode(rows: ["first", "second"]).isEmpty)

    // A row that got shorter must be erased, and the untouched row left alone.
    let shortened = String(decoding: renderer.encode(rows: ["first", "sec"]), as: UTF8.self)
    XCTAssertEqual(shortened, "\u{001B}[2;1Hsec\u{001B}[K")

    // A frame with fewer rows must clear the rows it no longer uses.
    let dropped = String(decoding: renderer.encode(rows: ["first"]), as: UTF8.self)
    XCTAssertEqual(dropped, "\u{001B}[2;1H\u{001B}[K")
  }

  func testFrameRendererRepaintsEverythingAfterInvalidation() {
    var renderer = FrameRenderer()
    _ = renderer.encode(rows: ["first", "second"])
    renderer.invalidate()
    XCTAssertEqual(
      String(decoding: renderer.encode(rows: ["first", "second"]), as: UTF8.self),
      "\u{001B}[2J\u{001B}[1;1Hfirst\u{001B}[K\u{001B}[2;1Hsecond\u{001B}[K")
  }

  func testRenderingUsesTheSelectedTheme() {
    var model = AppModel(
      themeStore: ThemeStore(
        directory: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent(UUID().uuidString)))
    model.theme = .mono
    let rendered = TerminalView.render(model).joined(separator: "\n")
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
    var model = AppModel()
    model.mode = .library
    model.trackTyping = true
    model.trackDraft = "Nocturne"

    _ = model.handle(.enter)

    XCTAssertTrue(model.showingTracks)
    XCTAssertTrue(model.trackSearching)
    XCTAssertEqual(
      model.takePendingCommands(),
      [PendingAppCommand(command: .searchLibrary("Nocturne"), message: "Searching your library…")])
  }

  func testEnterOnALibraryTrackQueuesThatTrack() {
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

    _ = model.handle(.down)
    _ = model.handle(.enter)

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

    let rendered = TerminalView.render(model).joined(separator: "\n")
    XCTAssertTrue(rendered.contains("YOUR LIBRARY TRACKS"))
    XCTAssertTrue(rendered.contains("Nocturne — Artist"))
    // Clearing status on a search keeps the previously set "Playing: …" message
    // from leaking into the track-list view.
    XCTAssertTrue(rendered.contains("YOUR LIBRARY TRACKS"))
    XCTAssertFalse(rendered.contains("Found 1 library track(s)."))
  }

  func testEscapeLeavesTheTrackListBeforeTheLibrary() {
    var model = AppModel()
    model.mode = .library
    model.showingTracks = true

    _ = model.handle(.escape)
    XCTAssertFalse(model.showingTracks)
    XCTAssertEqual(model.mode, .library)

    _ = model.handle(.escape)
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

  func testOverlongTrackLabelsAreElidedToTheColumnWidth() {
    var model = AppModel()
    model.mode = .library
    model.showingTracks = true
    model.trackQuery = "Nocturne"
    model.width = 100
    model.applyLibrarySearchResult(
      query: "Nocturne",
      songs: [
        Song(
          name: String(repeating: "A", count: 200) + "END", artist: "", album: "", url: "",
          libraryID: "ID1")
      ], error: nil)

    let rows = TerminalView.render(model).map {
      $0.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
    }
    guard let row = rows.first(where: { $0.hasPrefix("› ") }) else {
      return XCTFail("expected a selected track row")
    }
    // contentWidth is 96 here, so the label is elided to 92 columns after the cursor.
    XCTAssertEqual(row.count, 94)
    XCTAssertTrue(row.hasSuffix("…"), "elided rows must end with an ellipsis")
    XCTAssertFalse(row.contains("END"), "elided rows must not run past the column")
  }

  func testDurationHintsStayBoundedAcrossManyCatalogSearches() {
    var model = AppModel()
    for page in 0..<30 {
      model.catalogQuery = "query \(page)"
      model.applyCatalogSearchResult(
        query: "query \(page)",
        songs: (0..<25).map {
          Song(name: "Song \(page)-\($0)", artist: "Artist", album: "", url: "", duration: 200)
        }, error: nil)
    }
    XCTAssertLessThanOrEqual(model.durationHints.count, 512)
  }

  func testQuitKeysWorkInEveryModeButAreTextWhileTyping() {
    for mode in [ViewMode.player, .library, .catalog, .queue] {
      var model = AppModel()
      model.mode = mode
      XCTAssertEqual(model.handle(.character("q")), .quitApplication)
      _ = model.handle(.character("Q"))
      XCTAssertEqual(
        model.takePendingCommands(),
        [PendingAppCommand(command: .quitMusic, message: "Quitting Music…", quitAfterSuccess: true)])
    }

    // While a search draft is focused, q is part of the query, not a quit.
    var typing = AppModel()
    typing.mode = .catalog
    typing.catalogTyping = true
    XCTAssertEqual(typing.handle(.character("q")), .continueRunning)
    XCTAssertEqual(typing.catalogDraft, "q")
    XCTAssertTrue(typing.takePendingCommands().isEmpty)
  }

  func testQueueParsesPlaylistAndMarksTheCurrentTrack() {
    // Fields are separated by ASCII RS (0x1E). The first field names the
    // playlist Music is playing from; each row is five ASCII FS (0x1F) parts:
    // name, artist, album, persistent ID, current flag.
    let rows = [
      ["Nocturne", "Chopin", "Piano Works", "false"],
      ["Etude", "Chopin", "Piano Works", "true"],
    ]
    let output =
      "Late Night" + "\u{1E}" + rows.map { $0.joined(separator: "\u{1F}") }
      .joined(separator: "\u{1E}") + "\u{1E}"

    let queue = AppleMusicController.parseQueueResponse(output)

    XCTAssertEqual(queue.playlist, "Late Night")
    XCTAssertEqual(queue.count, 2)
    XCTAssertEqual(queue.entries[0].album, "Piano Works")
    XCTAssertEqual(queue.entries[1].display, "Etude — Chopin")
    XCTAssertTrue(queue.entries[1].isCurrent)
    XCTAssertFalse(queue.entries[0].isCurrent)
  }

  func testQueueParseTreatsAnEmptyReplyAsNothingPlaying() {
    let queue = AppleMusicController.parseQueueResponse("")
    XCTAssertTrue(queue.isEmpty)
    XCTAssertEqual(queue.playlist, "")
  }

  func testQueueParseDropsRowsThereIsNothingToActOn() {
    // A row that lost its separators, a row with an empty title, a row with no
    // persistent ID, and a row missing the current flag are all dropped: the
    // view must never offer to play a row it cannot address.
    let rows = [
      "Bad Row",
      "\u{1F}\u{1F}\u{1F}false",
      "Nocturne\u{1F}Chopin\u{1F}Piano Works",
      "\u{1F}Chopin\u{1F}Piano Works\u{1F}false",
      "Good\u{1F}Chopin\u{1F}Piano Works\u{1F}true",
    ]
    let output = "Late Night\u{1E}" + rows.joined(separator: "\u{1E}")

    let queue = AppleMusicController.parseQueueResponse(output)

    XCTAssertEqual(queue.entries.map(\.name), ["Good"])
    XCTAssertEqual(queue.playlist, "Late Night")
  }

  func testQueueKeysStepThroughTheQueue() {
    var model = AppModel()
    model.applyQueueResult(queuedTracks(2), error: nil)
    model.mode = .queue

    _ = model.handle(.character("n"))
    _ = model.handle(.character("p"))

    XCTAssertEqual(
      model.takePendingCommands().map(\.command), [.queuePlayNext, .queuePlayPrevious])
  }

  func testQueueKeysNeverJumpToARowOrRemoveOne() {
    // Music cannot start a track inside a playlist without dropping the playlist
    // context, and deleting one also deletes Apple Music tracks from the
    // library, so neither key may queue anything. Enter explains that instead.
    var model = AppModel()
    model.applyQueueResult(queuedTracks(2), error: nil)
    model.mode = .queue

    _ = model.handle(.enter)
    _ = model.handle(.space)
    _ = model.handle(.character("r"))

    XCTAssertTrue(model.takePendingCommands().isEmpty)
    XCTAssertEqual(model.status, "Use n / p to step through the queue, or Music itself to jump.")
  }

  func testQueueCursorMovesWithoutQueueingAnything() {
    var model = AppModel()
    model.applyQueueResult(queuedTracks(2), error: nil)
    model.mode = .queue

    _ = model.handle(.down)
    XCTAssertEqual(model.queue.cursor, 1)
    XCTAssertTrue(model.takePendingCommands().isEmpty)
  }

  func testQueueCursorMovesAndStaysInRange() {
    var model = AppModel()
    model.applyQueueResult(queuedTracks(3), error: nil)
    model.mode = .queue

    for _ in 0..<5 { _ = model.handle(.down) }
    XCTAssertEqual(model.queue.cursor, 2)
    _ = model.handle(.up)
    XCTAssertEqual(model.queue.cursor, 1)
    XCTAssertEqual(model.queue.selected?.name, "Track 1")
  }

  func testQueueRefreshKeepsTheCursorAndFailureKeepsTheRows() {
    var model = AppModel()
    model.applyQueueResult(queuedTracks(3), error: nil)
    model.mode = .queue
    _ = model.handle(.down)

    // A refresh after a track change must not jump to the top.
    model.applyQueueResult(queuedTracks(3), error: nil)
    XCTAssertEqual(model.queue.cursor, 1)

    // A failed read must not blank the rows already on screen.
    model.applyQueueResult(nil, error: "Music is not running.")
    XCTAssertEqual(model.queue.count, 3)
    XCTAssertEqual(model.status, "Could not read the queue: Music is not running.")
  }

  func testQueueEscapeAndTabReturnToThePlayer() {
    for input in [InputKey.escape, .character("l"), .tab] {
      var model = AppModel()
      model.mode = .queue
      _ = model.handle(input)
      XCTAssertEqual(model.mode, .player)
    }
  }

  func testRenderedQueueMarksThePlayingTrackAndSelectsTheCursorRow() {
    var model = AppModel()
    model.mode = .queue
    model.applyQueueResult(
      Queue(
        playlist: "Late Night",
        entries: [
          QueueEntry(name: "Nocturne", artist: "Chopin", isCurrent: true),
          QueueEntry(name: "Etude", artist: "Chopin", album: "Piano Works"),
        ]),
      error: nil)
    // Put the cursor on the row that is not playing, so the playing marker and
    // the selection marker are on different rows.
    _ = model.handle(.down)

    let rendered = TerminalView.render(model).joined(separator: "\n")

    XCTAssertTrue(rendered.contains("QUEUE"))
    XCTAssertTrue(rendered.contains("Late Night — 2 track(s) in playing order."))
    XCTAssertTrue(rendered.contains("▶   Nocturne — Chopin"), "playing row keeps the ▶ marker")
    XCTAssertTrue(rendered.contains("  › Etude — Chopin"), "cursor row is highlighted")
    XCTAssertTrue(rendered.contains("Piano Works"), "the cursor row shows its album")
  }

  func testPlayerUKeyOpensTheQueueAndLoadsIt() {
    var model = AppModel()

    _ = model.handle(.character("u"))

    XCTAssertEqual(model.mode, .queue)
    XCTAssertEqual(model.takePendingCommands().map(\.command), [.loadQueue])
  }

  private func queuedTracks(_ count: Int) -> Queue {
    Queue(
      playlist: "Late Night",
      entries: (0..<count).map { QueueEntry(name: "Track \($0)", artist: "Artist") })
  }
}

private final class FakeMusicController: MusicControlling {
  var playPauseCount = 0
  var playlistsReadCount = 0
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
  func play(_ song: Song) throws {}
  func searchLibrary(_ query: String) throws -> [Song] { [] }
  func queue(command: QueueCommand) throws -> Queue { Queue() }
  func quitMusic() throws {}
}

private final class FakeCatalogSearch: CatalogSearching {
  var searchCount = 0
  func search(_ query: String) throws -> [Song] {
    searchCount += 1
    return []
  }
}
