<script lang="ts">
  // About and consent (SPEC §6.6). Nothing is sent to the server until the
  // user agrees that their code isn't private.

  import { store } from '../store.svelte'

  let understood = $state(store.consented)
  let dialog: HTMLDialogElement

  $effect(() => {
    if (store.aboutOpen && !dialog.open) dialog.showModal()
    if (!store.aboutOpen && dialog.open) dialog.close()
  })

  function close() {
    // Before agreeing, the dialog can't be dismissed.
    if (store.consented) store.aboutOpen = false
  }
</script>

<dialog
  bind:this={dialog}
  aria-labelledby="about-title"
  oncancel={(e) => {
    e.preventDefault()
    close()
  }}
>
  <h2 id="about-title">About Swift TypeGraph</h2>
  <p>
    Swift TypeGraph shows how Swift's lexical type lookup sees your code: which type members each
    extension depends on, what every declaration and type resolves to, and why an extension fails to
    bind. Type in the editor; the graph and the details panel follow the cursor.
  </p>

  <h3>Your code is not private</h3>
  <ul>
    <li>Everything you type is sent to this server for analysis.</li>
    <li>
      When an analysis fails (it runs out of time or memory, or hits an internal error), the code
      that caused it is <strong>stored in a log</strong> along with the error, so we can fix the bug.
    </li>
    <li>Don't paste anything confidential: secrets, credentials or code you can't share.</li>
  </ul>

  <h3>Limits</h3>
  <p>
    At most 8 KiB of source per request, 0.5 s and 10 MiB per analysis. Parse errors are shown in the
    editor; lookup runs only on code that parses.
  </p>

  <form
    method="dialog"
    onsubmit={(e) => {
      e.preventDefault()
      if (store.consented) close()
      else store.agree()
    }}
  >
    {#if store.consented}
      <button type="submit" class="primary">Close</button>
    {:else}
      <label>
        <input type="checkbox" bind:checked={understood} />
        I understand that my code is sent to the server and may be logged.
      </label>
      <button type="submit" class="primary" disabled={!understood}>Agree and continue</button>
    {/if}
  </form>
</dialog>

<style>
  dialog {
    max-width: 560px;
    width: calc(100% - 32px);
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 22px 26px;
    background: var(--surface);
    color: var(--text);
    line-height: 1.5;
  }
  dialog::backdrop {
    background: rgb(0 0 0 / 0.35);
  }
  h2 {
    margin: 0 0 8px;
    font-size: 20px;
  }
  h3 {
    margin: 16px 0 4px;
    font-size: 15px;
  }
  ul {
    padding-left: 20px;
    margin: 0;
  }
  form {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    align-items: center;
    justify-content: space-between;
    margin-top: 20px;
  }
  label {
    display: flex;
    gap: 8px;
    align-items: flex-start;
    flex: 1 1 260px;
  }
</style>
