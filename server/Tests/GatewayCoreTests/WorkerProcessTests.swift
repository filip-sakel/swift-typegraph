import Foundation
import GatewayCore
import Testing

/// `fake-worker`, built next to the test binary.
let fakeWorker: URL = {
  var directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
  while directory.path != "/" {
    directory.deleteLastPathComponent()
    let candidate = directory.appendingPathComponent("fake-worker")
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
  }
  fatalError("fake-worker not found next to \(CommandLine.arguments[0])")
}()

func makeWorker(timeLimit: Duration = .seconds(2), environment: [String: String] = [:]) async throws -> WorkerProcess {
  try await WorkerProcess(executable: fakeWorker, environment: environment, timeLimit: timeLimit)
}

extension JobOutcome {
  var text: String? {
    if case .response(let data) = self { String(decoding: data, as: UTF8.self) } else { nil }
  }
}

@Test func relaysResponses() async throws {
  let worker = try await makeWorker()
  #expect(await worker.run(Data("echo:hello".utf8)).text == "hello")
  #expect(await worker.run(Data("echo:".utf8)).text == "")
}

@Test func reusesTheProcess() async throws {
  let worker = try await makeWorker()
  let first = await worker.run(Data("pid".utf8)).text
  let second = await worker.run(Data("pid".utf8)).text
  #expect(first != nil)
  #expect(first == second)
}

@Test func killsAtTheTimeLimitAndRestarts() async throws {
  let worker = try await makeWorker(timeLimit: .milliseconds(200))
  let before = await worker.run(Data("pid".utf8)).text

  let start = ContinuousClock.now
  let outcome = await worker.run(Data("hang".utf8))
  let elapsed = ContinuousClock.now - start
  guard case .timeLimit = outcome else {
    Issue.record("expected timeLimit, got \(outcome)")
    return
  }
  #expect(elapsed >= .milliseconds(200))
  #expect(elapsed < .seconds(2))

  let after = await worker.run(Data("pid".utf8)).text
  #expect(after != nil)
  #expect(after != before)
}

@Test func reportsCrashesWithStderr() async throws {
  let worker = try await makeWorker()
  let outcome = await worker.run(Data("crash".utf8))
  guard case .crashed(let message) = outcome else {
    Issue.record("expected crashed, got \(outcome)")
    return
  }
  #expect(message.contains("boom"))
  #expect(message.contains("signal"))
  #expect(await worker.run(Data("echo:alive".utf8)).text == "alive")
}

@Test func reportsAllocationFailureAsMemoryLimit() async throws {
  let worker = try await makeWorker()
  let outcome = await worker.run(Data("oom".utf8))
  guard case .memoryLimit = outcome else {
    Issue.record("expected memoryLimit, got \(outcome)")
    return
  }
  #expect(await worker.run(Data("echo:alive".utf8)).text == "alive")
}

@Test func stderrFromEarlierJobsDoesNotLeakIntoCrashes() async throws {
  let worker = try await makeWorker()
  _ = await worker.run(Data("oom".utf8))
  let outcome = await worker.run(Data("crash".utf8))
  guard case .crashed(let message) = outcome else {
    Issue.record("expected crashed, got \(outcome)")
    return
  }
  #expect(!message.contains("out of memory"))
}

@Test func throwsWhenTheWorkerCannotStart() async {
  await #expect {
    try await makeWorker(environment: ["FAKE_WORKER_START": "fail"])
  } throws: { error in
    guard case WorkerError.didNotStart(let stderr) = error else { return false }
    return stderr.contains("cannot start")
  }
}

/// Workers restarting at the same time must not inherit each other's pipes:
/// a dead worker's stdout would then never reach EOF, and its slot would hang.
@Test(.timeLimit(.minutes(1))) func concurrentRestartsDoNotHang() async throws {
  var workers: [WorkerProcess] = []
  for _ in 0..<8 { workers.append(try await makeWorker()) }
  for _ in 0..<5 {
    await withTaskGroup(of: Void.self) { group in
      for worker in workers {
        group.addTask {
          let outcome = await worker.run(Data("crash".utf8))
          guard case .crashed = outcome else {
            Issue.record("expected crashed, got \(outcome)")
            return
          }
        }
      }
    }
  }
  for worker in workers {
    #expect(await worker.run(Data("echo:alive".utf8)).text == "alive")
  }
}
