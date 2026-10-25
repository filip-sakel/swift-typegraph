// The one piece of shared state (SPEC §6.4): the source, the latest analysis,
// and what's hovered and selected. The editor, graph and details panel all
// read and write it.

import { analyze } from './api/client'
import type { AnalyzeResponse, DeclGroup, Diagnostic, Graph, MemberNode, Pill, Range, TypeSyntaxInfo } from './api/types'

export type Kind = 'member' | 'declGroup' | 'typeSyntax' | 'file'
export interface Sel {
  kind: Kind
  id: string
}

export const sameSel = (a: Sel | undefined, b: Sel | undefined) => a?.kind === b?.kind && a?.id === b?.id

export const MAX_SOURCE_BYTES = 8192
const DEBOUNCE_MS = 300
const CONSENT_KEY = 'typegraph.consent'
const SIMPLIFY_KEY = 'typegraph.simplifyNames'
const MODULE_KEY = 'typegraph.moduleName'
export const DEFAULT_MODULE_NAME = 'MyModule'
const FILE_KEY = 'typegraph.fileName'
export const DEFAULT_FILE_NAME = 'main.swift'

/** An ASCII Swift identifier; the gateway rejects anything else. */
export const isValidModuleName = (name: string) => /^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(name)
/** `<stem>.swift` in ASCII letters, digits, `_`, `-` and `.`, ≤ 64 characters; the gateway rejects anything else. */
export const isValidFileName = (name: string) => /^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,57}\.swift$/.test(name)

function load(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

function save(key: string, value: string) {
  try {
    localStorage.setItem(key, value)
  } catch {
    // Private mode: the setting lasts for this tab only.
  }
}

/** A successful analysis and lookups into it. */
export class Analysis {
  readonly members = new Map<string, MemberNode>()
  readonly groups = new Map<string, DeclGroup>()
  readonly typeSyntaxes = new Map<string, TypeSyntaxInfo>()
  readonly pillsByGroup = new Map<string, Pill[]>()
  private readonly lineStarts: number[] = [0]

  constructor(
    readonly revision: number,
    readonly source: string,
    readonly graph: Graph,
  ) {
    for (const m of graph.members) this.members.set(m.id, m)
    for (const g of graph.declGroups) this.groups.set(g.id, g)
    for (const t of graph.typeSyntaxes) this.typeSyntaxes.set(t.id, t)
    for (const p of graph.pills) {
      const key = p.selects.kind === 'declGroup' ? p.selects.id : `${p.selects.kind}:${p.selects.id}`
      this.pillsByGroup.set(key, [...(this.pillsByGroup.get(key) ?? []), p])
    }
    for (let i = 0; i < source.length; i++) if (source.charCodeAt(i) === 10) this.lineStarts.push(i + 1)
  }

  /** UTF-16 offset into `source`. */
  offset(line: number, column: number): number {
    return (this.lineStarts[line - 1] ?? this.source.length) + column - 1
  }

  /** The source ranges an entity covers, as offsets into `source`. */
  ranges(sel: Sel): [number, number][] {
    const span = (r: Range): [number, number] => [this.offset(r.start.line, r.start.column), this.offset(r.end.line, r.end.column)]
    switch (sel.kind) {
      case 'member':
        return (this.members.get(sel.id)?.decls ?? []).map((d) => span(d.range))
      case 'declGroup': {
        const group = this.groups.get(sel.id)
        return group ? [span(group.range)] : []
      }
      case 'typeSyntax': {
        const t = this.typeSyntaxes.get(sel.id)
        return t ? [span(t.range)] : []
      }
      case 'file':
        // The editor outlines itself instead.
        return []
    }
  }

  /** Every entity with its source range, for cursor hit-testing. */
  *hitTargets(): Generator<{ sel: Sel; from: number; to: number; rank: number }> {
    // On ties (`struct D {}` is both a member decl and a decl group), the
    // lower rank wins: type syntax, then member, then decl group.
    for (const t of this.graph.typeSyntaxes) {
      const [from, to] = this.ranges({ kind: 'typeSyntax', id: t.id })[0]
      yield { sel: { kind: 'typeSyntax', id: t.id }, from, to, rank: 0 }
    }
    for (const m of this.graph.members) {
      for (const [from, to] of this.ranges({ kind: 'member', id: m.id })) {
        yield { sel: { kind: 'member', id: m.id }, from, to, rank: 1 }
      }
    }
    for (const g of this.graph.declGroups) {
      const [from, to] = this.ranges({ kind: 'declGroup', id: g.id })[0]
      yield { sel: { kind: 'declGroup', id: g.id }, from, to, rank: 2 }
    }
  }

  /** Whether `sel` still names something in this analysis. */
  has(sel: Sel): boolean {
    switch (sel.kind) {
      case 'member':
        return this.members.has(sel.id)
      case 'declGroup':
        return this.groups.has(sel.id)
      case 'typeSyntax':
        return this.typeSyntaxes.has(sel.id)
      case 'file':
        return this.pillsByGroup.has(`file:${sel.id}`)
    }
  }
}

/** What the header badge shows. */
export type Activity = 'idle' | 'running' | 'ok' | 'syntax' | 'failed' | 'offline'

class Store {
  source = $state('')
  sourceBytes = $derived(new TextEncoder().encode(this.source).length)
  tooLarge = $derived(this.sourceBytes > MAX_SOURCE_BYTES)

  consented = $state(load(CONSENT_KEY) !== null)
  aboutOpen = $state(load(CONSENT_KEY) === null)
  simplifyNames = $state(load(SIMPLIFY_KEY) !== '0')
  moduleName = $state(load(MODULE_KEY) ?? DEFAULT_MODULE_NAME)
  fileName = $state(load(FILE_KEY) ?? DEFAULT_FILE_NAME)

  /** The latest successful analysis; kept (dimmed) while newer input fails. */
  analysis = $state.raw<Analysis | undefined>()
  /** The latest response of any kind. */
  last = $state.raw<AnalyzeResponse | undefined>()
  diagnostics = $state.raw<Diagnostic[]>([])
  activity = $state<Activity>('idle')
  /** Whether `analysis` lags behind `source`. */
  stale = $state(false)

  hovered = $state.raw<Sel | undefined>()
  /** What the details panel shows instead of the selection while hovering the graph. */
  preview = $state.raw<Sel | undefined>()
  selected = $state.raw<Sel | undefined>()
  private back: Sel[] = []
  private forward: Sel[] = []

  private revision = 0
  private timer: ReturnType<typeof setTimeout> | undefined
  /** Called with each new analysis's revision; the editor maps ranges from it. */
  onAnalysis: ((revision: number) => void) | undefined
  /** Called when a request goes out; the editor starts tracking edits from it. */
  onSend: ((revision: number) => void) | undefined

  agree() {
    save(CONSENT_KEY, new Date().toISOString())
    this.consented = true
    this.aboutOpen = false
    this.run()
  }

  setSimplifyNames(on: boolean) {
    this.simplifyNames = on
    save(SIMPLIFY_KEY, on ? '1' : '0')
  }

  /** Re-analyzes under the new name, debounced like an edit. */
  setModuleName(name: string) {
    if (!isValidModuleName(name) || name === this.moduleName) return
    this.moduleName = name
    save(MODULE_KEY, name)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.run(), DEBOUNCE_MS)
  }

  /** Re-analyzes under the new name, debounced like an edit. */
  setFileName(name: string) {
    if (!isValidFileName(name) || name === this.fileName) return
    this.fileName = name
    save(FILE_KEY, name)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.run(), DEBOUNCE_MS)
  }

  edit(source: string) {
    this.source = source
    this.stale = true
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.run(), DEBOUNCE_MS)
  }

  /** Analyzes the current source now (the Run button). */
  async run() {
    clearTimeout(this.timer)
    if (!this.consented) {
      this.aboutOpen = true
      return
    }
    if (this.tooLarge) {
      this.last = { status: 'tooLarge', limit: MAX_SOURCE_BYTES }
      this.activity = 'failed'
      return
    }
    const revision = ++this.revision
    const source = this.source
    this.onSend?.(revision)
    this.activity = 'running'
    const response = await analyze(revision, source, this.moduleName, this.fileName)
    if (response.revision !== this.revision) return
    this.receive(response, source)
  }

  private receive(response: AnalyzeResponse, source: string) {
    if (response.status === 'superseded') return
    this.last = response
    switch (response.status) {
      case 'ok': {
        const analysis = new Analysis(response.revision ?? this.revision, source, response.graph!)
        this.analysis = analysis
        // Type-resolution failures.
        this.diagnostics = response.diagnostics ?? []
        this.stale = false
        this.activity = response.invariantViolation ? 'failed' : 'ok'
        if (this.selected && !analysis.has(this.selected)) this.selected = undefined
        if (this.hovered && !analysis.has(this.hovered)) this.hovered = undefined
        if (this.preview && !analysis.has(this.preview)) this.preview = undefined
        this.onAnalysis?.(analysis.revision)
        break
      }
      case 'parseErrors':
        this.diagnostics = response.diagnostics ?? []
        this.activity = 'syntax'
        break
      case 'consentRequired':
        this.consented = false
        this.aboutOpen = true
        this.activity = 'idle'
        break
      case 'offline':
        this.activity = 'offline'
        break
      case 'busy':
      case 'rateLimited':
        this.activity = 'failed'
        // Try again once things calm down, unless the user edits first.
        clearTimeout(this.timer)
        this.timer = setTimeout(() => this.run(), 2000)
        break
      default:
        this.activity = 'failed'
    }
  }

  // MARK: Selection

  /** `preview`: also show `sel` in the details panel (graph hovers). */
  hover(sel: Sel | undefined, preview = false) {
    if (!sameSel(sel, this.hovered)) this.hovered = sel
    const shown = preview ? sel : undefined
    if (!sameSel(shown, this.preview)) this.preview = shown
  }

  /** Selects from a click or link, recording history. */
  select(sel: Sel | undefined) {
    if (sameSel(sel, this.selected)) return
    if (this.selected) this.back.push(this.selected)
    this.forward = []
    this.selected = sel
    this.revealRequested++
  }

  /** Selects from the cursor, without history or scrolling. */
  follow(sel: Sel | undefined) {
    if (!sameSel(sel, this.selected)) this.selected = sel
  }

  goBack() {
    const sel = this.back.pop()
    if (!sel) return
    if (this.selected) this.forward.push(this.selected)
    this.selected = sel
    this.revealRequested++
  }

  goForward() {
    const sel = this.forward.pop()
    if (!sel) return
    if (this.selected) this.back.push(this.selected)
    this.selected = sel
    this.revealRequested++
  }

  /** Bumped when the editor should scroll the selection into view. */
  revealRequested = $state(0)

  /** The display name of a type, per the Settings toggle. */
  typeName(t: { full: string; simple: string } | undefined): string {
    if (!t) return this.analysis?.graph.root.display ?? this.moduleName
    return this.simplifyNames ? t.simple : t.full
  }

  memberLabel(m: MemberNode): string {
    return `${this.typeName(m.base)} > ${m.name}`
  }
}

export const store = new Store()
