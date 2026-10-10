import Foundation

public final class CatalogSearchClient: CatalogSearching {
  public init() {}

  private struct Response: Decodable {
    struct Track: Decodable {
      let trackName: String?
      let artistName: String?
      let collectionName: String?
      let trackViewUrl: String?
      let trackTimeMillis: Int?
    }
    let results: [Track]?
  }

  public func search(_ query: String) throws -> [Song] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }

    var components = URLComponents(string: "https://itunes.apple.com/search")!
    let configuredCountry = ProcessInfo.processInfo.environment["MUSICTUI_COUNTRY"] ?? "TR"
    let country = configuredCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    components.queryItems = [
      URLQueryItem(name: "term", value: term),
      URLQueryItem(name: "media", value: "music"),
      URLQueryItem(name: "entity", value: "song"),
      URLQueryItem(name: "limit", value: "25"),
      URLQueryItem(name: "country", value: country.isEmpty ? "TR" : country),
    ]
    guard let url = components.url else {
      throw MusicTUIError.invalidResponse("Could not construct catalog search URL.")
    }

    return try Self.parseResponse(try fetch(url))
  }

  /// Synchronous wrapper around `URLSession`, which only exposes a callback API.
  /// Callers run this off the main thread, so blocking here is safe.
  private func fetch(_ url: URL) throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10

    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<Data, Error>?
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      defer { semaphore.signal() }
      if let error {
        outcome = .failure(error)
        return
      }
      guard let http = response as? HTTPURLResponse else {
        outcome = .failure(
          MusicTUIError.commandFailed("Catalog search returned no HTTP response."))
        return
      }
      guard (200..<300).contains(http.statusCode) else {
        outcome = .failure(
          MusicTUIError.commandFailed("Catalog search failed (HTTP \(http.statusCode))."))
        return
      }
      outcome = .success(data ?? Data())
    }
    task.resume()

    if semaphore.wait(timeout: .now() + 15) == .timedOut {
      task.cancel()
      throw MusicTUIError.commandFailed("Catalog search timed out.")
    }
    guard let outcome else {
      throw MusicTUIError.commandFailed("Catalog search did not complete.")
    }
    return try outcome.get()
  }

  static func parseResponse(_ data: Data) throws -> [Song] {
    let response = try JSONDecoder().decode(Response.self, from: data)
    return (response.results ?? []).compactMap { item in
      guard let name = item.trackName, !name.isEmpty,
        let url = item.trackViewUrl, !url.isEmpty
      else { return nil }
      return Song(
        name: name,
        artist: item.artistName ?? "",
        album: item.collectionName ?? "",
        url: url,
        duration: max(0, ((item.trackTimeMillis ?? 0) + 500) / 1000)
      )
    }
  }
}
