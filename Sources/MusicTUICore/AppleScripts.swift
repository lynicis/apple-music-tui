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

  static let playPause = #"tell application "Music" to playpause"#
  static let next = #"tell application "Music" to next track"#
  static let previous = #"tell application "Music" to previous track"#
  static let toggleShuffle =
    #"tell application "Music" to set shuffle enabled to not shuffle enabled"#
  static let quitMusic = #"tell application "Music" to quit"#
  static let playerState = #"tell application "Music" to return (player state as string)"#
  static let hideMusic = #"tell application "System Events" to set visible of process "Music" to false"#
  static let closeMusicWindows = #"tell application "Music" to close every window"#

  static func setVolume(_ volume: Int) -> String {
    #"tell application "Music" to set sound volume to \#(clamp(volume, min: 0, max: 100))"#
  }

  static func seek(by seconds: Int) -> String {
    #"""
    tell application "Music"
        set targetPosition to (player position) + (\#(seconds))
        if targetPosition < 0 then set targetPosition to 0
        set player position to targetPosition
    end tell
    """#
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

  static func openCatalog(_ url: String) -> String {
    #"tell application "Music" to open location "\#(escape(url))""#
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
