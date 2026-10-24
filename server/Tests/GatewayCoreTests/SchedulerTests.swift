import Foundation
import GatewayCore
import Testing

extension Scheduler.Result {
  var text: String? {
    if case .done(let outcome) = self { outcome.text } else { nil }
  }
  var isSuperseded: Bool {
    if case .superseded = self { true } else { false }
  }
  var isBusy: Bool {
    if case .busy = self { true } else { false }
  }
}

/// Submits a job in the background, then gives the scheduler time to take it.
func submitInBackground(_ scheduler: Scheduler, session: String, job: String) async throws -> Task<Scheduler.Result, Never> {
  let task = Task { await scheduler.submit(session: session, job: Data(job.utf8)) }
  try await Task.sleep(for: .milliseconds(50))
  return task
}

@Test func runsJobs() async throws {
  let scheduler = Scheduler(workers: [try await makeWorker()], maxQueued: 4, maxWait: .seconds(1))
  #expect(await scheduler.submit(session: "a", job: Data("echo:one".utf8)).text == "one")
  #expect(await scheduler.submit(session: "a", job: Data("echo:two".utf8)).text == "two")
}

@Test func newerJobFromTheSameSessionSupersedesTheQueuedOne() async throws {
  let scheduler = Scheduler(workers: [try await makeWorker()], maxQueued: 4, maxWait: .seconds(5))
  let running = try await submitInBackground(scheduler, session: "other", job: "sleep:300")
  let older = try await submitInBackground(scheduler, session: "a", job: "echo:older")
  let newer = try await submitInBackground(scheduler, session: "a", job: "echo:newer")

  #expect(await older.value.isSuperseded)
  #expect(await newer.value.text == "newer")
  #expect(await running.value.text == "slept")
}

@Test func otherSessionsAreNotSuperseded() async throws {
  let scheduler = Scheduler(workers: [try await makeWorker()], maxQueued: 4, maxWait: .seconds(5))
  let running = try await submitInBackground(scheduler, session: "other", job: "sleep:200")
  let a = try await submitInBackground(scheduler, session: "a", job: "echo:a")
  let b = try await submitInBackground(scheduler, session: "b", job: "echo:b")

  #expect(await a.value.text == "a")
  #expect(await b.value.text == "b")
  #expect(await running.value.text == "slept")
}

@Test func fullQueueIsBusy() async throws {
  let scheduler = Scheduler(workers: [try await makeWorker()], maxQueued: 1, maxWait: .seconds(5))
  let running = try await submitInBackground(scheduler, session: "other", job: "sleep:300")
  let queued = try await submitInBackground(scheduler, session: "a", job: "echo:a")

  #expect(await scheduler.submit(session: "b", job: Data("echo:b".utf8)).isBusy)
  #expect(await queued.value.text == "a")
  #expect(await running.value.text == "slept")
}

@Test func jobThatWaitedTooLongIsBusy() async throws {
  let scheduler = Scheduler(workers: [try await makeWorker()], maxQueued: 4, maxWait: .milliseconds(100))
  let running = try await submitInBackground(scheduler, session: "other", job: "sleep:400")
  let queued = try await submitInBackground(scheduler, session: "a", job: "echo:a")

  #expect(await queued.value.isBusy)
  #expect(await running.value.text == "slept")
}

@Test func usesEveryWorker() async throws {
  let scheduler = Scheduler(
    workers: [try await makeWorker(), try await makeWorker()], maxQueued: 4, maxWait: .milliseconds(100)
  )
  // With one worker the second job would wait 300 ms and be turned away.
  let first = try await submitInBackground(scheduler, session: "a", job: "sleep:300")
  let second = try await submitInBackground(scheduler, session: "b", job: "sleep:300")

  #expect(await first.value.text == "slept")
  #expect(await second.value.text == "slept")
}
