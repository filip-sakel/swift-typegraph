import SwiftSyntax

/// Converts swift-syntax's UTF-8 offsets to line and UTF-16 column (SPEC §4.3).
struct LineTable {
  private let utf8: [UInt8]
  /// UTF-8 offset of each line's first byte.
  private let lineStarts: [Int]

  init(source: String) {
    utf8 = Array(source.utf8)
    var starts = [0]
    for (offset, byte) in utf8.enumerated() where byte == UInt8(ascii: "\n") {
      starts.append(offset + 1)
    }
    lineStarts = starts
  }

  func pos(_ position: AbsolutePosition) -> Pos {
    let offset = min(max(position.utf8Offset, 0), utf8.count)
    // Last line start <= offset
    var low = 0
    var high = lineStarts.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
    }
    let prefix = String(decoding: utf8[lineStarts[low]..<offset], as: UTF8.self)
    return Pos(line: low + 1, column: prefix.utf16.count + 1)
  }

  func range(_ start: AbsolutePosition, _ end: AbsolutePosition) -> Range {
    Range(start: pos(start), end: pos(end))
  }

  /// The node's range without leading and trailing trivia.
  func range(_ node: some SyntaxProtocol) -> Range {
    range(node.positionAfterSkippingLeadingTrivia, node.endPositionBeforeTrailingTrivia)
  }
}
