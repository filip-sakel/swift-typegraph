<script lang="ts">
  // Tells the user why the latest analysis failed (SPEC §6.7). Internal errors
  // and invariant violations come with a bug-report prompt.

  import { MAX_SOURCE_BYTES, store } from '../store.svelte'

  const bugReportUrl = import.meta.env.VITE_BUG_REPORT_URL

  let copied = $state(false)

  const last = $derived(store.last)
  const bug = $derived(
    last?.status === 'internalError' ||
      (last?.status === 'ok' && last.invariantViolation !== undefined),
  )

  const message = $derived.by(() => {
    if (!last) return undefined
    switch (last.status) {
      case 'timeLimit':
        return `The analysis took longer than ${last.limit ?? 500} ms and was stopped. Try a smaller program.`
      case 'memoryLimit':
        return `The analysis used more than ${((last.limit ?? 10240) / 1024).toFixed(0)} MiB of memory and was stopped. Try a smaller program.`
      case 'tooLarge':
        return `The code is larger than ${((last.limit ?? MAX_SOURCE_BYTES) / 1024).toFixed(0)} KiB (UTF-8). Shorten it to analyze it.`
      case 'busy':
      case 'rateLimited':
        return 'Too many people are using TypeGraph right now. Retrying in a moment…'
      case 'offline':
        return "Can't reach the server. It will retry when you edit, or press Run."
      case 'badRequest':
        return 'The server rejected the request.'
      case 'internalError':
        return 'The analyzer hit an internal error. This is a bug in TypeGraph.'
      case 'ok':
        return last.invariantViolation
          ? 'The analyzer finished, but an internal TypeGraph assertion failed, so the graph may be wrong. This is a bug.'
          : undefined
      default:
        return undefined
    }
  })

  const report = $derived(
    bug && last
      ? [
          `**Kind:** ${last.status === 'ok' ? 'invariantViolation' : last.status}`,
          `**Report id:** ${last.reportId ?? 'n/a'}`,
          '',
          '**Message:**',
          '```',
          last.invariantViolation ?? last.message ?? '',
          '```',
          '',
          '**Source:**',
          '```swift',
          store.source,
          '```',
        ].join('\n')
      : '',
  )

  const fileUrl = $derived.by(() => {
    if (!bugReportUrl || !bug || !last) return undefined
    const url = new URL(bugReportUrl)
    url.searchParams.set('title', `TypeGraph ${last.status === 'ok' ? 'invariant violation' : 'internal error'} (${last.reportId ?? 'no id'})`)
    url.searchParams.set('body', report)
    return url.toString()
  })

  async function copy() {
    try {
      await navigator.clipboard.writeText(report)
      copied = true
      setTimeout(() => (copied = false), 1500)
    } catch {
      // Clipboard blocked; the user can still use the link.
    }
  }
</script>

{#if message}
  <div class="banner" class:bug role="status">
    <span>{message}</span>
    {#if bug}
      <span class="actions">
        Please file a bug report{#if last?.reportId}&nbsp;(id <code>{last.reportId}</code>){/if}.
        <button onclick={copy}>{copied ? 'Copied' : 'Copy bug report'}</button>
        {#if fileUrl}<a href={fileUrl} target="_blank" rel="noopener">File a bug report</a>{/if}
      </span>
    {/if}
  </div>
{/if}

<style>
  .banner {
    display: flex;
    flex-wrap: wrap;
    gap: 6px 14px;
    align-items: center;
    padding: 8px 14px;
    border-radius: 10px;
    background: var(--warning-bg);
    color: var(--warning-text);
    font-size: 14px;
  }
  .bug {
    background: var(--error-bg);
    color: var(--error);
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
  }
  code {
    font-family: var(--mono);
  }
  a {
    color: inherit;
    font-weight: 600;
  }
</style>
