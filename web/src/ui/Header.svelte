<script lang="ts">
  // Logo, title, About, Settings (simplify type names) and Run with a status badge.

  import { store, type Activity } from '../store.svelte'

  let settingsOpen = $state(false)

  const badges: Record<Activity, { label: string; title: string }> = {
    idle: { label: '', title: 'Not analyzed yet' },
    running: { label: '…', title: 'Analyzing' },
    ok: { label: '✓', title: 'Analyzed' },
    syntax: { label: '!', title: 'Syntax errors; showing the last valid analysis' },
    failed: { label: '✕', title: 'The analysis failed' },
    offline: { label: '?', title: "Can't reach the server" },
  }
  const badge = $derived(badges[store.activity])
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (settingsOpen = false)} />

<header>
  <div class="title">
    <svg class="logo" viewBox="0 0 56 56" aria-hidden="true">
      <rect width="56" height="56" rx="12" fill="#F05138" />
      <path
        fill="#fff"
        d="M31.5 11c8 5 12.5 14.7 10.6 21.6.2.3 3 4 1.7 7.6-1-2-3.6-3.4-6-1.9-5.1 3-12.6 3.1-19.6-.3-5.7-2.7-9.6-7.3-12-11.2 2.4 2 6.5 4.7 9.9 5.8-5.3-4.7-9.6-10.8-11.6-14.5 4 3.8 10 8.4 14 10.7C14.5 24.5 10 18 9 15c6.5 6.6 13.9 11.4 19.6 13.6 2.3-4.8 3.6-11.8 2.9-17.6Z"
      />
    </svg>
    <h1>Swift TypeGraph</h1>
  </div>

  <nav>
    <button class="plain" onclick={() => (store.aboutOpen = true)}>About</button>

    <div class="settings">
      <button class="plain" aria-expanded={settingsOpen} onclick={() => (settingsOpen = !settingsOpen)}>
        Settings
        <svg viewBox="0 0 24 24" class="icon" aria-hidden="true">
          <path
            fill="currentColor"
            d="M19.4 13a7.5 7.5 0 0 0 0-2l2.1-1.6-2-3.5-2.5 1a7.4 7.4 0 0 0-1.7-1L15 3h-4l-.4 2.9a7.4 7.4 0 0 0-1.7 1l-2.5-1-2 3.5L6.6 11a7.5 7.5 0 0 0 0 2l-2.1 1.6 2 3.5 2.5-1c.5.4 1.1.7 1.7 1L11 21h4l.4-2.9c.6-.3 1.2-.6 1.7-1l2.5 1 2-3.5L19.4 13ZM13 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7Z"
          />
        </svg>
      </button>
      {#if settingsOpen}
        <div class="popover" role="dialog" aria-label="Settings">
          <label>
            <input
              type="checkbox"
              checked={store.simplifyNames}
              onchange={(e) => store.setSimplifyNames(e.currentTarget.checked)}
            />
            Simplify type names
          </label>
          <p>
            Shows <code>MyModule.A</code> instead of <code>MyModule._(main.swift)::A</code>.
          </p>
        </div>
      {/if}
    </div>

    <button class="plain" onclick={() => store.run()} title={badge.title}>
      Run
      <span class="badge {store.activity}" aria-label={badge.title}>{badge.label}</span>
    </button>
  </nav>
</header>

<style>
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    flex-wrap: wrap;
  }
  .title {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .logo {
    width: 32px;
    height: 32px;
  }
  h1 {
    margin: 0;
    font-size: 24px;
    font-weight: 600;
  }
  nav {
    display: flex;
    align-items: center;
    gap: 18px;
  }
  .plain {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    border: none;
    background: none;
    color: var(--text);
    font-size: 17px;
    padding: 4px 2px;
  }
  .icon {
    width: 22px;
    height: 22px;
  }
  .badge {
    display: inline-grid;
    place-items: center;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    color: #fff;
    font-size: 13px;
    font-weight: 700;
    background: var(--muted);
  }
  .badge.ok {
    background: var(--success);
  }
  .badge.running {
    background: var(--accent);
  }
  .badge.syntax {
    background: var(--warning);
  }
  .badge.failed {
    background: var(--error);
  }
  .settings {
    position: relative;
  }
  .popover {
    position: absolute;
    right: 0;
    top: calc(100% + 6px);
    z-index: 10;
    width: 260px;
    padding: 12px 14px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--surface);
    box-shadow: 0 6px 24px rgb(0 0 0 / 0.12);
  }
  .popover label {
    display: flex;
    gap: 8px;
    align-items: center;
    font-weight: 500;
  }
  .popover p {
    margin: 6px 0 0;
    color: var(--muted);
    font-size: 13px;
  }
  code {
    font-family: var(--mono);
    font-size: 12px;
  }
</style>
