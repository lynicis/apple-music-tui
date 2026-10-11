import Foundation

public enum TerminalView {
  /// The frame as one string per screen row, ANSI-coloured and truncated to
  /// `model.width`. Rows carry no newlines; `FrameRenderer` places them.
  public static func render(_ model: AppModel) -> [String] {
    let width = max(48, model.width)
    let height = max(16, model.height)
    let contentWidth = clamp(width - 4, min: 38, max: 100)
    let theme = model.theme
    var lines: [String] = []
    let modeTitle: String
    switch model.mode {
    case .player: modeTitle = "PLAYER"
    case .library: modeTitle = "LIBRARY"
    case .catalog: modeTitle = "DISCOVER"
    case .queue: modeTitle = "QUEUE"
    }
    // U+F8FF is Apple's logo glyph; it only renders on Apple system fonts.
    lines.append("\(color("\u{F8FF}  APPLE MUSIC", theme.primary))    \(color("[ \(modeTitle) ]", theme.accent))")
    lines.append(color(String(repeating: "━", count: min(32, contentWidth)), theme.highlight))
    lines.append("")

    if model.helpVisible {
      lines.append(contentsOf: helpView(theme))
    } else {
      switch model.mode {
      case .player: lines.append(contentsOf: playerView(model, width: contentWidth))
      case .library:
        lines.append(contentsOf: libraryView(model, width: contentWidth, height: height))
      case .catalog:
        lines.append(contentsOf: catalogView(model, width: contentWidth, height: height))
      case .queue:
        lines.append(contentsOf: queueView(model, width: contentWidth, height: height))
      }
    }

    // Keep the display stable and prevent a very short terminal from flooding
    // a large amount of output; a normal terminal still displays the full view.
    let bodyLimit = max(8, height - 3)
    if lines.count > bodyLimit {
      lines = Array(lines.prefix(bodyLimit - 1)) + [color("… resize terminal for more details", theme.dim)]
    }
    return lines
  }

  private static func playerView(_ model: AppModel, width: Int) -> [String] {
    let theme = model.theme
    var lines: [String] = []
    if let error = model.musicError {
      lines.append(color("CONNECTION ERROR", theme.error))
      lines.append(truncate(error, width))
      lines.append(color("Check macOS Automation permissions for apple-music-tui.", theme.dim))
    } else if model.nowPlaying.state == "notrunning" {
      lines.append(color("Starting Music in the background…", theme.dim))
    } else if model.nowPlaying.name.isEmpty {
      lines.append(color("NOTHING PLAYING", theme.accent))
      lines.append(color("Press Tab to browse playlists or / to discover music.", theme.dim))
    } else {
      let state = model.nowPlaying.state
      let label =
        state == "playing" ? "NOW PLAYING" : state == "paused" ? "PAUSED" : state.uppercased()
      let indicator = state == "playing" ? "▶" : state == "paused" ? "Ⅱ" : "●"
      lines.append(color(label, theme.accent))
      lines.append(color(truncate("\(indicator)  \(model.nowPlaying.name)", width), theme.primary))
      if !model.nowPlaying.artist.isEmpty { lines.append(truncate(model.nowPlaying.artist, width)) }
      if !model.nowPlaying.album.isEmpty {
        lines.append(color(truncate(model.nowPlaying.album, width), theme.dim))
      }
      lines.append("")

      let durationAvailable = model.nowPlaying.durationAvailable && model.nowPlaying.duration > 0
      var positionAvailable = model.nowPlaying.positionAvailable
      if !durationAvailable && state == "playing" && model.nowPlaying.position == 0 {
        positionAvailable = false
      }
      let elapsed = availableTime(model.nowPlaying.position, available: positionAvailable)
      let duration = availableTime(model.nowPlaying.duration, available: durationAvailable)
      let barWidth = clamp(width - 28, min: 12, max: 38)
      let filled =
        durationAvailable
        ? clamp(
          model.nowPlaying.position * barWidth / max(1, model.nowPlaying.duration), min: 0,
          max: barWidth) : 0
      let bar =
        color(String(repeating: "━", count: filled), theme.highlight)
        + color(String(repeating: "─", count: barWidth - filled), theme.dim)
      lines.append("\(color(elapsed, theme.primary))  \(bar)  \(color(duration, theme.dim))")
      if !positionAvailable || !durationAvailable {
        lines.append(color("Playback timing is unavailable.", theme.dim))
        if !model.nowPlaying.timingDiagnostic.isEmpty {
          lines.append(
            color(truncate("Timing fallback: \(model.nowPlaying.timingDiagnostic)", width), theme.dim))
        } else {
          lines.append(color("MediaRemote is not reporting live timing.", theme.dim))
        }
      } else if model.nowPlaying.timingSource == "MediaRemote library" {
        lines.append(color("Live timing · MediaRemote", theme.dim))
      }
    }

    let shuffle = model.nowPlaying.shuffle ? "On" : "Off"
    lines.append("")
    lines.append(
      "\(color(" VOL \(model.nowPlaying.volume)% ", theme.accent))   \(color(" SHUFFLE \(shuffle) ", theme.accent))"
    )
    if !model.status.isEmpty { lines.append(statusLine(model.status, width: width, theme: theme)) }
    lines.append("")
    lines.append(
      hints(
        theme, ("u", "queue"), ("?", "help"), ("t", "theme: \(theme.name)"), ("q", "quit TUI"),
        ("Q", "quit Music")))
    return lines
  }

  private static func libraryView(_ model: AppModel, width: Int, height: Int) -> [String] {
    guard !model.showingTracks else { return trackListView(model, width: width, height: height) }
    let theme = model.theme
    var lines = [color("YOUR PLAYLISTS", theme.accent)]
    if model.playlistTyping {
      lines.append(color("/ \(model.playlistDraft)▏", theme.highlight))
    } else if !model.playlistFilter.isEmpty {
      lines.append("\(color("FILTER  ", theme.dim))\(color(model.playlistFilter, theme.primary))")
    } else {
      lines.append(color("Press / to filter playlists by name.", theme.dim))
    }
    lines.append("")
    let items = model.filteredPlaylists
    if model.playlistsLoading {
      lines.append(color("Loading your library…", theme.dim))
    } else if !model.playlistsLoaded && !model.status.isEmpty {
      lines.append(color("Playlist data is unavailable.", theme.dim))
    } else if items.isEmpty {
      lines.append(
        color(
          model.playlistFilter.isEmpty
            ? "No user playlists found." : "No playlists match this search.", theme.dim))
    } else {
      let window = pageWindow(count: items.count, cursor: model.playlistCursor, height: height)
      for index in window.start..<window.end {
        let prefix = index == model.playlistCursor ? "› " : "  "
        let item = truncate(items[index], width - 4)
        lines.append(
          index == model.playlistCursor ? color(prefix + item, theme.highlight) : prefix + item)
      }
      if items.count > window.rows {
        lines.append(color("Showing \(window.start + 1)–\(window.end) of \(items.count)", theme.dim))
      }
    }
    if !model.status.isEmpty && !model.playlistsLoading {
      lines.append(statusLine(model.status, width: width, theme: theme))
    }
    lines.append("")
    if model.playlistTyping {
      lines.append(hints(theme, ("TYPE", "filter"), ("ENTER", "apply"), ("ESC", "cancel")))
    } else {
      lines.append(
        hints(theme, ("j / k", "navigate"), ("ENTER", "play"), ("/", "search"), ("t", "tracks"), ("ESC", "back"))
      )
      lines.append(hints(theme, ("?", "help"), ("TAB / l", "player"), ("q", "quit")))
    }
    return lines
  }

  private static func trackListView(_ model: AppModel, width: Int, height: Int) -> [String] {
    let theme = model.theme
    var lines = [color("YOUR LIBRARY TRACKS", theme.accent)]
    if model.trackTyping {
      lines.append(color("/ \(model.trackDraft)▏", theme.highlight))
    } else if model.trackSearching {
      lines.append(color("Searching your library…", theme.dim))
    } else if !model.trackQuery.isEmpty {
      lines.append("\(color("SEARCH  ", theme.dim))\(color(model.trackQuery, theme.primary))")
    } else {
      lines.append(color("Press / to search your library by track, artist, or album.", theme.dim))
    }
    lines.append("")

    if model.tracks.isEmpty {
      lines.append(
        color(
          model.trackSearching ? "Searching your library…" : "No library tracks match this search.",
          theme.dim))
    } else {
      lines.append(
        contentsOf: songRows(
          model.tracks, cursor: model.trackCursor, width: width, height: height, noun: "tracks",
          theme: theme))
    }
    if !model.status.isEmpty && !model.trackSearching {
      lines.append(statusLine(model.status, width: width, theme: theme))
    }
    lines.append("")
    if model.trackTyping {
      lines.append(hints(theme, ("TYPE", "query"), ("ENTER", "search"), ("ESC", "cancel")))
    } else {
      lines.append(
        hints(theme, ("j / k", "navigate"), ("ENTER", "play"), ("/", "search"), ("ESC", "playlists"))
      )
      lines.append(hints(theme, ("?", "help"), ("TAB / l", "player"), ("q", "quit")))
    }
    return lines
  }

  private static func queueView(_ model: AppModel, width: Int, height: Int) -> [String] {
    let theme = model.theme
    var lines = [color("QUEUE", theme.accent)]
    if model.queue.isEmpty {
      lines.append(color("Nothing is playing, so Music has no queue.", theme.dim))
    } else {
      lines.append(
        color("\(model.queue.playlist) — \(model.queue.count) track(s) in playing order.", theme.dim)
      )
    }
    lines.append("")

    if model.queue.isEmpty {
      lines.append(color("Start a track in Music, then press u again.", theme.dim))
      lines.append(
        color("The queue is the playlist Music is playing from: the list n / p walk.", theme.dim))
    } else {
      lines.append(
        contentsOf: queueRows(
          model.queue.entries, cursor: model.queue.cursor, width: width, height: height,
          theme: theme))
    }
    if !model.status.isEmpty {
      lines.append(statusLine(model.status, width: width, theme: theme))
    }
    lines.append("")
    if model.queue.isEmpty {
      lines.append(hints(theme, ("ESC / l", "player"), ("?", "help"), ("q", "quit")))
    } else {
      lines.append(
        hints(theme, ("j / k", "navigate"), ("n / p", "next / previous"), ("ESC / l", "player")))
      lines.append(hints(theme, ("?", "help"), ("q", "quit"), ("Q", "quit Music")))
    }
    return lines
  }

  private static func catalogView(_ model: AppModel, width: Int, height: Int) -> [String] {
    let theme = model.theme
    var lines = [
      color("DISCOVER MUSIC", theme.accent),
      color("Search Apple's catalog, including songs outside your library.", theme.dim),
    ]
    if model.catalogTyping {
      lines.append(color("⌕  \(model.catalogDraft)▏", theme.highlight))
    } else if !model.catalogQuery.isEmpty {
      lines.append(color("⌕  \(model.catalogQuery)", theme.primary))
    } else {
      lines.append(color("Press / to enter a search.", theme.dim))
    }
    lines.append("")

    if model.catalogSearching {
      lines.append(color("Searching the Apple Music catalog…", theme.dim))
    } else if model.results.isEmpty {
      lines.append(color("Search by song, artist, or album.", theme.dim))
    } else {
      lines.append(
        contentsOf: songRows(
          model.results, cursor: model.resultCursor, width: width, height: height,
          noun: "results", theme: theme))
    }
    if !model.status.isEmpty { lines.append(statusLine(model.status, width: width, theme: theme)) }
    lines.append("")
    if model.catalogTyping {
      lines.append(hints(theme, ("TYPE", "query"), ("ENTER", "search"), ("ESC", "cancel")))
    } else {
      lines.append(
        hints(theme, ("j / k", "navigate"), ("ENTER", "play"), ("/", "edit"), ("ESC", "player"))
      )
      lines.append(hints(theme, ("?", "help"), ("q", "quit TUI"), ("Q", "quit Music")))
    }
    return lines
  }

  /// Renders the paged queue: a window centred on the cursor, the track Music
  /// is playing marked with a triangle, the cursor row highlighted, and a
  /// "Showing a–b of n" footer.
  private static func queueRows(
    _ entries: [QueueEntry], cursor: Int, width: Int, height: Int, theme: Theme
  ) -> [String] {
    let window = pageWindow(count: entries.count, cursor: cursor, height: height)
    var lines: [String] = []
    for index in window.start..<window.end {
      let entry = entries[index]
      let line =
        (entry.isCurrent ? "▶ " : "  ") + (index == cursor ? "› " : "  ")
        + truncate(entry.display, width - 6)
      lines.append(index == cursor ? color(line, theme.highlight) : line)
      if index == cursor && !entry.album.isEmpty {
        lines.append("     \(color(truncate(entry.album, width - 6), theme.dim))")
      }
    }
    if entries.count > window.rows {
      lines.append(
        color(
          "Showing \(window.start + 1)–\(window.end) of \(entries.count) queued tracks", theme.dim))
    }
    return lines
  }

  /// Renders the paged song list shared by the library-track and catalog views:
  /// a window centred on the cursor, the selected row highlighted with an album
  /// sub-line, and a "Showing a–b of n" footer.
  private static func songRows(
    _ songs: [Song], cursor: Int, width: Int, height: Int, noun: String, theme: Theme
  ) -> [String] {
    let window = pageWindow(count: songs.count, cursor: cursor, height: height)
    var lines: [String] = []
    for index in window.start..<window.end {
      let song = songs[index]
      let label = song.artist.isEmpty ? song.name : "\(song.name) — \(song.artist)"
      let line = (index == cursor ? "› " : "  ") + truncate(label, width - 4)
      lines.append(index == cursor ? color(line, theme.highlight) : line)
      if index == cursor && !song.album.isEmpty {
        lines.append("   \(color(truncate(song.album, width - 6), theme.dim))")
      }
    }
    if songs.count > window.rows {
      lines.append(color("Showing \(window.start + 1)–\(window.end) of \(songs.count) \(noun)", theme.dim))
    }
    return lines
  }

  /// The visible slice of `count` items: a window of rows centred on `cursor`
  /// and sized to the terminal. Shared by the playlist list and the song lists
  /// so every paged view scrolls and reports "Showing a–b of n" the same way.
  private static func pageWindow(count: Int, cursor: Int, height: Int) -> (
    start: Int, end: Int, rows: Int
  ) {
    let rows = clamp(height - 15, min: 4, max: 17)
    let start = clamp(cursor - rows / 2, min: 0, max: max(0, count - rows))
    return (start, min(count, start + rows), rows)
  }

  private static func helpView(_ theme: Theme) -> [String] {
    [
      color("KEYBOARD CONTROLS", theme.accent),
      color("Press ? or Esc to close this panel.", theme.dim),
      "",
      color("PLAYER", theme.highlight),
      "Space  Play or pause",
      "n / p, ← / →  Next / previous track",
      "f / b  Seek forward / back 10 seconds",
      "+ / -  Increase / decrease volume",
      "s  Toggle shuffle",
      "t  Cycle colour theme",
      "Tab / l  Open playlists",
      "/  Search the Apple Music catalog",
      "u  Open the queue of the playlist Music is playing",
      "",
      color("LIBRARY & DISCOVER", theme.highlight),
      "t or /  Search your library tracks (in Library)",
      "j / k or arrows  Move selection",
      "Enter  Play selected track or playlist",
      "Esc  Back to playlists, cancel, or clear filter",
      "",
      color("QUEUE", theme.highlight),
      "u  Show the queue Music is playing (press ? again to reopen)",
      "j / k or arrows  Move the cursor",
      "n / p  Next / previous track, staying in the queue",
      "▶  The track Music is playing right now",
      "Esc / l  Back to the player",
      "",
      color("GLOBAL", theme.highlight),
      "? or Esc  Close this help panel",
      "q  Exit apple-music-tui and leave Music playing",
      "Q  Quit Music and exit",
    ]
  }

  private static func hints(_ theme: Theme, _ items: (String, String)...) -> String {
    items.map { "\(color($0.0, theme.accent)) \(color($0.1, theme.dim))" }
      .joined(separator: "   ")
  }

  private static func statusLine(_ value: String, width: Int, theme: Theme) -> String {
    let lower = value.lowercased()
    let isError =
      value.hasPrefix("Error:") || lower.contains("failed") || value.contains("Could not")
    return color(truncate(value, width), isError ? theme.error : theme.highlight)
  }

  /// Truncates plain text to `width` characters, ending with an ellipsis when it
  /// does not fit. Every caller passes uncoloured text and colourises the result,
  /// so there are no escape sequences to discount here.
  private static func truncate(_ value: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    guard value.count > width else { return value }
    return String(value.prefix(width - 1)) + "…"
  }

  private static func color(_ value: String, _ code: String) -> String {
    "\u{001B}[\(code)m\(value)\u{001B}[0m"
  }
}
