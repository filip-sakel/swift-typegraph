// What the client relies on in an exported graph (SPEC §4.3): ids are unique
// within their kind, every reference names something in the graph, and id
// lists have no repeats (the client keys its lists by them).

extension Graph {
  /// The first broken invariant, described; `nil` if there's none.
  public func firstInvariantViolation() -> String? {
    var violations = GraphInvariantChecker(self)
    violations.check()
    return violations.first
  }
}

private struct GraphInvariantChecker {
  let graph: Graph
  let memberIds: Set<String>
  let groupIds: Set<String>
  private(set) var first: String?

  init(_ graph: Graph) {
    self.graph = graph
    memberIds = Set(graph.members.map(\.id))
    groupIds = Set(graph.declGroups.map(\.id))
  }

  mutating func check() {
    unique(graph.members.map(\.id), "member ids")
    unique(graph.declGroups.map(\.id), "declaration group ids")
    unique(graph.pills.map(\.id), "pill ids")
    unique(graph.typeSyntaxes.map(\.id), "type syntax ids")

    for member in graph.members {
      let at = "member \(member.id)"
      if let base = member.base { typeName(base, at) }
      for decl in member.decls { parent(decl.parent, at) }
      if let type = member.admits.type { typeName(type, at) }
      if let result = member.resolvedTo { typeResult(result, at) }
      unique(member.dependents, "\(at) dependents")
      for id in member.dependents { group(id, at) }
    }
    for group in graph.declGroups {
      let at = "declaration group \(group.id)"
      if let type = group.resolvedTo?.type { typeName(type, at) }
      if let failure = group.resolvedTo?.failure { self.failure(failure, at) }
      unique(group.dependencies, "\(at) dependencies")
      unique(group.introduces, "\(at) introduces")
      for id in group.dependencies + group.introduces { member(id, at) }
    }
    for pill in graph.pills {
      let at = "pill \(pill.id)"
      switch pill.selects.kind {
      case .declGroup: group(pill.selects.id, at)
      case .member: member(pill.selects.id, at)
      case .file: break
      }
      unique(pill.from, "\(at) from")
      for id in pill.from where id != graph.root.id { member(id, at) }
      if let to = pill.to { member(to, at) }
    }
    for type in graph.typeSyntaxes {
      let at = "type syntax \(type.id)"
      typeResult(type.result, at)
      parent(type.owner, at)
    }
  }

  private mutating func fail(_ message: String) {
    if first == nil { first = message }
  }

  private mutating func unique(_ ids: [String], _ what: String) {
    var seen: Set<String> = []
    for id in ids where !seen.insert(id).inserted {
      fail("\(what): duplicate \(id)")
    }
  }

  private mutating func member(_ id: String, _ at: String) {
    if !memberIds.contains(id) { fail("\(at): no member \(id)") }
  }

  private mutating func group(_ id: String, _ at: String) {
    if !groupIds.contains(id) { fail("\(at): no declaration group \(id)") }
  }

  /// A `DeclGroup.id` or the root.
  private mutating func parent(_ id: String, _ at: String) {
    if id != graph.root.id { group(id, at) }
  }

  private mutating func typeName(_ name: TypeName, _ at: String) {
    if let id = name.member { member(id, at) }
  }

  private mutating func typeResult(_ result: TypeResultDTO, _ at: String) {
    switch result {
    case .nominal(let types):
      unique(types.map(\.id), "\(at) types")
      for type in types { typeName(type, at) }
    case .metatype(let base): typeResult(base, at)
    case .failure(let failure): self.failure(failure, at)
    case .function, .tuple, .any: break
    }
  }

  private mutating func failure(_ failure: FailureDTO, _ at: String) {
    unique(failure.members, "\(at) failure members")
    for id in failure.members { member(id, at) }
    for child in failure.children { self.failure(child, at) }
  }
}
