import Foundation
import Subprocess
import Synchronization
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// What happened to one job.
package enum JobOutcome: Sendable {
  /// The worker's response JSON, relayed unchanged.
  case response(Data)
  case timeLimit
  /// The worker died allocating (`RLIMIT_AS`).
  case memoryLimit
  /// The worker died: an assertion, precondition or `fatalError`.
  case crashed(message: String)
}

package enum WorkerError: Error {
  case didNotStart(String)
}

/// One `typegraph-worker` process, restarted whenever it dies or times out
/// (SPEC §5.2). A task owns the process and takes jobs from a stream; it ends,
/// and the worker exits, when this object goes away.
package final class WorkerProcess: Sendable {
  private struct Job: Sendable {
    let payload: Data
    let reply: CheckedContinuation<JobOutcome, Never>
  }

  private let jobs: AsyncStream<Job>.Continuation
  private static let maxJobsPerProcess = 1000

  /// Returns once the first process is warm; throws if it doesn't get there.
  package init(executable: URL, environment: [String: String], timeLimit: Duration) async throws {
    let configuration = Configuration(
      executable: .path(FilePath(executable.path)),
      environment: .custom(Dictionary(uniqueKeysWithValues: environment.compactMap { name, value in
        Environment.Key(rawValue: name).map { ($0, value) }
      }))
    )
    let (jobs, submit) = AsyncStream.makeStream(of: Job.self)
    let (started, didStart) = AsyncStream.makeStream(of: Result<Void, WorkerError>.self)
    self.jobs = submit
    Task {
      await Self.supervise(configuration: configuration, timeLimit: timeLimit, jobs: jobs, started: didStart)
    }
    try await started.first { _ in true }?.get()
  }

  deinit {
    jobs.finish()
  }

  package func run(_ job: Data) async -> JobOutcome {
    await withCheckedContinuation { reply in
      jobs.yield(Job(payload: job, reply: reply))
    }
  }

  // MARK: Process lifecycle

  /// Why a process's session ended.
  private enum SessionEnd {
    /// No warm-up frame.
    case didNotStart(stderr: String)
    /// Served its share of jobs, or was killed just after answering.
    case retired
    /// Died running `job`.
    case died(job: Job, stderr: String, timedOut: Bool)
    /// The job stream ended.
    case finished
  }

  /// Runs processes one after another until the job stream ends.
  private static func supervise(
    configuration: Configuration,
    timeLimit: Duration,
    jobs: AsyncStream<Job>,
    started: AsyncStream<Result<Void, WorkerError>>.Continuation
  ) async {
    var pending = jobs.makeAsyncIterator()
    var isFirst = true
    while true {
      let end: SessionEnd
      let status: TerminationStatus?
      do {
        let result = try await Subprocess.run(
          configuration, input: .inputWriter, output: .sequence, error: .sequence
        ) { execution in
          await session(execution, jobs: &pending, timeLimit: timeLimit) {
            if isFirst {
              isFirst = false
              started.yield(.success(()))
            }
          }
        }
        end = result.closureResult
        status = result.terminationStatus
      } catch {
        end = .didNotStart(stderr: "\(error)")
        status = nil
      }

      switch end {
      case .finished:
        return
      case .retired:
        continue
      case .didNotStart(let stderr):
        if isFirst {
          started.yield(.failure(.didNotStart(stderr)))
          return
        }
        log("Worker failed to start, retrying: \(stderr)")
        try? await Task.sleep(for: .seconds(1))
      case .died(let job, let stderr, let timedOut):
        job.reply.resume(returning: outcome(stderr: stderr, timedOut: timedOut, status: status))
      }
    }
  }

  /// Serves jobs from one process until it dies or retires.
  private static func session(
    _ execution: Execution<CustomWriteInput, SequenceOutput, SequenceOutput>,
    jobs: inout AsyncStream<Job>.Iterator,
    timeLimit: Duration,
    ready: () -> Void
  ) async -> SessionEnd {
    let stderr = StderrTail()
    async let stderrClosed: Void = stderr.drain(execution.standardError)
    var frames = FrameReader(execution.standardOutput)

    // The worker writes an empty frame once warm.
    guard await frames.next() != nil else {
      try? execution.send(signal: .kill)
      await stderrClosed
      return .didNotStart(stderr: stderr.take())
    }
    ready()

    var end = SessionEnd.retired
    for _ in 0..<maxJobsPerProcess {
      guard let job = await jobs.next() else {
        end = .finished
        break
      }
      stderr.reset()

      let (response, timedOut) = await withDeadline(in: timeLimit) {
        // Killing the worker closes its stdout, which ends the read.
        let response = await withTaskCancellationHandler {
          await write(job.payload, to: execution.standardInputWriter) ? await frames.next() : nil
        } onCancel: {
          try? execution.send(signal: .kill)
        }
        return (response, Task.cancellationReason == .deadlineExpired)
      }

      if let response {
        job.reply.resume(returning: .response(response))
        if timedOut { break }
        continue
      }
      // The worker died; make sure, then let the caller find out why.
      try? execution.send(signal: .kill)
      await stderrClosed
      return .died(job: job, stderr: stderr.take(), timedOut: timedOut)
    }

    // EOF on stdin makes the worker exit.
    try? await execution.standardInputWriter.finish()
    await stderrClosed
    return end
  }

  private static func outcome(stderr: String, timedOut: Bool, status: TerminationStatus?) -> JobOutcome {
    if timedOut {
      return .timeLimit
    }
    if stderr.contains("allocat") || stderr.contains("out of memory") || stderr.contains("bad_alloc") {
      return .memoryLimit
    }
    let reason = switch status {
    case .signaled(let signal): "signal \(signal)"
    case .exited(let code): "exit \(code)"
    case nil: "unknown status"
    }
    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return .crashed(message: message.isEmpty ? "Analyzer died (\(reason))" : "\(message)\n(\(reason))")
  }

  // MARK: Framing

  private static func write(_ payload: Data, to stdin: StandardInputWriter) async -> Bool {
    var frame = withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Data($0) }
    frame.append(payload)
    return (try? await stdin.write(frame)) != nil
  }
}

/// Splits the worker's stdout into `UInt32 little-endian length + payload` frames.
private struct FrameReader {
  private var chunks: SubprocessOutputSequence.Iterator
  private var buffered: [UInt8] = []

  init(_ stdout: SubprocessOutputSequence) {
    chunks = stdout.makeAsyncIterator()
  }

  /// The next frame's payload, or `nil` once stdout closes.
  mutating func next() async -> Data? {
    guard let header = await read(4) else { return nil }
    let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    return await read(length).map { Data($0) }
  }

  private mutating func read(_ count: Int) async -> [UInt8]? {
    while buffered.count < count {
      guard let chunk = try? await chunks.next() else { return nil }
      chunk.withUnsafeBytes { buffered.append(contentsOf: $0) }
    }
    defer { buffered.removeFirst(count) }
    return Array(buffered.prefix(count))
  }
}

/// The end of the worker's stderr, where the `fatalError` message is.
private final class StderrTail: Sendable {
  private let bytes = Mutex(Data())

  func drain(_ stderr: SubprocessOutputSequence) async {
    do {
      for try await chunk in stderr {
        chunk.withUnsafeBytes { chunk in
          bytes.withLock { bytes in
            bytes.append(contentsOf: chunk)
            if bytes.count > 16_384 { bytes = bytes.suffix(8_192) }
          }
        }
      }
    } catch {
      // Cancelled because the worker exited; what was read is kept.
    }
  }

  /// Forgets what earlier jobs wrote.
  func reset() {
    bytes.withLock { $0 = Data() }
  }

  func take() -> String {
    bytes.withLock { String(decoding: $0, as: UTF8.self) }
  }
}
