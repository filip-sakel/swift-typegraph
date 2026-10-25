# Swift TypeGraph Explorer: Specification

A web app where users type Swift into an editor and see the type graph that
`SwiftLexicalLookup` builds for it: which declaration groups introduce which
type members, which members admit nominal types, what each extension resolves
to, and which members it depends on. The editor, graph and details panel share
a single selection.

Sources:
- UI: `prototypes/TypeGraph {Bound Extension, Bound Type Member, Failed Extension}.svg`
- Engine: `swift-syntax/Sources/SwiftLexicalLookup/TypeLookup/`, a copy of
  `~/Documents/swift-syntax-wip` on branch `typegraph-app` with the SPI in §3.4
  (`TypeGraph.swift`, `TypeGraph.md`, `SymbolTable*.swift`, `TypeResolver*.swift`)

---

## 1. Requirements

| # | Requirement |
|---|---|
| R1 | Up to **150 simultaneous users**. |
| R2 | Each analysis request takes **≤ 8 KiB** of source (UTF-8 bytes), **≤ 0.5 s** and **≤ 10 MiB** of memory. All three limits are configurable (env vars) because they may go up. |
| R3 | The server parses the source with SwiftParser. If it has syntax errors, the server returns them and stops. Otherwise it builds a `SymbolTable`, resolves every type declaration and every `TypeSyntax`, admits all extensions, then exports the resulting `TypeGraph` plus derived data (§3). |
| R4 | The client re-analyzes on edit, debounced, and renders editor highlights, the graph and the details panel from one response. |
| R5 | Selection is linked everywhere: editor cursor ⇄ graph ⇄ details. Links in the details panel navigate. |
| R6 | Deployable as a single `docker compose up -d`. |

---

## 2. Graph model (UI) vs. `TypeGraph` (engine)

`TypeGraph` exists for dependency management during extension binding, and
it's sparse on purpose: nodes are nominal types, edges are extensions, and type
members aren't stored as nodes because `TypeResolver` finds them on demand.

But extensions depend on **type members**, not on types. An extension fails to
bind because a member it looks up has two declarations (a redeclaration) or
none (no such member). The UI therefore makes type members the nodes:

| | `TypeGraph.md` / `TypeGraph.swift` | UI graph (prototypes) |
|---|---|---|
| Nodes | Nominal types (`GlobalTypeName → NominalType`) | **Type members**, written `Base > Name` (e.g. `MyModule.A > C`), plus one **module root** node (`MyModule`) |
| Edges | Extensions bound to a type | **Pills** labelled with the declaration group that introduces or looks up a member (`extension A.C`) |
| Type aliases | Only inside `TypeTable`s and dependencies | Member nodes |
| Redeclared member | A dependency member with `decls.count > 1` | `ambiguous` node |
| Missing member | A dependency member with `decls == []` | `missing` node, struck through |

### 2.1 Nodes: type members

There's one node per `(base, name)` pair that is either declared or looked up.

- **base**:
  - The **module root** for top-level declarations. Top-level types are members of the module: `TypeResolver` doesn't admit a top-level type that has redeclarations, so a redeclared top-level name behaves exactly like a redeclared member.
  - A `GlobalTypeName` for everything else.
- **status**:
  - `resolved`: exactly one declaration.
  - `ambiguous`: more than one declaration, counted across the base type's main declaration and all its bound extensions.
  - `missing`: looked up by some extension, but has no declarations. Drawn struck through (Failed Extension prototype).
- **admits**: whether this member admits a nominal type into `TypeGraph`. It does if and only if it has exactly one declaration, that declaration is a nominal type (`struct`/`class`/`enum`/`actor`/`protocol`), and `TypeGraph.namesToTypes` holds a `NominalType` whose `mainDecl` is that declaration. Otherwise it doesn't, for one of these reasons:
  - `notNominal`: a `typealias` or `associatedtype`. Aliases resolve to a type but never admit one.
  - `redeclared`: the member is `ambiguous`.
  - `missing`.
  - `notAdmitted`: a unique nominal declaration that still isn't in the graph. With admit-all (§3.4) this shouldn't happen, so the details panel shows it as a warning.
- **Label**: `<base> > <name>`, with `<base>` shown simplified or in full depending on the Settings toggle (§6.1).

### 2.2 Edges: pills

A pill connects a base to one member and is labelled with a declaration group
(or, at the top level, with the declaration itself). There is one pill per
`(declaration group, member)` pair, matching the prototypes, where
`extension A` appears once for `B` and once for `C`. Hovering or selecting any
pill acts on its whole declaration group, so every pill of that group lights
up together.

| Pill | From | To | Label |
|---|---|---|---|
| Top-level declaration | module root | its own member node | the declaration: `struct A`, `typealias T` |
| Member of a main declaration | the member node that admits the base type | the member | the main declaration: `struct A` |
| Member of a bound extension | the extension's **dependencies** (the member nodes it looked up); if it has none, the member node that admits the resolved type | the member | `extension A.C` |
| Missing member | the member node that admits the base type | the `missing` member | the base type's **main declaration**: `struct A` "contains" the missing member |
| Failed extension | its dependencies (often a `missing` node); if it has none, a synthesized `missing` top-level node (e.g. `MyModule > Z` for `extension Z {}`), joined to the module root by a plain line | nothing | struck-through `extension A.E` |

A declaration group that introduces no members still gets one pill, with no
outgoing line, so that it can be selected.

Checked against the prototypes:
- **Bound Extension:**
  - `struct A` links `MyModule` to `MyModule > A`. The prototype's `struct B` label there is a typo.
  - Two `extension A` pills lead to `MyModule.A > B` and `MyModule.A > C`.
  - `extension A.C` takes lines from both of its `TypeGraph` dependencies, `A > B` and `A > C` (`C` because of `typealias C = B`), and leads to `MyModule.A.B > D`.
- **Failed Extension:**
  - It adds `MyModule.A > E` (missing), contained by `struct A`. The prototype labels this pill `struct B`, the same typo.
  - The struck-through `extension A.E` hangs off `MyModule.A > E`.

---

## 3. Data the server must produce

`TypeGraph` stores only what binding needs. For the UI the server derives the following, all in one response.

### 3.1 Per type member
- **Declarations**: kind (`struct`/`class`/`enum`/`actor`/`protocol`/`typealias`/`associatedtype`), full range, name range.
- **Parent**: the declaration group that introduced each declaration. This is `ExtensionDependency.Member.introducingExtensionOrMainDecl` for members some extension depends on. For the rest, it's the group whose `TypeTable` contains the declaration.
- **Admits**: the `GlobalTypeName` admitted, or the reason it admits nothing (§2.1).
- **Resolved to**: for an admitting member, its own `GlobalTypeName`. For a type alias, the `TypeResult` of resolving the alias.
- **Dependents**: the extensions that depend on this member (`NominalType.dependents` of the base type, filtered by `memberType`).

### 3.2 Per declaration group
- Syntax label (`extension A.C`, `struct A`), full range, header range, extended-type range.
- **Resolved to** (extensions only): `ExtensionState.resolvedType`, either a `GlobalTypeName` or a structured `Failure` (§4.3).
- **Dependencies** (extensions only): the ordered `ExtensionState.dependencies`, flattened to member-node ids, each carrying its contributing declarations.
- **Introduces**: the member nodes it adds (from its `TypeTable`).

### 3.3 Per `TypeSyntax`
Every `TypeSyntax` in the file (alias initializers, inheritance clauses,
annotations, generic arguments, …) has a range, its text, its `TypeResult`, and
its owning declaration. These items aren't drawn in the graph. They exist for
the editor and the details panel, and their resolved types link to graph nodes.

### 3.4 Library API needed in `swift-syntax-wip`
`~/Documents/swift-syntax-wip` stays untouched. The changes below are made in
the copy at `swift-syntax/` (branch `typegraph-app`), which the server depends
on by path. Port them upstream when convenient.

**Already SPI and used as-is:**
- `SymbolTable.init(moduleName:moduleToSources:buildConfiguration:)`, `resolve(typeSyntax:)`, `admitExtensions(accessibleFrom:)`, `typeGraph`
- `TypeGraph.extensionsToState`, `ExtensionState.{dependencies, resolvedType}`, `ExtensionDependency.Member`
- `TypeResult`, `Failure`, `NestedFailure`, `ExtensionCycle(Element)`, `GlobalTypeName.components`
- `Attached`, `TypeDeclSyntax` and `NominalTypeDeclSyntax` (`_QualifiedLookup`)
- `TypeGraph._firstInvariantViolation(symbolTable:)`

**Proposed `@_spi(_QualifiedLookupTests)` additions.** All are read-only, with
setters staying `fileprivate`/`private`, so none of them changes behavior:

| Where (current line) | Today | Proposed | Needed for |
|---|---|---|---|
| `TypeGraph.swift:140` `TypeGraph.namesToTypes` | `private(set) var` | `@_spi public private(set) var` | Enumerating admitted nominals (**Admits**, **Resolved to**) |
| `TypeGraph.swift:166` `NominalType.mainDecl` | `fileprivate let` | `@_spi public let` | Matching admitted types to member declarations |
| `TypeGraph.swift:168` `NominalType.mainDeclMembers` | `fileprivate let` | `@_spi public let` | Members a main declaration introduces |
| `TypeGraph.swift:174` `NominalType.boundExtensions` | `fileprivate(set) var` | `@_spi public fileprivate(set) var` | Members each extension introduces |
| `TypeGraph.swift:189` `NominalType.dependents` | `fileprivate(set) var` | `@_spi public fileprivate(set) var` | **Dependents** |
| `TypeGraph.swift:210,217` `TypeTable`, `typeMembersToDecls` | internal struct, `fileprivate(set) var` | `@_spi public struct`, `@_spi public fileprivate(set) var` | The type of the two properties above |
| `TypeGraph.swift:224` `TypeDependent` and its two fields | internal | `@_spi public` | The element type of `dependents` |
| `TypeGraph.swift:289` `ExtensionDependency.baseTypeName` | `fileprivate let` | `@_spi public let` | Which type a dependency looked members up on |
| `TypeGraph.swift:298` `ExtensionDependency.members` | `fileprivate let` | `@_spi public let` | **Dependencies** and their declarations |
| `TypeGraph+TypeRef.swift:40-41` `Component.qualifier`, `.name` | `private let` | `@_spi public let` | Simplified vs. full names (§6.1) |
| `TypeGraph+TypeRef.swift:60` `GlobalTypeName.base` | internal | `@_spi public` | A member's base node |
| `TypeGraph+TypeRef.swift:141-142` `GlobalTypeRef.name`, `.mainDecl` | internal `let` | `@_spi public let` | Mapping a `.nominalTypes` result to a name and member node |
| `PartialTypeResolution.swift:49-50` `TypeReference.module`, `.name` | internal `let` | `@_spi public let` | Naming the missing member in `noTypeMember(member:in:)` |

**One new entry point** (not just a visibility change):

```swift
extension SymbolTable {
  @_spi(_QualifiedLookupTests)
  public func resolve(nominalTypeDecl: Attached<NominalTypeDeclSyntax>) -> TypeResolver.TypeResult
}
```

It wraps the `fileprivate` `TypeResolver.resolveTypeDecl` (via a new
`TypeResolver.resolve(nominalTypeDecl:)`),
passing the declaration context from `_findDeclContext(ofDeclGroup:)`. Nominal
types are admitted lazily, so without this entry point a type that nothing
references never enters the graph and shows `Admits: notAdmitted`.
`admitExtensions(accessibleFrom:)` already covers extensions.

This replaces the earlier `_snapshot()` idea: with the visibility changes
above, the worker builds its own snapshot. The worker also has to sort every
dictionary it iterates by source position to keep its output deterministic.

---

## 4. Wire format (JSON)

`POST /api/analyze`, `Content-Type: application/json`.

### 4.1 Request
```ts
type AnalyzeRequest = {
  revision: number        // client-monotonic; echoed back
  source: string          // ≤ 8 KiB UTF-8, checked on the server
}
```
The module name is fixed (`MyModule`), and so is the file name (`main.swift`).

### 4.2 Response
```ts
type AnalyzeResponse =
  | { revision: number; status: "ok"; graph: Graph; stats: Stats; invariantViolation?: string }
  | { revision: number; status: "parseErrors"; diagnostics: Diagnostic[] }   // lookup not run
  | { revision: number; status: "timeLimit" | "memoryLimit"; limit: number }
  | { revision: number; status: "internalError"; message: string; reportId: string } // fatalError/precondition text from stderr
  | { revision?: number; status: "tooLarge"; limit: number }                // HTTP 413
  | { revision: number; status: "busy" }                                    // HTTP 503: queue full
  | { revision: number; status: "superseded" }                              // HTTP 409 (§5.3)
  | { status: "consentRequired" }                                           // HTTP 428: no `X-Consent: 1`
  | { status: "badRequest" }                                                // HTTP 400

type Diagnostic = { range: Range; severity: "error" | "warning" | "note"; message: string }
type Stats = { elapsedMs: number; peakMemoryKiB: number }
```
Analysis outcomes come back as HTTP 200 with a `status`; the gateway's own
answers use the HTTP codes noted above. Caddy adds `429` (rate-limited) and
`413` for oversized bodies, both without a JSON body; the client maps those,
network errors (`offline`) and aborts (`superseded`) to statuses too.

Every request needs the header `X-Consent: 1`, which the client sends once the
user has agreed in the About dialog that their code isn't private (§6.6).

`invariantViolation` is set when the worker runs with `CHECK_INVARIANTS=1` (the
default). It holds the description of `_firstInvariantViolation(symbolTable:)`.
The gateway logs it with the input and adds a `reportId`, and the client shows
a bug-report prompt (§6.7).

### 4.3 Graph
```ts
type Pos   = { line: number; column: number } // 1-based; column counted in UTF-16 code units
type Range = { start: Pos; end: Pos }

type TypeName = {
  id: string            // canonical GlobalTypeName: "_(main.swift)::A._(main.swift)::B"
  full: string          // "MyModule._(main.swift)::A._(main.swift)::B"
  simple: string        // "MyModule.A.B"
  member: string        // MemberNode.id that admits this nominal type
}

type Graph = {
  root: { id: "root"; display: string }   // "MyModule"
  members: MemberNode[]
  declGroups: DeclGroup[]
  pills: Pill[]
  typeSyntaxes: TypeSyntaxInfo[]
}

type MemberNode = {
  id: string            // "<base TypeName.id | root> > <name>", stable across edits
  base?: TypeName; name: string            // base absent: a member of the module root
  status: "resolved" | "ambiguous" | "missing"
  decls: { kind: DeclKind; range: Range; nameRange: Range; parent: string /* DeclGroup.id | "root" */ }[]
  admits: { ok: true; type: TypeName }
        | { ok: false; reason: "notNominal" | "redeclared" | "missing" | "notAdmitted" }
  resolvedTo: TypeResultDTO | null        // null when missing
  dependents: string[]                    // DeclGroup.id[]
}

type DeclGroup = {
  id: string            // "<kind>:<extended-type text or name>#<ordinal>", stable across edits
  kind: "struct" | "class" | "enum" | "actor" | "protocol" | "extension"
  label: string; range: Range; headerRange: Range
  resolvedTo: { ok: true; type: TypeName } | { ok: false; failure: FailureDTO } | null // null: non-extensions
  dependencies: string[]                  // MemberNode.id[], engine order
  introduces: string[]                    // MemberNode.id[]
}

type Pill = {
  id: string
  label: string                           // "extension A.C", "struct A", "typealias T"
  selects: { kind: "declGroup" | "member"; id: string } // top-level typealias pills select the member
  from: string[]                          // MemberNode.id[] or "root" (§2.2)
  to: string | null                       // null for failed extensions and empty groups
                                          // label "": a plain line, e.g. root → a missing top-level member
  struck: boolean                         // failed extension
}

type TypeSyntaxInfo = { id: string; range: Range; text: string; result: TypeResultDTO; owner: string }

type TypeResultDTO =
  | { kind: "nominal"; types: TypeName[] }          // composition => several
  | { kind: "function"; argumentCount: number }
  | { kind: "tuple"; labels: (string | null)[] }
  | { kind: "any" }
  | { kind: "metatype"; base: TypeResultDTO }
  | { kind: "failure"; failure: FailureDTO }

type FailureDTO = {
  kind: string          // Failure case name: "noTypeMember", "cyclicalExtensionDependency", …
  message: string       // human-readable, from Failure.debugDescription
  ranges: Range[]       // syntax the failure refers to (cycle elements, ambiguous decls, …)
  members: string[]     // MemberNode.id[] it refers to (e.g. the missing member)
  children: FailureDTO[] // NestedFailure tree
}
```
IDs are semantic rather than position-based, so a selection survives re-analysis.

**Positions are line/column only.** The wire never carries offsets, because
absolute offsets shift with every edit above them. swift-syntax reports UTF-8
offsets, and the server converts them with `SourceLocationConverter` to a line
plus a column counted in UTF-16 code units (CodeMirror's unit). The client
resolves a position as `doc.line(line).from + column - 1`.

Shared types are written by hand as Swift `Codable` DTOs and TypeScript types.
Server snapshot tests write golden `fixtures/*.json`, and the web tests
type-check and render those same files, so any drift fails CI.

---

## 5. Server

### 5.1 Process isolation is required
The engine has **39 `fatalError`/`precondition`/`internalAssert` sites**, and
cycle detection is exponential in the worst case (per the `TypeGraph.swift`
complexity notes). Run in-process, a single malicious or unlucky input would
crash or stall the server for all 150 users, and Swift can't preempt a running
synchronous computation. Therefore:

```
Caddy ──HTTP──▶ gateway (Hummingbird) ──stdin/stdout, length-prefixed──▶ worker pool (N processes)
```

- **`typegraph-gateway`**: an HTTP server that validates the request, enqueues it, and relays the worker's JSON **bytes unchanged** (no re-encoding).
- **`typegraph-worker`**: a single-threaded executable that handles one job at a time: parse, build `SymbolTable`, admit, export, encode.

### 5.2 Limit enforcement
| Limit | Mechanism |
|---|---|
| 8 KiB | Caddy `request_body { max_size 64KB }` (allows for JSON escaping). The gateway counts the decoded `source.utf8.count` and returns `413`. |
| 0.5 s | The gateway starts a timer when it writes the job to the worker and sends `SIGKILL` at the deadline, then respawns the worker and returns `timeLimit`. `RLIMIT_CPU` is a backstop. |
| 10 MiB | The worker writes `5` to `/proc/self/clear_refs` (which resets the peak RSS) before each job, then reads `VmHWM` from `/proc/self/status` afterwards. If the delta exceeds the budget, it returns `memoryLimit` and discards the result. The hard cap: after warm-up, the worker sets `RLIMIT_DATA` to its current `VmData` plus the budget, with `MALLOC_ARENA_MAX=1`. The cap is set once, not per job, because freed memory stays mapped and a later job would reuse it on top of its own budget. If an allocation fails, the worker aborts, and the gateway respawns it and reports `memoryLimit`. |
| Crash | A non-zero exit or a signal means respawn and return `internalError` with the stderr tail (the `fatalError` message). |

**Assertions stay on.** The worker is a release build with `-Xswiftc -DDEBUG`,
so the engine's `#if DEBUG` assertions run, and `CHECK_INVARIANTS=1` runs
`_firstInvariantViolation` after every analysis. Measured on aarch64: no
meaningful overhead in release (a 6 KB input takes ~500 ms with or without the
checks; invariants cost ~1 ms), while a debug build is ~5× slower.

**Failure log.** Every `internalError`, `invariantViolation`, `timeLimit` and
`memoryLimit` is appended to `FAILURE_LOG` (JSON lines: `id`, `time`, `kind`,
`message`, `source`) and summarized on stderr. The `id` is returned as
`reportId` and quoted in bug reports. Users agree to this in the About dialog.

Workers also recycle every 1,000 jobs to cap fragmentation.

### 5.3 Concurrency and back-pressure
- Pool size defaults to the number of CPUs (`WORKERS` env).
- Queue: one slot per client session (an `X-Session` header, random per tab). **Latest wins**: a new request replaces that session's queued job, and the replaced request gets HTTP 409. This turns a burst of typing into one job.
- The global queue cap is `4 × WORKERS`. Past that, or past 1 s of waiting in the queue, requests get `503`.
- If the client disconnects (the client aborts stale requests), its queued job is dropped.
- Capacity: 150 users with a 300 ms debounce produce at most about 500 req/s in a pathological burst, and far fewer in practice. Throughput depends on per-job cost, which has to be **measured** (`stats.elapsedMs`). Either way, latest-wins coalescing plus `503` keeps worst-case latency bounded.

### 5.4 Analysis steps (worker)
1. Parse with `Parser.parse(source:)` and run `ParseDiagnosticsGenerator.diagnostics(for:)`. If there are any errors, return `parseErrors` and stop. Lookup doesn't run on a tree with syntax errors.
2. `SymbolTable(moduleName: "MyModule", moduleToSources: ["MyModule": ["main.swift": tree]], buildConfiguration: StaticBuildConfiguration(…))`.
3. Call `resolve(nominalTypeDecl:)` on every nominal type declaration, then `admitExtensions(accessibleFrom:)`.
4. Resolve every `TypeSyntax` (§3.3).
5. Read the graph through the SPI in §3.4, derive §3 and the pills (§2.2), and sort everything by source position for determinism.
6. If `CHECK_INVARIANTS=1`, run `_firstInvariantViolation(symbolTable:)`.
7. Encode JSON, length-prefix it, and write it to stdout.

### 5.5 Endpoints
- `POST /api/analyze` (§4)
- `GET /api/healthz`: ready once at least one worker is warm.

---

## 6. Client

### 6.1 Layout (per the prototypes)
- **Header**: logo, "Swift TypeGraph", **About**, **Settings**, and **Run** with a status badge (green check for ok, spinner while in flight, red for a crash or limit, amber for syntax errors, grey when offline). Run forces an immediate analysis.
- **Settings**: one toggle, **Simplify type names** (on by default, remembered in `localStorage`). When it's on, names show as `MyModule.A` (`TypeName.simple`). When it's off, they show as `MyModule._(main.swift)::A` (`TypeName.full`). It affects node labels and the details panel. Pill labels are source text, so it doesn't affect them.
- **Left**: code editor with line numbers.
- **Right**: graph view with pan and zoom.
- **Bottom**: details panel (`Syntax: <label>` plus a bullet list).

### 6.2 Request lifecycle
- Debounce **300 ms** after the last edit.
- Each request carries `revision = ++counter`. Starting a new request aborts the previous one (`AbortController`), and any response whose `revision` isn't the latest is ignored.
- **Stale ranges**: until the new response arrives, the editor keeps the previous decorations and maps them through edits with CodeMirror's `ChangeSet.mapPos`, so highlights don't jump. The graph and details stay as they were, slightly dimmed.
- **Syntax errors** (`parseErrors`): the diagnostics show as editor squiggles with hover messages (`@codemirror/lint`). The graph and details keep the last successful analysis, dimmed, with a note: "Showing the last valid analysis: 2 syntax errors".
- The editor footer shows a byte counter (`5.2 / 8 KiB`). Over the limit, analysis pauses and the counter turns red.

### 6.3 Graph rendering
- Lay out the graph (§2) top-down with **ELK layered** (`elkjs`, lazy-loaded, on the main thread; graphs from 8 KiB of source lay out in milliseconds). Member nodes and pills are both ELK nodes, so pills sit between the rows of member nodes, as in the prototypes.
- Render it as plain SVG from ELK's node positions **and edge routes**, with wheel zoom, drag pan and a Fit button. (Svelte Flow was planned, but it draws its own edges and would discard ELK's routes; custom SVG is less code and closer to the prototypes.)
- Member nodes are rounded boxes, and pills are smaller boxes. Labels of `missing` nodes and of struck pills are struck through. `ambiguous` nodes get a warning outline.
- Relayout on every response, animating node positions by id so the graph doesn't jump around.

### 6.4 Selection model
One store holds `hovered` and `selected` (each `{ kind: "member" | "declGroup" | "typeSyntax"; id }`) and a back/forward history (`Alt+←/→`).

| Trigger | Effect |
|---|---|
| Cursor moves in the editor | Select the **innermost** entity containing the cursor: a `TypeSyntax`, else a type declaration (its member node), else a declaration group. Two special cases: an extension's extended type selects the extension (Bound Extension prototype), and a cursor at file scope clears the selection. |
| Hover in the graph | Set `hovered`, tint its range(s) in the editor, and preview it in the details panel (dashed border). |
| Click in the graph | Set `selected`, scroll the editor to its range, and highlight it solid (prototype blue). |
| Click a link in the details | Select the target and push it onto the history. |

Highlight targets:
- **Member:** all its declarations (several if it's ambiguous).
- **Declaration group:** its full range (the prototypes highlight the whole `extension A.C { … }`), plus every pill of that group.
- **Type syntax:** its range. In the graph, the members that admit its resolved types are outlined.

### 6.5 Details panel content
Every name in **bold** below is a link.

- **Member** (Bound Type Member prototype):
  `Syntax: struct D` · Parent: **extension A.C** · Admits: **MyModule.A.B.D**, or `–` with the reason (`typealias`, `redeclared`, `missing`, ⚠ `not admitted`) · Resolved to: **…** · Dependents: **extension A.E**, … or `–` · Declarations (only if ambiguous): **…**
- **Declaration group** (Bound and Failed Extension prototypes):
  `Syntax: extension A.C` · Dependencies: **MyModule.A > B**, **MyModule.A > C** (`missing` ones suffixed `(missing)`) · Resolved to: **MyModule.A.B**, or the failure tree (a `message` per node, with `ranges`/`members` as links) · Introduces: **…**
- **Type syntax**:
  `Syntax: A.C` · Resolved to: **…** · In: **owner declaration**

Link targets: a member link selects that member node. A type link selects
`TypeName.member` (the member that admits it). Failure ranges show as line
numbers.

### 6.6 About and consent
On first visit, a modal About dialog explains the app and says plainly that
**the code is not private**: everything typed is sent to the server, and inputs
that make an analysis fail are logged with the error. Nothing is sent until the
user ticks "I understand…" and presses **Agree and continue**; the agreement is
remembered in `localStorage` and sent as `X-Consent: 1`. About stays reachable
from the header.

### 6.7 Failure messages
A banner under the header names the failure:

| Status | Message |
|---|---|
| `timeLimit` | took longer than *limit* ms |
| `memoryLimit` | used more than *limit* MiB |
| `tooLarge` | larger than 8 KiB (also caught client-side, before sending) |
| `busy`, `rateLimited` | too many people right now; retries after 2 s |
| `offline` | can't reach the server |
| `internalError`, `invariantViolation` | a bug in TypeGraph: **Copy bug report** (kind, report id, message, source) and, if `VITE_BUG_REPORT_URL` is set at build time, **File a bug report** (opens it with `title`/`body` filled in) |

---

## 7. Tech stack

### 7.1 Recommendation

| Layer | Choice |
|---|---|
| Reverse proxy, TLS and static files | **Caddy 2.11** with the `caddy-ratelimit` plugin |
| HTTP server | **Swift + Hummingbird 2** (`typegraph-gateway`) |
| Analyzer | **Swift executable** (`typegraph-worker`) linking `swift-syntax-wip` |
| Frontend | **Vite + TypeScript + Svelte 5** |
| Editor | **CodeMirror 6**, used directly (Swift mode from `@codemirror/legacy-modes`, `@codemirror/lint` for diagnostics) |
| Graph | Custom SVG (§6.3), **elkjs** for layout |
| State | A runes module (`store.svelte.ts`) holding selection, history, settings and the last response |

### 7.2 Why
- **Caddy, not nginx.** The analyzer endpoint is public and CPU-bound, so it needs a front that rate-limits per IP, caps body size, compresses, caches static assets and times out the proxy. Caddy does all of that and also obtains and renews Let's Encrypt certificates itself, so the server needs no certbot, cron job or mounted certs: setting `SITE_ADDRESS` to a domain is the whole TLS setup. The cost is rate limiting, which stock Caddy lacks: `web/Dockerfile` compiles in `github.com/mholt/caddy-ratelimit` with `xcaddy`, pinned to a commit because the plugin has no recent release tag. Its limiter is a sliding window rather than nginx's token bucket, which makes no difference at these rates. If the host already terminates TLS (Traefik, Cloudflare), leave `SITE_ADDRESS=:80` and Caddy serves plain HTTP behind it.
- **Hummingbird over Vapor.** The gateway only needs one route, a process pool and a queue. Hummingbird is smaller and NIO-native, with no ORM, templating or other unused machinery.
- **Separate worker executable**: see §5.1. This is the most important architectural decision in the app.
- **Svelte over React.** React's only real advantage here was React Flow's maturity, and the graph ended up as custom SVG anyway (§6.3). CodeMirror and elkjs don't depend on any framework. The app's core is one hover/selection state that three panes react to on every mouse move. Svelte's fine-grained reactivity handles that directly, while React needs memoized selectors (zustand) to avoid re-rendering the editor, the graph and the details panel on every hover.
- **Not ElementaryUI.** Most of the client is two JavaScript libraries, CodeMirror and Svelte Flow/ELK. In ElementaryUI, both would sit behind JavaScriptKit/BridgeJS bindings that you'd have to write and maintain. ElementaryUI is also pre-1.0: it had 0.x releases throughout 2026, recent releases needed Swift 6.3, and upgrades broke the Vite cache and runtime. Its real advantage would be sharing the `Codable` DTOs with the server, and the golden-fixture tests (§4.3) recover most of that.

### 7.3 Repository layout
```
swift-typegraph/
├── SPEC.md
├── README.md                     # running it (docker, podman, dev)
├── DEPLOY.md                     # server, domain, .env
├── scripts/up.sh                 # compose up --build, prints the URL
├── compose.yaml
├── .dockerignore
├── swift-syntax/                 # copy of swift-syntax-wip, branch typegraph-app (§3.4)
├── server/
│   ├── Package.swift             # deps: hummingbird, swift-http-types, ../swift-syntax
│   ├── Sources/TypeGraphExport/  # DTOs, analysis (§3, §5.4); library
│   ├── Sources/typegraph-worker/
│   ├── Sources/typegraph-gateway/
│   ├── Tests/
│   └── Dockerfile                # build context: repository root
└── web/
    ├── src/{api,editor,graph,details,ui}/, store.svelte.ts
    ├── Caddyfile
    └── Dockerfile                # node build + xcaddy → Caddy image with dist/
```

### 7.4 Docker Compose
`scripts/up.sh` (`docker compose` or `podman compose` `up -d --build`) serves
the app on `${HTTP_PORT:-8080}` and prints the URL. [README.md](README.md) covers
running it, including Podman; [DEPLOY.md](DEPLOY.md) covers a server with a domain. See `compose.yaml`. In short:

- **gateway**: `server/Dockerfile` builds on `swiftlang/swift:nightly-main-noble`
  (the engine needs a main-branch compiler, like the local toolchain) with
  `-c release -Xswiftc -DDEBUG --static-swift-stdlib`, and runs on `ubuntu:noble`
  as a non-root user. It has no network: it listens on a Unix socket on the
  `gateway_socket` volume, which only Caddy mounts. It has a read-only root
  filesystem, no capabilities, and the failure log on the `failures` volume.
  Env: `WORKERS` (default 4), `CHECK_INVARIANTS=1` and the
  three limits.
- **web**: `web/Dockerfile` builds the client (build arg `BUG_REPORT_URL` →
  `VITE_BUG_REPORT_URL`) and a Caddy binary with the rate-limit plugin into
  `caddy:2.11.7-alpine`. `web/Caddyfile` limits `/api/analyze` to 25 requests
  per 5 s per IP (429), caps bodies at 64 KB (413), compresses, caches
  `/assets/` as immutable, and proxies `/api/` to the gateway's socket. Its
  network mode is `WEB_NETWORK_MODE` (default `bridge`; `pasta` under rootless
  podman, so Caddy sees client addresses). `SITE_ADDRESS`
  (default `:80`, plain HTTP) set to a domain turns on automatic HTTPS; the
  certificates live on the `caddy_data` volume.
- **Architecture**: build images on the target server (`docker compose build`)
  or on native CI rather than through QEMU, which is very slow for Swift.

---

## 8. Milestones
1. **Library SPI** (in the `swift-syntax/` copy): the visibility changes and `resolve(nominalTypeDecl:)` from §3.4.
2. **Worker**: analysis to JSON, with golden fixtures for the three prototypes plus the cycle example from `TypeGraph.md`.
3. **Gateway**: pool, limits and the latest-wins queue, plus a load test (k6) at 150 virtual users.
4. **Web**: editor and request loop, then graph, then details and links.
5. **Compose and Caddy**: deploy.

---

## 9. Open questions
1. ~~Crash logging~~: decided. Failing inputs are logged (§5.2), and users agree to it first (§6.6).
2. **Pill fan-out.** One pill per `(declaration group, member)` matches the prototypes. But an extension with *d* dependencies that introduces *m* members draws *d × m* lines. If that gets noisy, the fallback is one pill per extension with *m* outgoing lines, which the prototypes neither show nor contradict.
