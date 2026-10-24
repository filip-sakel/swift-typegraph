// HTTP front for the analyzer (SPEC §5): validates requests, schedules them on
// a pool of `typegraph-worker` processes, turns limits and crashes into
// statuses for the client, and logs every failure.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird

let environment = ProcessInfo.processInfo.environment
func setting(_ name: String, _ defaultValue: Int) -> Int {
  environment[name].flatMap(Int.init) ?? defaultValue
}

let workerCount = setting("WORKERS", ProcessInfo.processInfo.activeProcessorCount)
let maxSourceBytes = setting("MAX_SOURCE_BYTES", 8192)
let maxTimeMs = setting("MAX_TIME_MS", 500)
let maxMemoryKiB = setting("MAX_MEMORY_KIB", 10240)
let port = setting("PORT", 8080)
// Next to our own binary. Not argv[0]: it has no directory when found via PATH.
let workerExecutable = environment["WORKER_PATH"].map { URL(fileURLWithPath: $0) }
  ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("typegraph-worker")

// A dead worker closes its pipes; don't let that kill the gateway.
signal(SIGPIPE, SIG_IGN)

var workerEnvironment = environment
workerEnvironment["MAX_MEMORY_KIB"] = "\(maxMemoryKiB)"
workerEnvironment["MALLOC_ARENA_MAX"] = "1"
workerEnvironment["CHECK_INVARIANTS"] = environment["CHECK_INVARIANTS", default: "1"]

log("Starting \(workerCount) workers from \(workerExecutable.path)")
var workers: [WorkerProcess] = []
for _ in 0..<workerCount {
  workers.append(try await WorkerProcess(
    executable: workerExecutable,
    environment: workerEnvironment,
    timeLimit: .milliseconds(maxTimeMs)
  ))
}
let scheduler = Scheduler(workers: workers, maxQueued: 4 * workerCount, maxWait: .seconds(1))
let failureLog = FailureLog(path: environment["FAILURE_LOG", default: "/var/log/typegraph/failures.jsonl"])

// MARK: Wire types (the rest of SPEC §4 is produced by the worker)

struct AnalyzeRequest: Codable {
  var revision: Int
  var source: String
}

/// The fields of a worker response the gateway looks at.
struct WorkerResponsePeek: Decodable {
  var invariantViolation: String?
}

/// Responses the gateway produces itself.
struct GatewayResponse: Encodable {
  var revision: Int?
  /// `timeLimit`, `memoryLimit`, `internalError`, `tooLarge`, `busy`,
  /// `superseded`, `consentRequired` or `badRequest`.
  var status: String
  var limit: Int?
  var message: String?
  var reportId: String?
}

func json(_ status: HTTPResponse.Status, _ body: some Encodable) -> Response {
  json(status, (try? JSONEncoder().encode(body)) ?? Data("{}".utf8))
}

func json(_ status: HTTPResponse.Status, _ data: Data) -> Response {
  Response(
    status: status,
    headers: [.contentType: "application/json", .cacheControl: "no-store"],
    body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
  )
}

// MARK: Routes

let consentHeader = HTTPField.Name("X-Consent")!
let sessionHeader = HTTPField.Name("X-Session")!

let router = Router()

router.get("/api/healthz") { _, _ in "ok" }

router.post("/api/analyze") { request, _ -> Response in
  // The client sends this once the user agreed that their code isn't private.
  guard request.headers[consentHeader] == "1" else {
    return json(.preconditionRequired, GatewayResponse(status: "consentRequired"))
  }
  let session = request.headers[sessionHeader] ?? UUID().uuidString

  let body = try await request.body.collect(upTo: 64 * 1024)
  guard let analyze = try? JSONDecoder().decode(AnalyzeRequest.self, from: Data(body.readableBytesView)) else {
    return json(.badRequest, GatewayResponse(status: "badRequest"))
  }
  let revision = analyze.revision
  guard analyze.source.utf8.count <= maxSourceBytes else {
    return json(.contentTooLarge, GatewayResponse(revision: revision, status: "tooLarge", limit: maxSourceBytes))
  }

  switch await scheduler.submit(session: session, job: try JSONEncoder().encode(analyze)) {
  case .superseded:
    return json(.conflict, GatewayResponse(revision: revision, status: "superseded"))
  case .busy:
    return json(.serviceUnavailable, GatewayResponse(revision: revision, status: "busy"))
  case .done(.response(let data)):
    guard let violation = (try? JSONDecoder().decode(WorkerResponsePeek.self, from: data))?.invariantViolation else {
      return json(.ok, data)
    }
    // Still a usable graph, but an internal assertion failed: log it and
    // splice the report id into the worker's JSON object.
    let id = await failureLog.record(kind: "invariantViolation", message: violation, source: analyze.source)
    var spliced = data.dropLast()
    spliced.append(Data(",\"reportId\":\"\(id)\"}".utf8))
    return json(.ok, Data(spliced))
  case .done(.timeLimit):
    await failureLog.record(kind: "timeLimit", message: nil, source: analyze.source)
    return json(.ok, GatewayResponse(revision: revision, status: "timeLimit", limit: maxTimeMs))
  case .done(.memoryLimit):
    await failureLog.record(kind: "memoryLimit", message: nil, source: analyze.source)
    return json(.ok, GatewayResponse(revision: revision, status: "memoryLimit", limit: maxMemoryKiB))
  case .done(.crashed(let message)):
    let id = await failureLog.record(kind: "internalError", message: message, source: analyze.source)
    return json(.ok, GatewayResponse(revision: revision, status: "internalError", message: message, reportId: id))
  }
}

let app = Application(
  router: router,
  configuration: .init(address: .hostname(environment["HOST", default: "0.0.0.0"], port: port))
)
try await app.runService()
