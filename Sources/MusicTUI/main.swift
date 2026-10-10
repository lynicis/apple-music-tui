import Foundation
import MusicTUICore

do {
  let controller = AppleMusicController()
  let catalog = CatalogSearchClient()
  try TerminalRuntime().run(music: controller, catalog: catalog)
} catch {
  fputs("apple-music-tui: \(error.localizedDescription)\n", stderr)
  exit(EXIT_FAILURE)
}
