<script lang="ts">
  // The details panel (SPEC §6.5): everything the analysis knows about the
  // selected (or, while hovering the graph, previewed) entity. Every name that
  // stands for something else is a link that selects it.

  import type { Snippet } from 'svelte'
  import type { Failure, MemberNode, Range, TypeName, TypeResult } from '../api/types'
  import { sameSel, store, type Sel } from '../store.svelte'

  const shown = $derived(store.preview ?? store.selected)
  const analysis = $derived(store.analysis)

  const member = $derived(shown?.kind === 'member' ? analysis?.members.get(shown.id) : undefined)
  const group = $derived(shown?.kind === 'declGroup' ? analysis?.groups.get(shown.id) : undefined)
  const typeSyntax = $derived(shown?.kind === 'typeSyntax' ? analysis?.typeSyntaxes.get(shown.id) : undefined)
  /** The file's pills lead to its top-level members. */
  const file = $derived(
    shown?.kind === 'file' && analysis?.has(shown)
      ? { name: shown.id, declares: (analysis.pillsByGroup.get(`file:${shown.id}`) ?? []).flatMap((p) => (p.to ? [p.to] : [])) }
      : undefined,
  )

  const reasons: Record<string, string> = {
    notNominal: 'not a nominal type',
    missing: 'no such member',
    notAdmitted: 'not admitted',
  }

  function href(sel: Sel) {
    return `#${sel.kind}/${encodeURIComponent(sel.id)}`
  }

  function follow(event: MouseEvent, sel: Sel) {
    event.preventDefault()
    store.hover(undefined)
    store.select(sel)
  }

  function leave(sel: Sel) {
    if (sameSel(store.hovered, sel)) store.hover(undefined)
  }

  const lines = (r: Range) =>
    r.start.line === r.end.line ? `line ${r.start.line}` : `lines ${r.start.line}–${r.end.line}`

  /** Members that a type's base points at, for parent links. */
  function parentOf(m: MemberNode): Sel | undefined {
    return m.base?.member ? { kind: 'member', id: m.base.member } : undefined
  }
</script>

{#snippet link(sel: Sel, text: string, extra?: string)}
  <a
    href={href(sel)}
    class:struck={extra === 'missing'}
    onclick={(e) => follow(e, sel)}
    onpointerenter={() => store.hover(sel)}
    onpointerleave={() => leave(sel)}><code>{text}</code></a
  >{#if extra}{' '}<span class="note">({extra})</span>{/if}
{/snippet}

{#snippet memberLink(id: string)}
  {@const m = analysis?.members.get(id)}
  {#if m}
    {@render link({ kind: 'member', id }, store.memberLabel(m), m.status === 'resolved' ? undefined : m.status)}
  {:else}
    <code>{id}</code>
  {/if}
{/snippet}

{#snippet groupLink(id: string)}
  {@const g = analysis?.groups.get(id)}
  {#if g}
    {@render link({ kind: 'declGroup', id }, g.label)}
  {:else}
    <code>{analysis?.graph.root.display ?? id}</code>
  {/if}
{/snippet}

{#snippet typeName(t: TypeName)}
  {#if t.member}
    {@render link({ kind: 'member', id: t.member }, store.typeName(t))}
  {:else}
    <code>{store.typeName(t)}</code>
  {/if}
{/snippet}

{#snippet typeResult(r: TypeResult)}
  {#if r.kind === 'nominal'}
    {#each r.types as t, i (t.id)}{#if i > 0}<span class="sep"> or </span>{/if}{@render typeName(t)}{/each}
    {#if r.types.length > 1}<span class="note"> (ambiguous)</span>{/if}
  {:else if r.kind === 'function'}
    <code>function</code><span class="note"> ({r.argumentCount} argument{r.argumentCount === 1 ? '' : 's'})</span>
  {:else if r.kind === 'tuple'}
    <code>({r.labels.map((l) => (l ? `${l}: _` : '_')).join(', ')})</code>
  {:else if r.kind === 'any'}
    <code>Any</code>
  {:else if r.kind === 'metatype'}
    {@render typeResult(r.base)}<code>.Type</code>
  {:else}
    {@render failure(r.failure)}
  {/if}
{/snippet}

{#snippet failure(f: Failure)}
  <span class="failure">
    <code title={f.kind}>{f.message}</code>
    {#if f.members.length}
      <span class="note">—</span>
      {#each f.members as id, i (id)}{#if i > 0}, {/if}{@render memberLink(id)}{/each}
    {/if}
    {#if f.ranges.length}
      <span class="note">({f.ranges.map(lines).join(', ')})</span>
    {/if}
  </span>
  {#if f.children.length}
    <ul class="children">
      {#each f.children as child, i (i)}
        <li>{@render failure(child)}</li>
      {/each}
    </ul>
  {/if}
{/snippet}

{#snippet list(ids: string[], render: Snippet<[string]>, empty: string)}
  {#if ids.length === 0}
    <span class="note">{empty}</span>
  {:else}
    {#each ids as id, i (id)}{#if i > 0}, {/if}{@render render(id)}{/each}
  {/if}
{/snippet}

<section class="details" class:previewing={store.preview !== undefined} aria-label="Details">
  {#if member}
    <h2>Member: <code>{store.memberLabel(member)}</code></h2>
    <ul>
      <li>
        Parent:
        {#if parentOf(member)}
          {@render link(parentOf(member)!, store.typeName(member.base))}
        {:else}
          <code>{store.typeName(member.base)}</code>
        {/if}
      </li>
      <li>
        Declarations:
        {#if member.decls.length === 0}
          <span class="note">none (missing; contained by the base's main declaration)</span>
        {:else}
          {#each member.decls as decl, i (i)}{#if i > 0}, {/if}<code>{decl.kind} {member.name}</code>
            <span class="note">({lines(decl.range)}{#if decl.parent !== 'root'}, in {/if}</span
            >{#if decl.parent !== 'root'}{@render groupLink(decl.parent)}{/if}<span class="note">)</span>{/each}
          {#if member.status === 'ambiguous'}<span class="note"> — redeclared</span>{/if}
        {/if}
      </li>
      <li>
        {#if member.admits.ok && member.admits.type}
          Admits: {@render typeName(member.admits.type)}
        {:else if member.admits.reason === 'notNominal' && member.resolvedTo}
          Alias for: {@render typeResult(member.resolvedTo)}
        {:else if member.admits.reason === 'redeclared'}
          <span class="no">Redeclaration</span>
        {:else if member.admits.reason === 'missing'}
          <span class="no">Nonexistent</span>
        {:else}
          Admits: <span class="no">nothing</span>
          <span class="note">({reasons[member.admits.reason ?? ''] ?? member.admits.reason ?? 'unknown'})</span>
        {/if}
      </li>
      <li>
        Dependents: {@render list(member.dependents, groupLink, 'none')}
      </li>
    </ul>
  {:else if group}
    <h2>Syntax: <code>{group.label}</code> <span class="note">{lines(group.range)}</span></h2>
    <ul>
      <li>Dependencies: {@render list(group.dependencies, memberLink, 'none')}</li>
      {#if group.resolvedTo}
        <li>
          Resolved to:
          {#if group.resolvedTo.ok && group.resolvedTo.type}
            {@render typeName(group.resolvedTo.type)}
          {:else if group.resolvedTo.failure}
            {@render failure(group.resolvedTo.failure)}
          {:else}
            <span class="no">failed</span>
          {/if}
        </li>
      {/if}
      <li>Introduces: {@render list(group.introduces, memberLink, 'nothing')}</li>
    </ul>
  {:else if typeSyntax}
    <h2>Type: <code>{typeSyntax.text}</code> <span class="note">{lines(typeSyntax.range)}</span></h2>
    <ul>
      <li>Resolved to: {@render typeResult(typeSyntax.result)}</li>
      <li>In: {@render groupLink(typeSyntax.owner)}</li>
    </ul>
  {:else if file}
    <h2>File: <code>{file.name}</code></h2>
    <ul>
      <li>Declares: {@render list(file.declares, memberLink, 'nothing')}</li>
    </ul>
  {:else if analysis}
    <p class="hint">Put the cursor in a declaration or type, or click a node in the graph.</p>
  {:else}
    <p class="hint">Details appear here once the code is analyzed.</p>
  {/if}
</section>

<style>
  .details {
    height: 100%;
    overflow: auto;
    padding: 12px 18px;
    border: 2px solid var(--accent);
    border-radius: 14px;
    background: var(--surface);
    color: var(--text);
    font-size: 15px;
    line-height: 1.6;
  }
  .details.previewing {
    border-style: dashed;
  }
  h2 {
    margin: 0 0 6px;
    font-size: 18px;
    font-weight: 400;
  }
  ul {
    margin: 0;
    padding-left: 22px;
  }
  .children {
    padding-left: 18px;
    list-style: circle;
  }
  code {
    font-family: var(--mono);
    font-size: 0.95em;
  }
  a {
    color: var(--accent);
    text-decoration: none;
    border-radius: 3px;
  }
  a:hover {
    text-decoration: underline;
    background: var(--hover-tint);
  }
  a.struck code {
    text-decoration: line-through;
  }
  .note,
  .sep,
  .hint {
    color: var(--muted);
  }
  .no {
    color: var(--error);
  }
  .failure code {
    color: var(--error);
  }
</style>
