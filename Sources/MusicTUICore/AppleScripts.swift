import Foundation

/// Every AppleScript the app runs, kept in one place instead of scattered
/// through the controller as inline literals. Parameterised scripts are
/// functions so user values go through AppleScript escaping exactly once.
enum AppleScript {
  static let musicRunning = #"""
    if application "Music" is running then
        return "true"
    else
        return "false"
    end if
    """#

  static let nowPlaying = #"""
    if application "Music" is not running then return "notrunning"
    tell application "Music"
        set fieldSep to (ASCII character 31)
        set stateText to "stopped"
        set volValue to 0
        set shuffleText to "false"
        set trackTitle to ""
        set trackArtist to ""
        set trackAlbum to ""
        set posText to ""
        set posAvailable to "false"
        set durText to ""
        set durAvailable to "false"
        set formattedDuration to ""
        try
            set stateText to (player state as string)
        end try
        try
            set volValue to sound volume
        end try
        try
            set shuffleText to (shuffle enabled as string)
        end try
        try
            set curTrack to current track
            try
                set trackTitle to (name of curTrack)
            end try
            try
                set trackArtist to (artist of curTrack)
            end try
            try
                set trackAlbum to (album of curTrack)
            end try
            try
                set durText to (duration of curTrack as text)
                set durAvailable to "true"
            end try
            try
                set formattedDuration to (time of curTrack as text)
            end try
        end try
        try
            set posText to (player position as text)
            set posAvailable to "true"
        end try
        return stateText & fieldSep & volValue & fieldSep & shuffleText & fieldSep & trackTitle & fieldSep & trackArtist & fieldSep & trackAlbum & fieldSep & posText & fieldSep & posAvailable & fieldSep & durText & fieldSep & durAvailable & fieldSep & formattedDuration
    end tell
    """#

  static let playlists = #"""
    if application "Music" is not running then return ""
    tell application "Music"
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to (ASCII character 30)
        set playlistNames to (name of every user playlist) as text
        set AppleScript's text item delimiters to oldDelimiters
        return playlistNames
    end tell
    """#

  static let quitMusic = #"tell application "Music" to quit"#
  static let playerState = #"tell application "Music" to return (player state as string)"#

  /// Music's current output volume, so a catalog seek can mute it and put the
  /// user's own level back afterwards instead of guessing a default.
  static let soundVolume = #"tell application "Music" to return (sound volume as text)"#

  /// The current track's title, or an empty string when nothing is loaded.
  /// Used to confirm a requested song actually started, instead of trusting a
  /// bare `playing` state that may belong to whatever was already playing.
  static let currentTrackTitle = #"""
    if application "Music" is not running then return ""
    tell application "Music"
        try
            return name of current track
        on error
            return ""
        end try
    end tell
    """#
  static let hideMusic = #"tell application "System Events" to set visible of process "Music" to false"#
  static let closeMusicWindows = #"tell application "Music" to close every window"#

  /// Steps within the playlist Music is playing from. Music takes about a
  /// second to swap the track, so this waits for the current track to actually
  /// change: the queue is read straight afterwards, and without the wait it
  /// would still mark the old row as playing. `direction` is a constant verb
  /// ("next" / "previous"), never user input, so it needs no escaping.
  static func stepTrack(_ direction: String) -> String {
    #"""
    tell application "Music"
        set previousID to ""
        try
            set previousID to (persistent ID of current track)
        end try
        \#(direction) track
        repeat 15 times
            set currentID to ""
            try
                set currentID to (persistent ID of current track)
            end try
            if currentID is not "" and currentID is not previousID then exit repeat
            delay 0.1
        end repeat
    end tell
    """#
  }

  // There is no script for starting a specific queued row. Any `play <track>`
  // leaves Music without a current playlist at all, so the queue could not be
  // read back afterwards; stepping with `next track` / `previous track` is the
  // only way to move that keeps the playlist intact.

  // There is no queue-removal script on purpose. `delete track of current
  // playlist` removes the Apple Music track from the user's library as well as
  // from the playlist, and Up Next is not scriptable at all, so the queue view
  // leaves removal to Music's own up-next controls.

  /// Reads the queue, which Music scripts as the playlist it is playing from:
  /// the same list `next track` and `previous track` walk. The reply starts
  /// with the playlist name, then one row per track — name, artist, album and
  /// whether it is the current track — fields joined by ASCII FS (31) and rows
  /// terminated by ASCII RS (30). Rows are capped so a very long playlist
  /// cannot stall the poll loop on a whole-library read.
  ///
  /// The read retries: Music refuses `current playlist` and briefly reports an
  /// empty one while it swaps tracks, and a single failure would otherwise look
  /// like an empty queue to the caller and blank the view. An empty reply means
  /// nothing is playing, so an unreadable queue while something *is* playing is
  /// reported as an error for the caller to keep its existing rows.
  static let queue =
    #"""
    if application "Music" is not running then return ""
    tell application "Music"
        set fieldSep to (ASCII character 31)
        set rowSep to (ASCII character 30)
        repeat 10 times
            try
                set sourceName to (name of current playlist)
                set entries to (every track of current playlist)
                set total to (count of entries)
                if total is 0 then error "Music has not reported its queue yet."
                set maxRows to 300
                if total > maxRows then set total to maxRows
                set currentID to ""
                try
                    set currentID to (persistent ID of current track)
                end try
                set output to sourceName & rowSep
                repeat with index from 1 to total
                    set entry to item index of entries
                    set flag to "false"
                    if (persistent ID of entry) is currentID then set flag to "true"
                    set output to output & (name of entry) & fieldSep & (artist of entry) & fieldSep & (album of entry) & fieldSep & flag & rowSep
                end repeat
                return output
            end try
            delay 0.1
        end repeat
        try
            set ignored to (name of current track)
        on error
            return ""
        end try
        error "Music did not report its queue."
    end tell
    """#

  static func setVolume(_ volume: Int) -> String {
    #"tell application "Music" to set sound volume to \#(clamp(volume, min: 0, max: 100))"#
  }


  static func playPlaylist(_ name: String) -> String {
    #"tell application "Music" to play user playlist "\#(escape(name))""#
  }

  static func searchLibrary(_ term: String) -> String {
    #"""
    if application "Music" is not running then return ""
    tell application "Music"
        set queryText to "\#(escape(term))"
        set matches to (tracks of library playlist 1 whose name contains queryText or artist contains queryText or album contains queryText)
        set total to (count of matches)
        if total > 25 then set total to 25
        set fieldSep to (ASCII character 31)
        set rowSep to (ASCII character 30)
        set output to ""
        repeat with index from 1 to total
            set entry to item index of matches
            set output to output & (name of entry) & fieldSep & (artist of entry) & fieldSep & (album of entry) & fieldSep & (persistent ID of entry) & rowSep
        end repeat
        return output
    end tell
    """#
  }

  static func playLibraryTrack(_ identifier: String) -> String {
    #"tell application "Music" to play (first track of library playlist 1 whose persistent ID is "\#(escape(identifier))")"#
  }

  /// Header of the collection Music is showing, but only when it matches
  /// `album` — otherwise "". Used to wait until a catalog link has actually
  /// navigated before its controls are driven. Nothing is matched by a
  /// localized label: the content list is found by role and the header by the
  /// album's own title. A page whose first node is not the header (e.g. when it
  /// is still loading) simply does not match yet, which is what waiting wants.
  static func catalogPageHeader(_ album: String, _ song: String) -> String {
    #"""
    try
        tell application "System Events"
            tell process "Music"
                set wantedAlbum to "\#(escape(album))"
                set wantedSong to "\#(escape(song))"
                set sg to missing value
                try
                    set sg to first UI element of window 1 whose role is "AXSplitGroup"
                end try
                if sg is missing value then return ""
                repeat with lvl1 in (UI elements of sg)
                    if (role of lvl1) is "AXScrollArea" then
                        repeat with lvl2 in (UI elements of lvl1)
                            if (role of lvl2) is "AXList" then
                                repeat with lvl3 in (UI elements of lvl2)
                                    set hdrtxt to (description of lvl3)
                                    if wantedAlbum is "" or hdrtxt is wantedAlbum or hdrtxt contains wantedAlbum or wantedAlbum contains hdrtxt then
                                        return hdrtxt
                                    end if
                                    if wantedSong is not "" then
                                        repeat with lvl4 in (UI elements of lvl3)
                                            if (description of lvl4) contains wantedSong then return hdrtxt
                                        end repeat
                                    end if
                                end repeat
                            end if
                        end repeat
                    end if
                end repeat
                return ""
            end tell
        end tell
    on error
        return ""
    end try
    """#
  }

  /// Presses the Play control of the collection whose header matches `album` on
  /// the page Music is showing. On recent macOS the page's own Play control —
  /// not opening the link — is what starts playback, and it works while Music is
  /// hidden, so no `activate` is needed. Matching the header also stops a stale
  /// page's Play from being pressed by mistake.
  ///
  /// Music gives these controls no AXIdentifier, so nothing is matched by a
  /// localized label: the content list is found by role, the header by the
  /// album's own title, and the control by position (the first button in the
  /// album header is Play). A "Play"/"Play" description-or-title is only a
  /// preference, so a non-English Music still works. Needs Accessibility
  /// permission for the calling app. Returns "ok", "no page", "no play control",
  /// "accessibility", or "error <n>".
  static func pressCollectionPlay(_ album: String, _ song: String) -> String {
    #"""
    try
        tell application "System Events"
            tell process "Music"
                set wantedAlbum to "\#(escape(album))"
                set wantedSong to "\#(escape(song))"
                set sg to missing value
                try
                    set sg to first UI element of window 1 whose role is "AXSplitGroup"
                end try
                if sg is missing value then return "no page"
                repeat with lvl1 in (UI elements of sg)
                    if (role of lvl1) is "AXScrollArea" then
                        repeat with lvl2 in (UI elements of lvl1)
                            if (role of lvl2) is "AXList" then
                                set headerL3 to missing value
                                set firstL3 to missing value
                                set songSeen to false
                                repeat with lvl3 in (UI elements of lvl2)
                                    if firstL3 is missing value then set firstL3 to lvl3
                                    set hdrtxt to (description of lvl3)
                                    if headerL3 is missing value and (wantedAlbum is "" or hdrtxt is wantedAlbum or hdrtxt contains wantedAlbum or wantedAlbum contains hdrtxt) then
                                        set headerL3 to lvl3
                                    end if
                                    if wantedSong is not "" then
                                        repeat with lvl4 in (UI elements of lvl3)
                                            if (description of lvl4) contains wantedSong then set songSeen to true
                                        end repeat
                                    end if
                                end repeat
                                -- On pages whose header title is not the album name (some
                                -- singles), fall back to the first header once the requested
                                -- song is listed somewhere on the page.
                                if headerL3 is missing value and songSeen then set headerL3 to firstL3
                                if headerL3 is not missing value then
                                    set firstBtn to missing value
                                    set playBtn to missing value
                                    repeat with lvl4 in (UI elements of headerL3)
                                        repeat with lvl5 in (UI elements of lvl4)
                                            if (role of lvl5) is "AXButton" then
                                                if firstBtn is missing value then set firstBtn to lvl5
                                                try
                                                    if (description of lvl5) is "Play" or (title of lvl5) is "Play" then set playBtn to lvl5
                                                end try
                                            end if
                                        end repeat
                                    end repeat
                                    if playBtn is not missing value then
                                        perform action "AXPress" of playBtn
                                        return "ok"
                                    end if
                                    if firstBtn is not missing value then
                                        perform action "AXPress" of firstBtn
                                        return "ok"
                                    end if
                                end if
                            end if
                        end repeat
                    end if
                end repeat
                return "no play control"
            end tell
        end tell
    on error errMsg number errNum
        if errNum is -1743 or errNum is -25211 or errNum is -1719 then return "accessibility"
        return "error " & errNum
    end try
    """#
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
