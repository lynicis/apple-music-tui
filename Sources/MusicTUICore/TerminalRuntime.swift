import Darwin
import Foundation

public final class TerminalRuntime {
  public init() {}

  public func run(music: MusicControlling, catalog: CatalogSearching) throws {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
      throw MusicTUIError.commandFailed("apple-music-tu needs an interactive terminal.")
    }
    let terminal = TerminalSession()
    try terminal.enter()
    defer { terminal.leave() }

    var model = AppModel()
    do {
      model.nowPlaying = try music.initialize()
      model.musicError = nil
    } catch {
      model.musicError = error.localizedDescription
    }

    let mailbox = RuntimeEventMailbox()
    let workers = TerminalWorkers(mailbox: mailbox)
    var running = true
    var needsRender = true
    var lastRefresh = Date.distantPast

    while running {
      // Nothing that talks to Music or the network runs on this loop. Input and
      // rendering stay responsive even when AppleScript or catalog requests stall.
      if let raw = terminal.readKey() {
        let key = InputKey(raw: raw)
        if case .character("CTRL_C") = key { break }
        if model.handle(key, music: music, catalog: catalog) == .quitApplication {
          running = false
        }
        needsRender = true
      }

      for command in model.takePendingCommands() {
        workers.execute(command, music: music, catalog: catalog)
        needsRender = true
      }

      for event in mailbox.drain() {
        switch event {
        case .nowPlayingSuccess(let snapshot):
          model.applyNowPlayingResult(snapshot, error: nil)
          needsRender = true
        case .nowPlayingFailure(let message):
          model.applyNowPlayingResult(nil, error: message)
          needsRender = true
        case .playlistsSuccess(let playlists):
          model.applyPlaylistResult(playlists, error: nil)
          needsRender = true
        case .playlistsFailure(let message):
          model.applyPlaylistResult(nil, error: message)
          needsRender = true
        case .catalogSuccess(let query, let songs):
          model.applyCatalogSearchResult(query: query, songs: songs, error: nil)
          needsRender = true
        case .catalogFailure(let query, let message):
          model.applyCatalogSearchResult(query: query, songs: nil, error: message)
          needsRender = true
        case .librarySuccess(let query, let songs):
          model.applyLibrarySearchResult(query: query, songs: songs, error: nil)
          needsRender = true
        case .libraryFailure(let query, let message):
          model.applyLibrarySearchResult(query: query, songs: nil, error: message)
          needsRender = true
        case .commandFinished(let message, let error, let quitAfterSuccess):
          model.applyCommandResult(message: message, error: error)
          if error == nil && quitAfterSuccess { running = false }
          needsRender = true
        }
      }

      let now = Date()
      if now.timeIntervalSince(lastRefresh) >= 1 {
        workers.refreshNowPlaying(music: music)
        lastRefresh = now
      }

      if needsRender {
        let dimensions = terminal.dimensions()
        model.width = dimensions.columns
        model.height = dimensions.rows
        let frame = "\u{001B}[H\(TerminalView.render(model))\u{001B}[J"
        try TerminalOutput.writeAll(Data(frame.utf8))
        needsRender = false
      }

      // Service the main dispatch queue so the MediaRemote adapter's main-queue
      // callbacks can run; this also limits idle CPU use while polling input.
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
  }

}

private enum RuntimeEvent {
  case nowPlayingSuccess(NowPlaying)
  case nowPlayingFailure(String)
  case playlistsSuccess([String])
  case playlistsFailure(String)
  case catalogSuccess(query: String, songs: [Song])
  case catalogFailure(query: String, message: String)
  case librarySuccess(query: String, songs: [Song])
  case libraryFailure(query: String, message: String)
  case commandFinished(message: String, error: String?, quitAfterSuccess: Bool)
}

private final class RuntimeEventMailbox {
  private let lock = NSLock()
  private var events: [RuntimeEvent] = []

  func post(_ event: RuntimeEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  func drain() -> [RuntimeEvent] {
    lock.lock()
    defer { lock.unlock() }
    let pending = events
    events.removeAll(keepingCapacity: true)
    return pending
  }
}

private final class TerminalWorkers {
  private let mailbox: RuntimeEventMailbox
  private let musicCommandQueue = DispatchQueue(
    label: "MusicTUI.music-commands", qos: .userInitiated)
  private let catalogQueue = DispatchQueue(label: "MusicTUI.catalog-search", qos: .utility)
  private let refreshLock = NSLock()
  private var refreshInFlight = false

  init(mailbox: RuntimeEventMailbox) {
    self.mailbox = mailbox
  }

  func refreshNowPlaying(music: MusicControlling) {
    refreshLock.lock()
    guard !refreshInFlight else {
      refreshLock.unlock()
      return
    }
    refreshInFlight = true
    refreshLock.unlock()

    DispatchQueue.global(qos: .utility).async { [mailbox] in
      defer {
        self.refreshLock.lock()
        self.refreshInFlight = false
        self.refreshLock.unlock()
      }
      do {
        mailbox.post(.nowPlayingSuccess(try music.nowPlaying()))
      } catch {
        mailbox.post(.nowPlayingFailure(error.localizedDescription))
      }
    }
  }

  func execute(_ pending: PendingAppCommand, music: MusicControlling, catalog: CatalogSearching) {
    switch pending.command {
    case .loadPlaylists:
      musicCommandQueue.async { [mailbox] in
        do {
          mailbox.post(.playlistsSuccess(try music.playlists()))
        } catch {
          mailbox.post(.playlistsFailure(error.localizedDescription))
        }
      }
    case .searchCatalog(let query):
      catalogQueue.async { [mailbox] in
        do {
          mailbox.post(.catalogSuccess(query: query, songs: try catalog.search(query)))
        } catch {
          mailbox.post(.catalogFailure(query: query, message: error.localizedDescription))
        }
      }
    case .searchLibrary(let query):
      musicCommandQueue.async { [mailbox] in
        do {
          mailbox.post(.librarySuccess(query: query, songs: try music.searchLibrary(query)))
        } catch {
          mailbox.post(.libraryFailure(query: query, message: error.localizedDescription))
        }
      }
    default:
      musicCommandQueue.async { [mailbox] in
        do {
          switch pending.command {
          case .playPause: try music.playPause()
          case .next: try music.next()
          case .previous: try music.previous()
          case .setVolume(let volume): try music.setVolume(volume)
          case .seek(let seconds): try music.seek(seconds)
          case .toggleShuffle: try music.toggleShuffle()
          case .playPlaylist(let name): try music.playPlaylist(name)
          case .playSong(let song): try music.play(song)
          case .quitMusic: try music.quitMusic()
          case .loadPlaylists, .searchCatalog, .searchLibrary: break
          }
          mailbox.post(
            .commandFinished(
              message: pending.message,
              error: nil,
              quitAfterSuccess: pending.quitAfterSuccess))
        } catch {
          mailbox.post(
            .commandFinished(
              message: pending.message,
              error: error.localizedDescription,
              quitAfterSuccess: false))
        }
      }
    }
  }
}

private final class TerminalSession {
  private var original = termios()
  private var configured = false
  private var originalFileFlags: Int32 = 0

  func dimensions() -> (columns: Int, rows: Int) {
    var size = winsize()
    let result = Darwin.ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size)
    if result == 0, size.ws_col > 0, size.ws_row > 0 {
      return (Int(size.ws_col), Int(size.ws_row))
    }

    let environment = ProcessInfo.processInfo.environment
    let columns = Int(environment["COLUMNS"] ?? "100") ?? 100
    let rows = Int(environment["LINES"] ?? "30") ?? 30
    return (max(48, columns), max(16, rows))
  }

  func enter() throws {
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw MusicTUIError.commandFailed("Could not read terminal settings.")
    }
    var raw = original
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
    raw.c_iflag &= ~tcflag_t(ICRNL)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
      throw MusicTUIError.commandFailed("Could not enable raw terminal input.")
    }
    originalFileFlags = fcntl(STDIN_FILENO, F_GETFL)
    if originalFileFlags >= 0 { _ = fcntl(STDIN_FILENO, F_SETFL, originalFileFlags | O_NONBLOCK) }
    configured = true
    do {
      try TerminalOutput.writeAll(Data("\u{001B}[?1049h\u{001B}[?25l".utf8))
    } catch {
      _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
      if originalFileFlags >= 0 { _ = fcntl(STDIN_FILENO, F_SETFL, originalFileFlags) }
      configured = false
      throw error
    }
  }

  func leave() {
    if configured {
      _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
      if originalFileFlags >= 0 { _ = fcntl(STDIN_FILENO, F_SETFL, originalFileFlags) }
    }
    try? TerminalOutput.writeAll(Data("\u{001B}[0m\u{001B}[?25h\u{001B}[?1049l".utf8))
    configured = false
  }

  func readKey() -> String? {
    guard let first = readByte() else { return nil }
    if first == 3 { return "CTRL_C" }
    if first == 27 {
      guard let second = readByte(waitMilliseconds: 25) else { return "ESC" }
      if second == 91, let third = readByte(waitMilliseconds: 25) {
        switch third {
        case 65: return "UP"
        case 66: return "DOWN"
        case 67: return "RIGHT"
        case 68: return "LEFT"
        default: return "ESC"
        }
      }
      return "ESC"
    }
    if first == 9 { return "TAB" }
    if first == 10 || first == 13 { return "ENTER" }
    if first == 8 || first == 127 { return "BACKSPACE" }
    if first < 32 { return nil }

    var bytes = [UInt8(first)]
    let expectedLength: Int
    switch first {
    case 0xC2...0xDF: expectedLength = 2
    case 0xE0...0xEF: expectedLength = 3
    case 0xF0...0xF4: expectedLength = 4
    default: expectedLength = 1
    }
    while bytes.count < expectedLength {
      guard let next = readByte(waitMilliseconds: 20) else { break }
      bytes.append(UInt8(next))
    }
    return String(bytes: bytes, encoding: .utf8) ?? String(UnicodeScalar(first) ?? " ")
  }

  private func readByte(waitMilliseconds: Int = 0) -> Int? {
    let deadline = Date().addingTimeInterval(Double(waitMilliseconds) / 1_000)
    repeat {
      var byte: UInt8 = 0
      let count = Darwin.read(STDIN_FILENO, &byte, 1)
      if count == 1 { return Int(byte) }
      if waitMilliseconds == 0 || Date() >= deadline { return nil }
      usleep(1_000)
    } while true
  }
}
