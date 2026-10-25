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

@Test func typeResolutionDiagnostics() throws {
  let response = Analyzer.analyze(
    source: """
      struct A {}
      let a: A.B.C
      let b: (A & P)
      extension Z {}
      """,
    checkInvariants: true
  )
  #expect(response.status == .ok)
  let diagnostics = try #require(response.diagnostics)
  // `A.B.C` fails only because of `B`, so it isn't reported again.
  #expect(diagnostics.map(\.message) == [
    "'B' is not a member type of 'MyModule.A'",
    "non-protocol, non-class type 'A' cannot be used within a protocol-constrained type",
    "cannot find type 'P' in scope",
    "cannot find type 'Z' in scope",
  ])
  #expect(diagnostics.allSatisfy { $0.severity == .error })
  #expect(diagnostics[0].range.start.line == 2 && diagnostics[0].range.start.column == 10)
}

@Test func customModuleName() throws {
  let response = Analyzer.analyze(source: "struct A {}\nlet a: A", moduleName: "Shapes", checkInvariants: true)
  let graph = try #require(response.graph)
  #expect(graph.root.display == "Shapes")
  #expect(graph.members.first { $0.name == "A" }?.admits.type?.simple == "Shapes.A")
}

@Test func customFileName() throws {
  let response = Analyzer.analyze(source: "struct A { struct B {} }", fileName: "Shapes.swift", checkInvariants: true)
  let graph = try #require(response.graph)
  let a = try #require(graph.members.first { $0.name == "A" }?.admits.type)
  #expect(a.full == "MyModule._(Shapes.swift)::A")
  // The module root's edge stands for the file; the member's for its declaration.
  let root = try #require(graph.pills.first { $0.from == ["root"] })
  #expect(root.label == "Shapes.swift" && root.selects.kind == .file && root.selects.id == "Shapes.swift")
  #expect(graph.pills.first { $0.from == [a.member!] }?.label == "struct A")
}
