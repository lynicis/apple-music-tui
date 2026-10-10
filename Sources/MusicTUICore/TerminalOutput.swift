import Darwin
import Foundation

/// Double-buffers frames. It remembers the rows currently on screen and emits
/// only the rows that changed, each positioned with an absolute cursor move and
/// erased to end of line — so a row that got shorter cannot leave a stale tail,
/// and unchanged rows are never retyped.
struct FrameRenderer {
  private var displayed: [String] = []
  private var redrawAll = true

  /// Drops the remembered frame so the next one repaints every row, e.g. when a
  /// resize reflows the screen.
  mutating func invalidate() { redrawAll = true }

  mutating func encode(rows: [String]) -> Data {
    var output = ""
    // A resize can leave reflowed text below the frame; paint on a clean screen.
    if redrawAll { output += "\u{001B}[2J" }
    for index in 0..<max(rows.count, displayed.count) {
      let row = index < rows.count ? rows[index] : ""
      let shown = index < displayed.count ? displayed[index] : nil
      if !redrawAll && row == shown { continue }
      output += "\u{001B}[\(index + 1);1H\(row)\u{001B}[K"
    }
    displayed = rows
    redrawAll = false
    return Data(output.utf8)
  }
}

/// Writes terminal frames using POSIX I/O instead of Foundation's FileHandle.
/// FileHandle.write can raise an Objective-C exception when a nonblocking
/// terminal temporarily returns EAGAIN; POSIX writes let us retry safely.
enum TerminalOutput {
  static func writeAll(_ data: Data, to fileDescriptor: Int32 = STDOUT_FILENO) throws {
    try data.withUnsafeBytes { buffer in
      guard let start = buffer.baseAddress else { return }
      var offset = 0

      while offset < buffer.count {
        let result = Darwin.write(fileDescriptor, start.advanced(by: offset), buffer.count - offset)

        if result > 0 {
          offset += result
          continue
        }
        if result == 0 {
          throw MusicTUIError.commandFailed("Terminal output closed before a frame was written.")
        }

        let writeError = errno
        if writeError == EINTR { continue }
        if writeError == EAGAIN || writeError == EWOULDBLOCK {
          try waitUntilWritable(fileDescriptor)
          continue
        }

        throw MusicTUIError.commandFailed(
          "Could not write to the terminal: \(String(cString: strerror(writeError))) (errno \(writeError))."
        )
      }
    }
  }

  private static func waitUntilWritable(_ fileDescriptor: Int32) throws {
    var descriptor = pollfd()
    descriptor.fd = fileDescriptor
    descriptor.events = Int16(POLLOUT)

    while true {
      descriptor.revents = 0
      let result = poll(&descriptor, 1, 1_000)
      if result > 0 {
        if descriptor.revents & Int16(POLLOUT) != 0 { return }
        if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
          throw MusicTUIError.commandFailed("Terminal output is no longer available.")
        }
        continue
      }
      if result == 0 || errno == EINTR { continue }

      let pollError = errno
      throw MusicTUIError.commandFailed(
        "Could not wait for terminal output: \(String(cString: strerror(pollError))) (errno \(pollError))."
      )
    }
  }
}
