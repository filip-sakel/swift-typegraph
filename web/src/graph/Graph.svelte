<script lang="ts">
  // The type-member graph (SPEC §6.3), drawn as SVG from ELK's layout, with
  // pan and zoom. Hovering and clicking go through the store.

  import type { Pill, TypeResult } from '../api/types'
  import { sameSel, store, type Sel } from '../store.svelte'
  import { layout, pillNodeId, type LaidOutNode, type Layout } from './layout'

  let svg: SVGSVGElement
  let current = $state.raw<Layout | undefined>()
  let view = $state({ x: 0, y: 0, k: 1 })
  let fitted = false
  let layoutRun = 0

  const pillById = $derived(new Map((store.analysis?.graph.pills ?? []).map((p) => [pillNodeId(p.id), p])))

  $effect(() => {
    const analysis = store.analysis
    // Labels depend on the setting.
    const label = (id: string) => store.memberLabel(analysis!.members.get(id)!)
    if (!analysis) return
    const run = ++layoutRun
    layout(analysis.graph, label).then((result) => {
      if (run !== layoutRun) return
      current = result
      if (!fitted) fit()
    })
  })

  function fit() {
    if (!current || !svg) return
    const { width, height } = svg.getBoundingClientRect()
    if (width === 0 || height === 0) return
    const k = Math.min(1.25, width / current.width, height / current.height)
    view = { k, x: (width - current.width * k) / 2, y: Math.max(0, (height - current.height * k) / 2) * 0.3 }
    fitted = true
  }

  // MARK: What a node stands for

  function selOf(node: LaidOutNode): Sel | undefined {
    if (node.kind === 'member') return { kind: 'member', id: node.id }
    if (node.kind === 'pill') return pillById.get(node.id)?.selects
    return undefined
  }

  function admittedMembers(result: TypeResult | undefined): string[] {
    if (!result) return []
    if (result.kind === 'nominal') return result.types.flatMap((t) => (t.member ? [t.member] : []))
    if (result.kind === 'metatype') return admittedMembers(result.base)
    return []
  }

  /** Graph node ids lit up by a selection (SPEC §6.4 "Highlight targets"). */
  function litNodes(sel: Sel | undefined): Set<string> {
    const lit = new Set<string>()
    const analysis = store.analysis
    if (!sel || !analysis) return lit
    switch (sel.kind) {
      case 'member':
        lit.add(sel.id)
        for (const p of analysis.pillsByGroup.get(`member:${sel.id}`) ?? []) lit.add(pillNodeId(p.id))
        break
      case 'declGroup':
        for (const p of analysis.pillsByGroup.get(sel.id) ?? []) lit.add(pillNodeId(p.id))
        break
      case 'file':
        for (const p of analysis.pillsByGroup.get(`file:${sel.id}`) ?? []) lit.add(pillNodeId(p.id))
        break
      case 'typeSyntax':
        for (const id of admittedMembers(analysis.typeSyntaxes.get(sel.id)?.result)) lit.add(id)
        break
    }
    return lit
  }

  const selectedNodes = $derived(litNodes(store.selected))
  const hoveredNodes = $derived(litNodes(store.hovered))
  const outlineOnly = $derived(store.selected?.kind === 'typeSyntax')

  function nodeClass(node: LaidOutNode): string {
    const classes: string[] = [node.kind]
    const member = node.kind === 'member' ? store.analysis?.members.get(node.id) : undefined
    const pill: Pill | undefined = node.kind === 'pill' ? pillById.get(node.id) : undefined
    if (member?.status === 'missing' || pill?.struck) classes.push('struck')
    if (member?.status === 'ambiguous') classes.push('ambiguous')
    if (selectedNodes.has(node.id)) classes.push(outlineOnly ? 'outlined' : 'selected')
    else if (hoveredNodes.has(node.id)) classes.push('hovered')
    return classes.join(' ')
  }

  function edgeLit(pill: string | undefined): boolean {
    return pill !== undefined && selectedNodes.has(pillNodeId(pill))
  }

  // MARK: Pan and zoom

  let drag: { x: number; y: number; moved: boolean } | undefined

  function onWheel(event: WheelEvent) {
    event.preventDefault()
    const rect = svg.getBoundingClientRect()
    const px = event.clientX - rect.left
    const py = event.clientY - rect.top
    const k = Math.min(3, Math.max(0.2, view.k * Math.exp(-event.deltaY * 0.0015)))
    view = { k, x: px - ((px - view.x) * k) / view.k, y: py - ((py - view.y) * k) / view.k }
  }

  function onPointerDown(event: PointerEvent) {
    if (event.button !== 0) return
    drag = { x: event.clientX, y: event.clientY, moved: false }
  }

  function onPointerMove(event: PointerEvent) {
    if (!drag) return
    const dx = event.clientX - drag.x
    const dy = event.clientY - drag.y
    if (!drag.moved && Math.hypot(dx, dy) < 4) return
    if (!drag.moved) svg.setPointerCapture(event.pointerId)
    drag.moved = true
    view = { ...view, x: view.x + dx, y: view.y + dy }
    drag.x = event.clientX
    drag.y = event.clientY
  }

  function onPointerUp(event: PointerEvent) {
    if (drag && !drag.moved && event.target === svg) store.select(undefined)
    drag = undefined
  }

  function onNodeClick(node: LaidOutNode) {
    if (drag?.moved) return
    store.select(selOf(node))
  }

  function points(list: { x: number; y: number }[]) {
    return list.map((p) => `${p.x},${p.y}`).join(' ')
  }
</script>

<div class="graph" class:dimmed={store.stale && store.activity !== 'running'}>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <svg
    bind:this={svg}
    onwheel={onWheel}
    onpointerdown={onPointerDown}
    onpointermove={onPointerMove}
    onpointerup={onPointerUp}
  >
    <defs>
      <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
        <path d="M 1 1 L 9 5 L 1 9" fill="none" stroke="context-stroke" stroke-width="1.6" />
      </marker>
    </defs>
    {#if current}
      <g transform="translate({view.x},{view.y}) scale({view.k})">
        {#each current.edges as edge (edge.id)}
          <polyline
            class="edge"
            class:lit={edgeLit(edge.pill)}
            points={points(edge.points)}
            marker-end={edge.arrow ? 'url(#arrow)' : undefined}
          />
        {/each}
        {#each current.nodes as node (node.id)}
          {@const sel = selOf(node)}
          <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_tabindex -->
          <g
            class="node {nodeClass(node)}"
            style="transform: translate({node.x}px, {node.y}px)"
            role={sel ? 'button' : undefined}
            tabindex={sel ? 0 : undefined}
            onpointerenter={() => store.hover(sel, true)}
            onpointerleave={() => sameSel(store.hovered, sel) && store.hover(undefined)}
            onclick={() => onNodeClick(node)}
            onkeydown={(e) => e.key === 'Enter' && onNodeClick(node)}
          >
            <rect width={node.width} height={node.height} rx={node.kind === 'pill' ? 9 : 8} />
            <text x={node.width / 2} y={node.height / 2}>{node.label}</text>
          </g>
        {/each}
      </g>
    {/if}
  </svg>
  <div class="controls">
    <button onclick={fit} title="Fit graph to view">Fit</button>
  </div>
  {#if store.analysis && store.activity === 'syntax'}
    <div class="note">
      Showing the last valid analysis: {store.diagnostics.filter((d) => d.severity === 'error').length} syntax error(s)
    </div>
  {/if}
  {#if !store.analysis}
    <div class="empty">
      {store.consented ? (store.activity === 'running' ? 'Analyzing…' : 'No analysis yet') : 'Agree to the About notice to start analyzing'}
    </div>
  {/if}
</div>

<style>
  .graph {
    position: relative;
    height: 100%;
    overflow: hidden;
    transition: opacity 150ms;
  }
  .graph.dimmed svg {
    opacity: 0.55;
  }
  svg {
    width: 100%;
    height: 100%;
    display: block;
    cursor: grab;
    touch-action: none;
    user-select: none;
  }
  .edge {
    fill: none;
    stroke: var(--text);
    stroke-width: 1.4;
  }
  .edge.lit {
    stroke: var(--accent);
    stroke-width: 2;
  }
  .node {
    transition: transform 250ms ease;
    cursor: pointer;
  }
  .node.root {
    cursor: default;
  }
  .node rect {
    fill: var(--node-fill);
    stroke: var(--node-stroke);
    stroke-width: 1;
  }
  .node.pill rect {
    fill: var(--surface);
    stroke: var(--pill-stroke);
  }
  .node text {
    font-family: var(--mono);
    font-size: 14px;
    fill: var(--text);
    dominant-baseline: central;
    text-anchor: middle;
  }
  .node.pill text {
    font-size: 13px;
  }
  .node.struck text {
    text-decoration: line-through;
  }
  .node.ambiguous rect {
    stroke: var(--warning);
    stroke-width: 2;
    stroke-dasharray: 5 3;
  }
  .node.hovered rect {
    fill: var(--hover-tint);
  }
  .node.selected rect {
    fill: var(--accent);
    stroke: var(--accent);
  }
  .node.selected text {
    fill: white;
  }
  .node.outlined rect {
    stroke: var(--accent);
    stroke-width: 2.5;
  }
  .node:focus {
    outline: none;
  }
  .node:focus-visible rect {
    stroke: var(--accent);
    stroke-width: 2;
  }
  .controls {
    position: absolute;
    right: 12px;
    bottom: 12px;
  }
  .controls button {
    font: inherit;
    font-size: 13px;
    padding: 4px 10px;
    border-radius: 6px;
    border: 1px solid var(--border);
    background: var(--surface);
    color: var(--text);
    cursor: pointer;
  }
  .note,
  .empty {
    position: absolute;
    left: 12px;
    top: 10px;
    font-size: 13px;
    color: var(--muted);
  }
  .note {
    top: auto;
    bottom: 12px;
    color: var(--warning-text);
    background: var(--warning-bg);
    padding: 4px 10px;
    border-radius: 6px;
  }
</style>
