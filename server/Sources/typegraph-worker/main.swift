// Analyzes one job at a time (SPEC §5.1).
//
// Protocol: the gateway writes `UInt32 little-endian length + JSON {"source": …}`
// (plus optional `"moduleName"` and `"fileName"`) to stdin; the worker answers with
// `UInt32 length + AnalyzeResponse JSON` on stdout. Assertion and `fatalError`
// messages go to stderr and the process dies; the gateway reports and logs
// those.
//
// `typegraph-worker --once < file.swift` prints the response for one file.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif
// FoundationEssentials has the JSON coders without ICU, whose data would
// otherwise take ~37 MiB of a wasm instance's linear memory.
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TypeGraphExport

struct Job: Decodable {
  var revision: Int?
  var source: String
  var moduleName: String?
  var fileName: String?
}

let environment = ProcessInfo.processInfo.environment
let checkInvariants = environment["CHECK_INVARIANTS", default: "1"] != "0"
let maxMemoryKiB = Int(environment["MAX_MEMORY_KIB", default: "10240"]) ?? 10240

func analyze(_ source: String, moduleName: String? = nil, fileName: String? = nil, revision: Int? = nil) -> AnalyzeResponse {
  resetPeakMemory()
  let baseline = peakMemoryKiB()
  let start = ContinuousClock.now
  var response = Analyzer.analyze(
    source: source,
    moduleName: moduleName ?? Analyzer.defaultModuleName,
    fileName: fileName ?? Analyzer.defaultFileName,
    checkInvariants: checkInvariants
  )
  let elapsed = ContinuousClock.now - start
  let used = max(0, peakMemoryKiB() - baseline)
  if used > maxMemoryKiB {
    return AnalyzeResponse(revision: revision, status: .memoryLimit, limit: maxMemoryKiB)
  }
  let (seconds, attoseconds) = elapsed.components
  response.revision = revision
  response.stats = Stats(elapsedMs: Double(seconds) * 1000 + Double(attoseconds) / 1e15, peakMemoryKiB: used)
  if let violation = response.invariantViolation {
    // The gateway logs every stderr line along with the input.
    writeAll(2, Data("TypeGraph invariant violation: \(violation)\n".utf8))
  }
  return response
}

// MARK: Memory accounting (Linux; zero elsewhere)

func resetPeakMemory() {
  // "5" resets the peak resident set size (VmHWM).
  let fd = open("/proc/self/clear_refs", O_WRONLY)
  guard fd >= 0 else { return }
  writeAll(fd, Data("5".utf8))
  close(fd)
}

func peakMemoryKiB() -> Int {
  statusKiB("VmHWM:")
}

/// Caps the heap at what's mapped now plus `budget` (SPEC §5.2). `RLIMIT_DATA`
/// covers `brk` and private writable mappings; an allocation past it aborts
/// the process, which the gateway reports as `memoryLimit`. The cap is set
/// once, not per job: freed memory stays mapped, so a per-job cap would let
/// each job reuse what earlier ones left behind on top of its own budget.
func limitDataGrowth(toKiB budget: Int) {
  #if canImport(Glibc)
  let current = statusKiB("VmData:")
  guard current > 0 else { return }
  let bytes = rlim_t(current + budget) << 10
  var limit = rlimit(rlim_cur: bytes, rlim_max: rlim_t.max)
  setrlimit(Int32(RLIMIT_DATA.rawValue), &limit)
  #endif
}

func statusKiB(_ field: String) -> Int {
  guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
  for line in status.split(separator: "\n") where line.hasPrefix(field) {
    return Int(line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first ?? "") ?? 0
  }
  return 0
}

// MARK: Framing

/// Reads up to `count` bytes from stdin; fewer only at end of input.
func readUpTo(_ count: Int) -> Data {
  var data = Data(count: count)
  var filled = 0
  while filled < count {
    let n = data.withUnsafeMutableBytes { read(0, $0.baseAddress! + filled, count - filled) }
    if n < 0 && errno == EINTR { continue }
    guard n > 0 else { break }
    filled += n
  }
  return data.prefix(filled)
}

func readExactly(_ count: Int) -> Data? {
  let data = readUpTo(count)
  return data.count == count ? data : nil
}

func writeAll(_ fd: Int32, _ data: Data) {
  data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return }
      offset += n
    }
  }
}

func writeFrame(_ payload: Data) {
  var length = UInt32(payload.count).littleEndian
  var frame = Data(bytes: &length, count: 4)
  frame.append(payload)
  writeAll(1, frame)
}

let encoder = JSONEncoder()

if CommandLine.arguments.contains("--once") {
  var input = Data()
  while case let chunk = readUpTo(1 << 16), !chunk.isEmpty { input.append(chunk) }
  let source = String(decoding: input, as: UTF8.self)
  limitDataGrowth(toKiB: maxMemoryKiB)
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  writeAll(1, try encoder.encode(analyze(source)))
  writeAll(1, Data("\n".utf8))
  exit(0)
}

// Warm up so the first job doesn't pay for lazy initialization.
_ = Analyzer.analyze(source: "struct A {}\nextension A {}", checkInvariants: checkInvariants)
limitDataGrowth(toKiB: maxMemoryKiB)

// Ready.
writeFrame(Data("{}".utf8))

while let header = readExactly(4) {
  let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
  guard let payload = readExactly(length) else { break }
  let response: AnalyzeResponse
  if let job = try? JSONDecoder().decode(Job.self, from: payload) {
    response = analyze(job.source, moduleName: job.moduleName, fileName: job.fileName, revision: job.revision)
  } else {
    writeAll(2, Data("Malformed job\n".utf8))
    exit(2)
  }
  writeFrame(try encoder.encode(response))
}
