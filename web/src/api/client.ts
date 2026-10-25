import type { AnalyzeResponse } from './types'

/** Identifies this tab, so the server can drop its superseded requests. */
const session = crypto.randomUUID()

let inFlight: AbortController | undefined

/**
 * Posts one analysis request (SPEC §6.2). Starting a new request aborts the
 * previous one. Never throws: transport failures become statuses.
 */
export async function analyze(
  revision: number,
  source: string,
  moduleName: string,
  fileName: string,
): Promise<AnalyzeResponse> {
  inFlight?.abort()
  const controller = new AbortController()
  inFlight = controller
  let response: Response
  try {
    response = await fetch('/api/analyze', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Consent': '1', 'X-Session': session },
      body: JSON.stringify({ revision, source, moduleName, fileName }),
      signal: controller.signal,
    })
  } catch {
    return { revision, status: controller.signal.aborted ? 'superseded' : 'offline' }
  }
  // Caddy answers these itself, without a JSON body.
  if (response.status === 429) return { revision, status: 'rateLimited' }
  try {
    return { revision, ...(await response.json()) }
  } catch {
    if (response.status === 413) return { revision, status: 'tooLarge' }
    if (response.status === 502 || response.status === 503 || response.status === 504) {
      return { revision, status: 'offline' }
    }
    return { revision, status: 'internalError', message: `HTTP ${response.status} without a JSON body` }
  }
}
