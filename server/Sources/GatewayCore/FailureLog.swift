import Foundation

/// Logs to stderr, which is unbuffered, so `docker logs` shows lines as they happen.
package func log(_ message: String) {
  FileHandle.standardError.write(Data("[gateway] \(message)\n".utf8))
}

/// Appends every failed analysis (with its input, which users agree to share
/// in the About dialog) to a JSON-lines file, and a summary to stderr.
package actor FailureLog {
  struct Entry: Encodable {
    let id: String
    let time: String
    /// `internalError`, `invariantViolation`, `timeLimit` or `memoryLimit`.
    let kind: String
    let message: String?
    let source: String
  }

  private let handle: FileHandle?

  package init(path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) {
      _ = FileManager.default.createFile(atPath: path, contents: nil)
    }
    handle = FileHandle(forWritingAtPath: path)
    _ = try? handle?.seekToEnd()
    if handle == nil {
      log("Can't open failure log at \(path); logging to stderr only")
    }
  }

  /// Returns the entry's id, which users quote in bug reports.
  @discardableResult
  package func record(kind: String, message: String?, source: String) -> String {
    let id = UUID().uuidString.prefix(8).lowercased()
    let entry = Entry(
      id: String(id),
      time: ISO8601DateFormatter().string(from: Date()),
      kind: kind,
      message: message,
      source: source
    )
    log("failure \(entry.id) \(kind): \(message?.split(separator: "\n").first ?? "")")
    if let handle, var line = try? JSONEncoder().encode(entry) {
      line.append(UInt8(ascii: "\n"))
      try? handle.write(contentsOf: line)
    }
    return entry.id
  }
}
