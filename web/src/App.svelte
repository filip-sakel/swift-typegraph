<script lang="ts">
  // Layout (SPEC §6.1): header, editor | graph, details panel underneath.

  import { onMount } from 'svelte'
  import Details from './details/Details.svelte'
  import Editor from './editor/Editor.svelte'
  import Graph from './graph/Graph.svelte'
  import { MAX_SOURCE_BYTES, store } from './store.svelte'
  import About from './ui/About.svelte'
  import Header from './ui/Header.svelte'
  import StatusBanner from './ui/StatusBanner.svelte'

  onMount(() => {
    if (store.consented) store.run()
  })

  const stats = $derived(store.last?.status === 'ok' ? store.last.stats : undefined)
</script>

<div class="app">
  <Header />
  <StatusBanner />

  <main>
    <div class="pane editor-pane">
      <div class="editor"><Editor /></div>
      <footer>
        <span class:over={store.tooLarge}>{store.sourceBytes.toLocaleString()} / {MAX_SOURCE_BYTES.toLocaleString()} bytes</span>
        {#if stats}
          <span>{stats.elapsedMs.toFixed(1)} ms · {(stats.peakMemoryKiB / 1024).toFixed(1)} MiB</span>
        {/if}
      </footer>
    </div>
    <div class="pane graph-pane"><Graph /></div>
  </main>

  <div class="details"><Details /></div>
</div>

<About />

<style>
  .app {
    display: flex;
    flex-direction: column;
    gap: 12px;
    height: 100dvh;
    padding: 14px 16px 16px;
    box-sizing: border-box;
  }
  main {
    flex: 1 1 0;
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    min-height: 0;
    border: 1px solid var(--border);
    border-radius: 14px;
    overflow: hidden;
    background: var(--surface);
  }
  .pane {
    min-width: 0;
    min-height: 0;
  }
  .editor-pane {
    display: grid;
    grid-template-rows: minmax(0, 1fr) auto;
    border-right: 3px solid var(--border);
  }
  .editor {
    min-width: 0;
    min-height: 0;
    overflow: hidden;
  }
  footer {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    padding: 4px 12px;
    border-top: 1px solid var(--border);
    color: var(--muted);
    font-size: 12px;
    font-variant-numeric: tabular-nums;
  }
  .over {
    color: var(--error);
    font-weight: 600;
  }
  .details {
    flex: 0 0 max(140px, 26vh);
    min-height: 0;
  }
  @media (max-width: 760px) {
    .app {
      height: auto;
    }
    main {
      flex: none;
      grid-template-columns: 1fr;
      grid-template-rows: 50vh 60vh;
    }
    .editor-pane {
      border-right: none;
      border-bottom: 3px solid var(--border);
    }
    .details {
      flex: none;
      min-height: 200px;
    }
  }
</style>
