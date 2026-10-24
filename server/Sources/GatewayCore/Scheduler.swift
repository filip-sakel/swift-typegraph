import Foundation

/// Hands jobs to idle workers (SPEC §5.3). Each session has at most one queued
/// job: a newer request replaces it ("latest wins").
package actor Scheduler {
  package enum Result: Sendable {
    case done(JobOutcome)
    /// A newer request from the same session replaced this one.
    case superseded
    /// The queue is full, or the job waited too long.
    case busy
  }

  private struct Waiter {
    let session: String
    let job: Data
    let enqueued: ContinuousClock.Instant
    let continuation: CheckedContinuation<Result, Never>
  }

  private var idle: [WorkerProcess]
  private var queue: [Waiter] = []
  private let maxQueued: Int
  private let maxWait: Duration

  package init(workers: [WorkerProcess], maxQueued: Int, maxWait: Duration) {
    self.idle = workers
    self.maxQueued = maxQueued
    self.maxWait = maxWait
  }

  package func submit(session: String, job: Data) async -> Result {
    await withCheckedContinuation { continuation in
      if let index = queue.firstIndex(where: { $0.session == session }) {
        queue.remove(at: index).continuation.resume(returning: .superseded)
      }
      guard queue.count < maxQueued else {
        continuation.resume(returning: .busy)
        return
      }
      queue.append(Waiter(session: session, job: job, enqueued: .now, continuation: continuation))
      dispatch()
    }
  }

  private func dispatch() {
    while !idle.isEmpty, !queue.isEmpty {
      let waiter = queue.removeFirst()
      guard ContinuousClock.now - waiter.enqueued <= maxWait else {
        waiter.continuation.resume(returning: .busy)
        continue
      }
      let worker = idle.removeLast()
      Task {
        let outcome = await worker.run(waiter.job)
        waiter.continuation.resume(returning: .done(outcome))
        self.finished(worker)
      }
    }
  }

  private func finished(_ worker: WorkerProcess) {
    idle.append(worker)
    dispatch()
  }
}
