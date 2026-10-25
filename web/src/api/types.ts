// Mirror of `server/Sources/TypeGraphExport/Wire.swift` (SPEC §4).

export interface Pos {
  /** 1-based. */
  line: number
  /** 1-based, in UTF-16 code units. */
  column: number
}

export interface Range {
  start: Pos
  end: Pos
}

export interface Diagnostic {
  range: Range
  severity: 'error' | 'warning' | 'note'
  message: string
}

export interface TypeName {
  id: string
  full: string
  simple: string
  /** The member that admits this type. */
  member?: string
}

export interface MemberDecl {
  kind: string
  range: Range
  nameRange: Range
  /** `DeclGroup.id` or `"root"`. */
  parent: string
}

export interface MemberNode {
  id: string
  /** Absent for members of the module root. */
  base?: TypeName
  name: string
  status: 'resolved' | 'ambiguous' | 'missing'
  decls: MemberDecl[]
  admits: {
    ok: boolean
    type?: TypeName
    reason?: 'notNominal' | 'redeclared' | 'missing' | 'notAdmitted'
  }
  resolvedTo?: TypeResult
  /** `DeclGroup.id`s */
  dependents: string[]
}

export interface DeclGroup {
  id: string
  kind: string
  label: string
  range: Range
  headerRange: Range
  resolvedTo?: { ok: boolean; type?: TypeName; failure?: Failure }
  /** `MemberNode.id`s */
  dependencies: string[]
  /** `MemberNode.id`s */
  introduces: string[]
}

export interface Pill {
  id: string
  label: string
  selects: { kind: 'declGroup' | 'member' | 'file'; id: string }
  /** `MemberNode.id`s or `"root"`. */
  from: string[]
  to?: string
  struck: boolean
}

export interface TypeSyntaxInfo {
  id: string
  range: Range
  text: string
  result: TypeResult
  /** `DeclGroup.id` or `"root"`. */
  owner: string
}

export type TypeResult =
  | { kind: 'nominal'; types: TypeName[] }
  | { kind: 'function'; argumentCount: number }
  | { kind: 'tuple'; labels: (string | null)[] }
  | { kind: 'any' }
  | { kind: 'metatype'; base: TypeResult }
  | { kind: 'failure'; failure: Failure }

export interface Failure {
  kind: string
  message: string
  ranges: Range[]
  /** `MemberNode.id`s */
  members: string[]
  children: Failure[]
}

export interface Graph {
  root: { id: 'root'; display: string }
  members: MemberNode[]
  declGroups: DeclGroup[]
  pills: Pill[]
  typeSyntaxes: TypeSyntaxInfo[]
}

export type Status =
  | 'ok'
  | 'parseErrors'
  | 'timeLimit'
  | 'memoryLimit'
  | 'internalError'
  | 'tooLarge'
  | 'busy'
  | 'superseded'
  | 'consentRequired'
  | 'badRequest'
  | 'rateLimited'
  | 'offline'

export interface AnalyzeResponse {
  revision?: number
  status: Status
  graph?: Graph
  diagnostics?: Diagnostic[]
  stats?: { elapsedMs: number; peakMemoryKiB: number }
  /** Set alongside `status: "ok"` when a TypeGraph invariant failed. */
  invariantViolation?: string
  /** The limit that was exceeded (ms, KiB or bytes). */
  limit?: number
  message?: string
  /** Failure log id, quoted in bug reports. */
  reportId?: string
}
