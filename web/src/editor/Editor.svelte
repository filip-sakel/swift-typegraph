<script lang="ts">
  // CodeMirror, wired to the store (SPEC §6.2, §6.4): edits trigger analysis,
  // the cursor selects the innermost entity, and the hovered and selected
  // entities are highlighted. Server ranges refer to the source that was sent,
  // so they're mapped through every edit made since.

  import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
  import { bracketMatching, indentOnInput, StreamLanguage, syntaxHighlighting, defaultHighlightStyle } from '@codemirror/language'
  import { swift } from '@codemirror/legacy-modes/mode/swift'
  import { lintGutter, setDiagnostics, type Diagnostic as LintDiagnostic } from '@codemirror/lint'
  import { ChangeSet, EditorState, StateEffect, StateField, type ChangeDesc, type Text } from '@codemirror/state'
  import { Decoration, EditorView, highlightActiveLineGutter, keymap, lineNumbers, type DecorationSet } from '@codemirror/view'
  import { onMount, untrack } from 'svelte'
  import { store, type Sel } from '../store.svelte'

  let host: HTMLDivElement
  let view: EditorView

  /** The doc each request was sent with, and the edits made since. */
  const snapshots = new Map<number, { doc: Text; changes: ChangeDesc }>()

  function toOffset(revision: number, line: number, column: number): number | undefined {
    const snapshot = snapshots.get(revision)
    if (!snapshot || line > snapshot.doc.lines) return undefined
    const offset = Math.min(snapshot.doc.line(line).from + column - 1, snapshot.doc.length)
    return snapshot.changes.mapPos(offset, 1)
  }

  /** Maps a `[from, to)` offset range in revision `revision`'s doc to the current doc. */
  function mapSpan(revision: number, from: number, to: number): [number, number] | undefined {
    const snapshot = snapshots.get(revision)
    if (!snapshot) return undefined
    const a = snapshot.changes.mapPos(from, 1)
    const b = snapshot.changes.mapPos(to, -1)
    return a < b ? [a, b] : undefined
  }

  // MARK: Highlights

  const setHighlights = StateEffect.define<DecorationSet>()
  const highlights = StateField.define<DecorationSet>({
    create: () => Decoration.none,
    update(value, tr) {
      for (const effect of tr.effects) if (effect.is(setHighlights)) return effect.value
      return value.map(tr.changes)
    },
    provide: (field) => EditorView.decorations.from(field),
  })

  function spans(sel: Sel | undefined): [number, number][] {
    const analysis = store.analysis
    if (!sel || !analysis) return []
    return analysis.ranges(sel).flatMap(([from, to]) => {
      const span = mapSpan(analysis.revision, from, to)
      return span ? [span] : []
    })
  }

  function updateHighlights() {
    if (!view) return
    const marks = [
      ...spans(store.hovered).map(([f, t]) => Decoration.mark({ class: 'tg-hovered' }).range(f, t)),
      ...spans(store.selected).map(([f, t]) => Decoration.mark({ class: 'tg-selected' }).range(f, t)),
    ]
    view.dispatch({ effects: setHighlights.of(Decoration.set(marks, true)) })
  }

  // MARK: Cursor → selection

  /** The innermost entity containing `pos` (SPEC §6.4). */
  function entityAt(pos: number): Sel | undefined {
    const analysis = store.analysis
    if (!analysis) return undefined
    let best: { sel: Sel; size: number; rank: number } | undefined
    for (const target of analysis.hitTargets()) {
      const span = mapSpan(analysis.revision, target.from, target.to)
      if (!span || pos < span[0] || pos > span[1]) continue
      const size = span[1] - span[0]
      if (!best || size < best.size || (size === best.size && target.rank < best.rank)) {
        best = { sel: target.sel, size, rank: target.rank }
      }
    }
    return best?.sel
  }

  // MARK: Setup

  onMount(() => {
    view = new EditorView({
      parent: host,
      state: EditorState.create({
        doc: store.source,
        extensions: [
          lineNumbers(),
          highlightActiveLineGutter(),
          history(),
          indentOnInput(),
          bracketMatching(),
          EditorState.tabSize.of(2),
          StreamLanguage.define(swift),
          syntaxHighlighting(defaultHighlightStyle),
          lintGutter(),
          highlights,
          keymap.of([indentWithTab, ...defaultKeymap, ...historyKeymap]),
          EditorView.updateListener.of((update) => {
            if (update.docChanged) {
              for (const snapshot of snapshots.values()) snapshot.changes = snapshot.changes.composeDesc(update.changes.desc)
              store.edit(update.state.doc.toString())
            }
            if (update.selectionSet && update.view.hasFocus) {
              store.follow(entityAt(update.state.selection.main.head))
            }
          }),
        ],
      }),
    })

    store.onSend = (revision) => {
      snapshots.set(revision, { doc: view.state.doc, changes: ChangeSet.empty(view.state.doc.length).desc })
    }
    store.onAnalysis = (revision) => {
      // Older snapshots can't be needed any more.
      for (const key of snapshots.keys()) if (key < revision) snapshots.delete(key)
    }

    const keys = (event: KeyboardEvent) => {
      if (!event.altKey) return
      if (event.key === 'ArrowLeft') store.goBack()
      else if (event.key === 'ArrowRight') store.goForward()
      else return
      event.preventDefault()
    }
    window.addEventListener('keydown', keys)
    return () => {
      window.removeEventListener('keydown', keys)
      view.destroy()
    }
  })

  $effect(() => {
    // Re-run on any change to these.
    void [store.hovered, store.selected, store.analysis]
    updateHighlights()
  })

  $effect(() => {
    const diagnostics = store.diagnostics
    const revision = store.last?.revision
    if (!view) return
    const mapped: LintDiagnostic[] =
      revision === undefined
        ? []
        : diagnostics.flatMap((d) => {
            const from = toOffset(revision, d.range.start.line, d.range.start.column)
            const to = toOffset(revision, d.range.end.line, d.range.end.column)
            if (from === undefined || to === undefined) return []
            return [{ from, to: Math.max(from, to), severity: d.severity === 'note' ? 'info' : d.severity, message: d.message }]
          })
    view.dispatch(setDiagnostics(view.state, mapped))
  })

  $effect(() => {
    if (store.revealRequested === 0 || !view) return
    // Only on explicit requests, not on every cursor-driven selection.
    untrack(() => {
      const [first] = spans(store.selected)
      if (first) view.dispatch({ effects: EditorView.scrollIntoView(first[0], { y: 'center' }) })
    })
  })
</script>

<div class="editor" bind:this={host}></div>

<style>
  .editor {
    height: 100%;
    overflow: hidden;
  }
  .editor :global(.cm-editor) {
    height: 100%;
    font-size: 15px;
  }
  .editor :global(.cm-editor.cm-focused) {
    outline: none;
  }
  .editor :global(.cm-scroller) {
    font-family: var(--mono);
    line-height: 1.6;
  }
  .editor :global(.cm-gutters) {
    background: var(--panel);
    border-right: 1px solid var(--border);
    color: var(--muted);
  }
  .editor :global(.tg-hovered) {
    background: var(--hover-tint);
    border-radius: 3px;
  }
  .editor :global(.tg-selected) {
    background: var(--selection-tint);
    border-radius: 3px;
  }
</style>
