import Testing
import TypeGraphExport

@Test func boundExtension() throws {
  let response = Analyzer.analyze(
    source: """
      struct A { struct B {} }
      extension A.B { struct C {} }
      """,
    checkInvariants: true
  )
  #expect(response.status == .ok)
  #expect(response.invariantViolation == nil)
  let graph = try #require(response.graph)
  #expect(graph.members.contains { $0.name == "C" })
}

@Test func parseErrorsSkipLookup() {
  let response = Analyzer.analyze(source: "struct A {", checkInvariants: true)
  #expect(response.status == .parseErrors)
  #expect(response.graph == nil)
  #expect(response.diagnostics?.isEmpty == false)
}
