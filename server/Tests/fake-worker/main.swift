// Stands in for `typegraph-worker` in GatewayCoreTests: same framing, but each
// job's payload is a command instead of a source file.
//
//   echo:<text>   reply <text>
//   pid           reply this process's pid
//   sleep:<ms>    sleep, then reply "slept"
//   hang          never reply
//   crash         fatalError("boom")
//   oom           die the way an allocation failure under RLIMIT_AS does
//
// FAKE_WORKER_START=fail makes it exit before the ready frame.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation

func readExactly(_ count: Int) -> Data? {
  var data = Data()
  while data.count < count {
    guard let chunk = try? FileHandle.standardInput.read(upToCount: count - data.count), !chunk.isEmpty else {
      return nil
    }
    data.append(chunk)
  }
  return data
}

func writeFrame(_ payload: String) {
  var length = UInt32(payload.utf8.count).littleEndian
  var frame = Data(bytes: &length, count: 4)
  frame.append(Data(payload.utf8))
  FileHandle.standardOutput.write(frame)
}

if ProcessInfo.processInfo.environment["FAKE_WORKER_START"] == "fail" {
  FileHandle.standardError.write(Data("cannot start\n".utf8))
  exit(1)
}

// Ready.
writeFrame("{}")

while let header = readExactly(4) {
  let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
  guard let payload = readExactly(length) else { break }
  let command = String(decoding: payload, as: UTF8.self)
  switch command {
  case "pid":
    writeFrame("\(getpid())")
  case "hang":
    while true { sleep(60) }
  case "crash":
    fatalError("boom")
  case "oom":
    FileHandle.standardError.write(Data("fatal error: out of memory\n".utf8))
    abort()
  case _ where command.hasPrefix("echo:"):
    writeFrame(String(command.dropFirst("echo:".count)))
  case _ where command.hasPrefix("sleep:"):
    usleep(UInt32(command.dropFirst("sleep:".count))! * 1000)
    writeFrame("slept")
  default:
    FileHandle.standardError.write(Data("unknown command \(command)\n".utf8))
    exit(2)
  }
}
