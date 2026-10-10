import Darwin
import Foundation

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
