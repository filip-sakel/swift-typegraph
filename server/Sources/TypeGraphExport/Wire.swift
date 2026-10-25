// The JSON wire format (SPEC §4). Mirrored by hand in `web/src/api/types.ts`.

public struct Pos: Codable, Hashable, Sendable {
  /// 1-based.
  public var line: Int
  /// 1-based, counted in UTF-16 code units.
  public var column: Int
}

public struct Range: Codable, Hashable, Sendable {
  public var start: Pos
  public var end: Pos
}

public struct Diagnostic: Codable, Sendable {
  public enum Severity: String, Codable, Sendable { case error, warning, note }
  public var range: Range
  public var severity: Severity
  public var message: String
}

public struct Stats: Codable, Sendable {
  public var elapsedMs: Double
  public var peakMemoryKiB: Int

  public init(elapsedMs: Double, peakMemoryKiB: Int) {
    self.elapsedMs = elapsedMs
    self.peakMemoryKiB = peakMemoryKiB
  }
}

/// What the worker writes back for one job. The gateway adds the statuses it
/// detects itself (time and memory limits, crashes).
public struct AnalyzeResponse: Codable, Sendable {
  public enum Status: String, Codable, Sendable { case ok, parseErrors, memoryLimit }
  /// Echoed from the request so the client can drop stale responses.
  public var revision: Int?
  public var status: Status
  public var graph: Graph?
  public var diagnostics: [Diagnostic]?
  public var stats: Stats?
  /// `TypeGraph._firstInvariantViolation`, when it found one.
  public var invariantViolation: String?
  public var limit: Int?

  public init(
    revision: Int? = nil,
    status: Status,
    graph: Graph? = nil,
    diagnostics: [Diagnostic]? = nil,
    stats: Stats? = nil,
    invariantViolation: String? = nil,
    limit: Int? = nil
  ) {
    self.revision = revision
    self.status = status
    self.graph = graph
    self.diagnostics = diagnostics
    self.stats = stats
    self.invariantViolation = invariantViolation
    self.limit = limit
  }
}

public struct TypeName: Codable, Hashable, Sendable {
  /// Canonical `GlobalTypeName`, e.g. `_(main.swift)::A._(main.swift)::B`.
  public var id: String
  /// `MyModule._(main.swift)::A._(main.swift)::B`
  public var full: String
  /// `MyModule.A.B`
  public var simple: String
  /// The `MemberNode.id` that admits this type; `nil` for local types.
  public var member: String?
}

public struct Graph: Codable, Sendable {
  public struct Root: Codable, Sendable {
    public var id = "root"
    public var display: String
  }
  public var root: Root
  public var members: [MemberNode]
  public var declGroups: [DeclGroup]
  public var pills: [Pill]
  public var typeSyntaxes: [TypeSyntaxInfo]
}

public struct MemberNode: Codable, Sendable {
  public enum Status: String, Codable, Sendable { case resolved, ambiguous, missing }
  public struct Decl: Codable, Sendable {
    public var kind: String
    public var range: Range
    public var nameRange: Range
    /// `DeclGroup.id` or `"root"`.
    public var parent: String
  }
  public struct Admits: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case notNominal, redeclared, missing, notAdmitted }
    public var ok: Bool
    public var type: TypeName?
    public var reason: Reason?
  }

  public var id: String
  /// `nil` means the module root.
  public var base: TypeName?
  public var name: String
  public var status: Status
  public var decls: [Decl]
  public var admits: Admits
  public var resolvedTo: TypeResultDTO?
  /// `DeclGroup.id`s
  public var dependents: [String]
}

public struct DeclGroup: Codable, Sendable {
  public struct ResolvedTo: Codable, Sendable {
    public var ok: Bool
    public var type: TypeName?
    public var failure: FailureDTO?
  }
  public var id: String
  public var kind: String
  public var label: String
  public var range: Range
  public var headerRange: Range
  /// Extensions only.
  public var resolvedTo: ResolvedTo?
  /// `MemberNode.id`s, in engine order.
  public var dependencies: [String]
  /// `MemberNode.id`s
  public var introduces: [String]
}

public struct Pill: Codable, Sendable {
  public struct Selects: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case declGroup, member, file }
    public var kind: Kind
    public var id: String
  }
  public var id: String
  public var label: String
  public var selects: Selects
  /// `MemberNode.id`s or `"root"`.
  public var from: [String]
  public var to: String?
  public var struck: Bool
}

public struct TypeSyntaxInfo: Codable, Sendable {
  public var id: String
  public var range: Range
  public var text: String
  public var result: TypeResultDTO
  /// The innermost enclosing `DeclGroup.id`, or `"root"`.
  public var owner: String
}

public indirect enum TypeResultDTO: Codable, Sendable {
  case nominal(types: [TypeName])
  case function(argumentCount: Int)
  case tuple(labels: [String?])
  case any
  case metatype(base: TypeResultDTO)
  case failure(FailureDTO)

  private enum CodingKeys: String, CodingKey { case kind, types, argumentCount, labels, base, failure }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .nominal(let types):
      try c.encode("nominal", forKey: .kind)
      try c.encode(types, forKey: .types)
    case .function(let argumentCount):
      try c.encode("function", forKey: .kind)
      try c.encode(argumentCount, forKey: .argumentCount)
    case .tuple(let labels):
      try c.encode("tuple", forKey: .kind)
      try c.encode(labels, forKey: .labels)
    case .any:
      try c.encode("any", forKey: .kind)
    case .metatype(let base):
      try c.encode("metatype", forKey: .kind)
      try c.encode(base, forKey: .base)
    case .failure(let failure):
      try c.encode("failure", forKey: .kind)
      try c.encode(failure, forKey: .failure)
    }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "nominal": self = .nominal(types: try c.decode([TypeName].self, forKey: .types))
    case "function": self = .function(argumentCount: try c.decode(Int.self, forKey: .argumentCount))
    case "tuple": self = .tuple(labels: try c.decode([String?].self, forKey: .labels))
    case "metatype": self = .metatype(base: try c.decode(TypeResultDTO.self, forKey: .base))
    case "failure": self = .failure(try c.decode(FailureDTO.self, forKey: .failure))
    default: self = .any
    }
  }
}

public struct FailureDTO: Codable, Sendable {
  /// The `TypeResolver.Failure` case name, e.g. `noTypeMember`.
  public var kind: String
  public var message: String
  public var ranges: [Range]
  /// `MemberNode.id`s
  public var members: [String]
  public var children: [FailureDTO]
}
