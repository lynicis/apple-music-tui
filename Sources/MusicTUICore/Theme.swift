import Foundation

/// Colour scheme for the TUI. Values are ANSI SGR parameters.
public struct Theme: Equatable {
  public let name: String
  public let accent: String
  public let highlight: String
  public let primary: String
  public let dim: String
  public let error: String

  public init(
    name: String, accent: String, highlight: String, primary: String, dim: String, error: String
  ) {
    self.name = name
    self.accent = accent
    self.highlight = highlight
    self.primary = primary
    self.dim = dim
    self.error = error
  }

  public static let classic = Theme(
    name: "classic", accent: "36;1", highlight: "35;1", primary: "1;97", dim: "90", error: "31;1")
  public static let mono = Theme(
    name: "mono", accent: "1;97", highlight: "4;97", primary: "97", dim: "90", error: "4;97")
  public static let ocean = Theme(
    name: "ocean", accent: "38;5;45;1", highlight: "38;5;39;1", primary: "38;5;195",
    dim: "38;5;240", error: "38;5;203;1")
  public static let sunset = Theme(
    name: "sunset", accent: "38;5;208;1", highlight: "38;5;205;1", primary: "38;5;230",
    dim: "38;5;245", error: "38;5;196;1")

  public static let all: [Theme] = [classic, mono, ocean, sunset]

  public static func named(_ name: String) -> Theme {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return all.first { $0.name == wanted } ?? classic
  }
}

/// Remembers the chosen theme in `~/.config/apple-music-tui/theme`.
public struct ThemeStore {
  public static let shared = ThemeStore()
  private let fileURL: URL

  public init(directory: URL? = nil) {
    let base =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".config/apple-music-tui")
    fileURL = base.appendingPathComponent("theme")
  }

  public func load() -> Theme {
    guard let stored = try? String(contentsOf: fileURL, encoding: .utf8) else { return .classic }
    return Theme.named(stored)
  }

  public func save(_ theme: Theme) {
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? theme.name.write(to: fileURL, atomically: true, encoding: .utf8)
  }
}
